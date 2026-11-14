# frozen_string_literal: true

module Pikuri
  class Conversations
    # One live conversation: an {Pikuri::Agent} and the turn state around it.
    # Every method returns at once; the agent is built and its turns run on
    # threads of the conversation's own, and what happens there reaches the
    # listener as events:
    #
    #   conv = convs.open(id: 'c1', transport:, listener:)   # boots the agent
    #   conv.submit('how do I keep an avocado?')            # => :started
    #   conv.submit('also, ripe?')                           # => :injected — the running turn reads it
    #   conv.cancel                                          # the turn ends with TurnEnded(:cancelled)
    #   conv.submit                                          # => :started — a bare turn re-sends the injection
    #   conv.close                                           # => :closed, or :busy while a turn runs
    #
    # The states: +:new → :booting → :idle ⇄ :running → :closed+. A conversation
    # opened with +boot: false+ stays +:new+, readable through {#history}, until
    # the first message.
    #
    # == Implementation details
    #
    # One +Mutex+ guards the state; nothing outside the gem is ever called
    # under it — no listener, no +on_turn_end+, no +Agent#close+ — so a host may
    # take its own lock in a listener and call {#status} under that same lock.
    # The lock order is host lock → this lock → the agent's +Interloper+ lock.
    #
    # Whoever moves the conversation to +:running+ resets the +Cancellable+ in
    # the same critical section (+pikuri:D_host_resets_cancel+): a cancel that
    # lands after the move stops the turn, one that landed before was for the
    # previous turn.
    #
    # Messages that arrive before the agent exists wait here, since the agent
    # builds its +Interloper+ itself. Once it is built, the last waiting user
    # message becomes the first turn's message and the ones before it go into
    # the +Interloper+, which +run_loop+ drains ahead of the message — so the
    # order holds, and the common case (one message) is an ordinary turn.
    #
    # Thread-safe.
    class Conversation
      LOGGER = Pikuri.logger_for('Conversation')
      private_constant :LOGGER

      # What +Agent#run_loop+ refuses by stated modality, by an attachment's
      # MIME family. Mirrors the agent's own table, so a refused attachment
      # fails in {#submit} rather than inside the turn.
      MODALITY_BY_MEDIA_TYPE = { 'image' => :vision, 'audio' => :audio, 'video' => :video }.freeze
      private_constant :MODALITY_BY_MEDIA_TYPE

      Item = Pikuri::Agent::Control::Interloper::Item
      private_constant :Item

      # @return [String] the id the conversation was opened with
      attr_reader :id

      # @return [Pikuri::Agent::Listener::Base] hears the agent's events and this
      #   conversation's {Event}s, fixed for the conversation's life
      attr_reader :listener

      # @param id [String]
      # @param transport [Pikuri::Agent::ChatTransport] the model the agent is
      #   built on
      # @param listener [Pikuri::Agent::Listener::Base]
      # @param history [Pikuri::Agent::History, nil] a conversation to resume
      # @param build [#call] +(conversation, transport, history, cancellable)+
      #   → a new +Pikuri::Agent+
      # @param on_turn_end [#call, nil] +(conversation, history)+, see
      #   {Conversations#initialize}
      # @param on_closed [#call, nil] +(conversation)+, once the agent is released
      # @param priority [Integer] the turn threads' +Thread#priority+
      def initialize(id:, transport:, listener:, history:, build:, on_turn_end:, on_closed:, priority:)
        @id = id
        @listener = listener
        @transport = transport
        @history = history
        @build = build
        @on_turn_end = on_turn_end
        @on_closed = on_closed
        @priority = priority

        @lock = Mutex.new
        @released = ConditionVariable.new
        @cancellable = Pikuri::Agent::Control::Cancellable.new
        @state = :new
        @agent = nil
        @trifecta = nil
        @next_transport = nil
        @waiting = []
        @run_after_boot = false
        @cancelled_boot = false
        @closing = false
        @agent_released = false
      end

      # Send a user message: starts a turn when idle, joins the running one
      # when not.
      #
      #   conv.submit('fix the tests', attachments: [png])   # => :started
      #
      # A blank message with no attachments delivers what is pending — a
      # correction typed into a turn that was then cancelled — and is
      # +:ignored+ when nothing is.
      #
      # @param text [String, nil]
      # @param attachments [Array<Pikuri::Attachment>]
      # @return [Symbol] +:started+ (a turn or a boot starts, or a boot under way
      #   will deliver it), +:injected+ (the running turn reads it after its
      #   current tool batch, or a bare turn right after), +:ignored+ (blank, and
      #   nothing to deliver) or +:discarded+ (closed)
      # @raise [ArgumentError] if an attachment is not a +Pikuri::Attachment+
      # @raise [Pikuri::Agent::UnsupportedAttachmentError] if the next turn's
      #   transport states a modality that refuses an attachment; nothing is queued
      def submit(text = nil, attachments: [])
        unless attachments.all?(Pikuri::Attachment)
          raise ArgumentError, "attachments must be Pikuri::Attachments, got #{attachments.map(&:class)}"
        end

        blank = text.to_s.strip.empty?
        item = Item.new(kind: :user, content: blank ? '' : text, attachments:) unless blank && attachments.empty?
        locked do
          refuse_attachments!(attachments)
          deliver(item)
        end
      end

      # Inject reference text the host chose to show the model — a skill the
      # user loaded with +/skill+ — and run a bare turn to deliver it when idle.
      #
      # @param text [String]
      # @return [Symbol] as {#submit}
      # @raise [ArgumentError] if +text+ is blank
      def inject_system(text)
        raise ArgumentError, "text must not be blank, got #{text.inspect}" if text.to_s.strip.empty?

        locked { deliver(Item.new(kind: :system, content: text)) }
      end

      # Stop the running turn, or the boot. Undelivered messages stay pending;
      # {#submit} with no text re-sends them, {#discard_pending} drops them.
      #
      # @return [Symbol] +:cancelled+, or +:ignored+ when nothing runs
      def cancel
        locked do
          next :ignored unless %i[booting running].include?(@state) && !@closing

          @cancelled_boot = true if @state == :booting
          @cancellable.cancel!
          @effects << Event::CancelRequested.new
          :cancelled
        end
      end

      # @return [Array<Pikuri::Agent::Control::Interloper::Item>] the messages
      #   waiting for the agent, in delivery order
      def pending
        locked { @agent ? @agent.interloper.peek : @waiting.dup }
      end

      # Drop every message waiting for the agent.
      #
      # @return [Array<Pikuri::Agent::Control::Interloper::Item>] what was dropped
      def discard_pending
        locked do
          next @agent.interloper.drain! if @agent

          taken = @waiting.dup
          @waiting.clear
          @effects << Event::PendingChanged.new(count: 0) unless taken.empty?
          taken
        end
      end

      # Pick the model the next turn runs on. A turn already running finishes
      # on its own model; the last pick before the next turn wins, and picking
      # the current model undoes a pick.
      #
      # @param transport [Pikuri::Agent::ChatTransport]
      # @return [Symbol] +:selected+, or +:discarded+ when closed
      def switch_model(transport)
        locked do
          next :discarded if closed?

          picked = transport == @transport ? nil : transport
          @effects << Event::ModelPending.new(transport: picked) unless picked == @next_transport
          @next_transport = picked
          :selected
        end
      end

      # Start over: close the agent and boot a fresh one with an empty history.
      # Everything outside the history goes with the old agent too — a task
      # list, activated skills, an MCP server's state (+pikuri:D_agent_is_one_conversation+).
      #
      # @return [Symbol] +:cleared+, +:busy+ while booting or running, or
      #   +:discarded+ when closed
      def clear
        locked do
          next :discarded if closed?
          next :busy unless %i[new idle].include?(@state)

          old = @agent
          dropped = old ? old.interloper.size : @waiting.size
          @agent = nil
          @trifecta = nil
          @waiting.clear
          @history = nil
          @effects << Event::PendingChanged.new(count: 0) if dropped.positive?
          if old
            old.interloper.on_change = nil
            start_boot(retiring: old)
          end
          :cleared
        end
      end

      # Retire the conversation and release its agent. Once closing, the turn
      # in flight, if any, ends without +on_turn_end+ — so a host deleting the
      # conversation from disk never races a save.
      #
      # @param force [Boolean] cancel a running turn or boot and close once it
      #   unwinds, rather than refuse
      # @return [Symbol] +:closed+, +:closing+ (forced; {Event::Closed} follows
      #   once the turn unwinds) or +:busy+
      def close(force: false)
        agent = nil
        result = locked do
          next :closed if closed?

          if %i[booting running].include?(@state)
            next :busy unless force

            @closing = true
            @cancellable.cancel!
            next :closing
          end
          agent = @agent
          @state = :closed
          :released
        end
        return result unless result == :released

        release(agent)
        :closed
      end

      # @return [Status] state, pending count and models, read in one critical
      #   section; each model carries the cap and modalities {Probe} has learnt
      #   so far, so it may not +==+ the transport you passed in
      def status
        locked do
          pending = @agent ? @agent.interloper.size : @waiting.size
          Status.new(state: @state, pending:, model: Probe.facts(@transport),
                     next_model: Probe.facts(@next_transport || @transport))
        end
      end

      # @return [Pikuri::Agent::History, nil] the conversation as of {Conversations#open}
      #   or the last turn's end; +nil+ for a fresh or cleared one
      def history
        locked { @history }
      end

      # @return [Pikuri::Agent::Trifecta::Report, nil] the agent's trifecta
      #   picture; +nil+ until it is booted
      def trifecta
        locked { @trifecta }
      end

      # Block until the agent is released after a {#close}.
      #
      # @param timeout [Numeric] seconds
      # @return [Boolean] whether it was released in time
      def wait_closed(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @lock.synchronize do
          until @agent_released
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false if remaining <= 0

            @released.wait(@lock, remaining)
          end
          true
        end
      end

      # Start the boot of a +:new+ conversation; {Conversations#open} calls it
      # for +boot: true+.
      #
      # @return [void]
      # @api private
      def boot
        locked { start_boot if @state == :new }
        nil
      end

      # @return [String]
      def to_s
        "Conversation(#{@id}, #{@state})"
      end

      private

      def closed?
        @state == :closed || @closing
      end

      # Run the block under the lock, then emit the events it queued in
      # +@effects+ and start the threads it queued in +@spawns+ — both outside
      # the lock, which is the class's one rule.
      def locked
        effects = []
        spawns = []
        result = @lock.synchronize do
          @effects = effects
          @spawns = spawns
          yield
        ensure
          @effects = nil
          @spawns = nil
        end
        effects.each { |e| emit(e) }
        spawns.each { |name, task| spawn(name, &task) }
        result
      end

      def emit(event)
        @listener.on_event(event)
      rescue StandardError => e
        # A listener's bug must not strand the state machine mid-transition.
        LOGGER.error("conversation #{@id}: listener raised on #{event.class}: #{e.class}: #{e.message}")
      end

      # Hand +item+ (+nil+ for a blank submit) to the agent, or keep it for the
      # agent-to-be. Under the lock.
      def deliver(item)
        return :discarded if closed?

        case @state
        when :new, :booting
          if item
            @waiting << item
            @effects << Event::PendingChanged.new(count: @waiting.size)
          end
          return :ignored if @waiting.empty?

          @run_after_boot = true
          start_boot if @state == :new
          :started
        when :idle
          if item&.kind == :user
            start_turn(item.content, item.attachments)
          else
            inject(@agent, item) if item
            return :ignored unless @agent.interloper.pending?

            start_turn(nil, [])
          end
          :started
        when :running
          return :ignored unless item

          inject(@agent, item)
          :injected
        end
      end

      def inject(agent, item)
        if item.kind == :system
          agent.interloper.inject_system_message(item.content)
        else
          agent.interloper.inject_user_message(item.content, attachments: item.attachments)
        end
      end

      def refuse_attachments!(attachments)
        transport = Probe.facts(@next_transport || @transport)
        return unless transport.modalities

        attachments.each do |a|
          modality = MODALITY_BY_MEDIA_TYPE[a.mime.to_s.split('/').first]
          next unless modality && transport.modalities[modality] == false

          raise Pikuri::Agent::UnsupportedAttachmentError.new(a, "model #{transport.model} takes no #{modality} input")
        end
      end

      # Under the lock. +retiring+ is an agent {#clear} replaces: closed on the
      # boot thread before the new one is built, so the two never hold one
      # resource (an MCP server, a language server) at once.
      def start_boot(retiring: nil)
        @state = :booting
        @cancellable.reset!
        @cancelled_boot = false
        @effects << Event::Booting.new
        @spawns << ["boot #{@id}", lambda {
          retiring&.close
          run_boot
        }]
      end

      # Under the lock.
      def start_turn(message, attachments)
        @state = :running
        @cancellable.reset!
        @spawns << ["turn #{@id}", -> { run_turns(message, attachments) }]
      end

      def run_boot
        transport, history = locked do
          if @next_transport
            @transport = @next_transport
            @next_transport = nil
            @effects << Event::ModelPending.new(transport: nil)
          end
          [@transport, @history]
        end
        begin
          # The lookup that loads no model, so #status and #submit know the
          # model's inputs before the first turn.
          Probe.modalities(transport)
          agent = @build.call(self, transport, history, @cancellable)
          trifecta = agent.trifecta
        rescue StandardError => e
          agent&.close
          return boot_failed(e)
        end

        first = nil
        outcome = locked do
          if @closing
            @state = :closed
            next :close
          end
          @agent = agent
          @trifecta = trifecta
          agent.interloper.on_change = method(:pending_changed)
          first = @waiting.pop if @waiting.last&.kind == :user
          @waiting.each { |item| inject(agent, item) }
          @waiting.clear
          @effects << Event::Ready.new(trifecta:)
          run = @run_after_boot && !@cancelled_boot && (first || agent.interloper.pending?)
          @run_after_boot = false
          if run
            @state = :running
            @cancellable.reset!
            next :turn
          end
          # A cancelled boot keeps its first message pending, like any other.
          inject(agent, first) if first
          @state = :idle
          :idle
        end
        case outcome
        when :close then release(agent)
        when :turn then run_turns(first&.content, first&.attachments || [])
        end
      end

      def boot_failed(error)
        LOGGER.warn("conversation #{@id}: agent failed to boot: #{error.class}: #{error.message}")
        closing = locked do
          @state = @closing ? :closed : :new
          @run_after_boot = false
          @effects << Event::BootFailed.new(error:)
          @closing
        end
        release(nil) if closing
      end

      # The turn task: one turn, then bare turns while injections arrived too
      # late for the last one. Entered in +:running+, the token already reset.
      def run_turns(message, attachments)
        Thread.current.name = "turn #{@id}"
        Thread.current.priority = @priority
        loop do
          picked, current = locked do
            picked = @next_transport
            if picked
              @transport = picked
              @next_transport = nil
              @effects << Event::ModelPending.new(transport: nil)
            end
            @effects << Event::TurnStarted.new(user_message: message, attachments:)
            [picked, @transport]
          end

          outcome, error = begin
            probe(current)
            @agent.run_loop(user_message: message, attachments:, transport: picked)
            [:completed, nil]
          rescue Pikuri::Agent::Control::Cancellable::Cancelled
            [:cancelled, nil]
          rescue StandardError => e
            [:failed, e]
          end

          save unless locked { @closing }

          restart = locked do
            if @closing
              @state = :closed
              next false
            end
            if outcome == :completed && @agent.interloper.pending?
              @cancellable.reset!
              next true
            end
            @state = :idle
            false
          end
          emit(Event::TurnEnded.new(outcome:, error:, restarting: restart))
          break unless restart

          message = nil
          attachments = []
        end
        agent = locked { @state == :closed ? @agent : nil }
        release(agent) if agent
      end

      # Learn the turn's model before its first request, and size its server's
      # permits from the slot count. After {Event::TurnStarted}, so a UI shows
      # the message during a router's cold load. Skipped when nothing is left
      # to learn.
      def probe(transport)
        server = Probe.server(transport)
        return if transport.context_window && transport.modalities && Throttle.sized?(server)

        slots = Probe.props(transport).total_slots
        Throttle.default(server, slots) if slots && Throttle.key_for(server)
      end

      # Snapshot the history and hand it to +on_turn_end+, on the turn's
      # thread: the conversation goes idle only once the host has saved.
      def save
        history = @agent.export_history
        locked { @history = history }
        @on_turn_end&.call(self, history)
      rescue StandardError => e
        # A host hook that raises must not strand the conversation in :running.
        LOGGER.error("conversation #{@id}: on_turn_end raised #{e.class}: #{e.message}")
      end

      # +Interloper#on_change+: fires on whichever thread changed the count.
      # Under this lock it is a mid-turn {#submit} or a {#discard_pending}, so
      # the event waits for the lock to drop; elsewhere it is the agent's own
      # drain, on the turn thread.
      def pending_changed(count)
        event = Event::PendingChanged.new(count:)
        if @lock.owned?
          @effects << event
        else
          emit(event)
        end
      end

      # Close +agent+ off the caller's thread — an MCP teardown may take
      # seconds — then report {Event::Closed}.
      def release(agent)
        spawn("close #{@id}") do
          agent&.close
        ensure
          @lock.synchronize do
            @agent_released = true
            @released.broadcast
          end
          emit(Event::Closed.new)
          @on_closed&.call(self)
        end
      end

      def spawn(name, &task)
        Thread.new do
          Thread.current.name = name
          Thread.current.report_on_exception = false
          task.call
        rescue Exception => e # rubocop:disable Lint/RescueException
          LOGGER.error("#{name}: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
        end
      end
    end
  end
end
