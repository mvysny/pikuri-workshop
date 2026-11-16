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
    # {#boot} or the first message.
    #
    # == Implementation details
    #
    # One +Mutex+ guards the state; nothing outside the gem is ever called
    # under it — no listener, no {Saver}, no +Agent#close+ — so a host may
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
      # @param saver [Saver, nil] keeps the conversation after every turn
      # @param on_closed [#call, nil] +(conversation)+, once the agent is released
      # @param priority [Integer] the turn threads' +Thread#priority+
      # @param titler [Titler, nil] names this conversation once a turn has
      #   ended; +nil+ when it needs no name
      def initialize(id:, transport:, listener:, history:, build:, saver:, on_closed:, priority:, titler: nil)
        @id = id
        @listener = listener
        @transport = transport
        @history = history
        @build = build
        @saver = saver
        @on_closed = on_closed
        @priority = priority
        @titler = titler
        @title_cancellable = Pikuri::Agent::Control::Cancellable.new

        @lock = Mutex.new
        # Broadcast when the agent is released or one of the threads ends.
        @changed = ConditionVariable.new
        @threads = 0
        @cancellable = Pikuri::Agent::Control::Cancellable.new
        @state = :new
        @agent = nil
        @trifecta = nil
        @next_transport = nil
        @cap = nil
        @waiting = []
        @run_after_boot = false
        @cancelled_boot = false
        # Bumped by a clear while booting: a build for an older one is stale.
        @boot_generation = 0
        @closing = false
        @agent_released = false
        # Calls of #locked whose events are being heard; Closed waits for zero.
        @emitting = 0
      end

      # Send a user message: starts a turn when idle, joins the running one
      # when not.
      #
      #   conv.submit('fix the tests', attachments: [png])   # => :started
      #   conv.submit('extract page 3', system: [skill])     # the skill, then the message, one turn
      #   conv.submit(system: [skill])                       # a bare turn delivers the skill alone
      #
      # +system:+ is reference text the host chose to show the model — a skill
      # the user loaded with +/skill+. It goes ahead of +text+ in one step, so
      # the two arrive in order whatever state the conversation is in.
      #
      # A blank message with no attachments delivers what is pending — a
      # correction typed into a turn that was then cancelled — and is
      # +:ignored+ when nothing is.
      #
      # @param text [String, nil]
      # @param attachments [Array<Pikuri::Attachment>]
      # @param system [Array<String>] reference blocks, in order, ahead of +text+
      # @return [Symbol] +:started+ (a turn or a boot starts, or a boot under way
      #   will deliver it), +:injected+ (the running turn reads it after its
      #   current tool batch, or a bare turn right after), +:ignored+ (blank, and
      #   nothing to deliver) or +:discarded+ (closed)
      # @raise [ArgumentError] if an attachment is not a +Pikuri::Attachment+,
      #   or a +system:+ block is not a non-blank String
      # @raise [Pikuri::Agent::UnsupportedAttachmentError] if the next turn's
      #   transport states a modality that refuses an attachment; nothing is queued
      def submit(text = nil, attachments: [], system: [])
        unless attachments.all?(Pikuri::Attachment)
          raise ArgumentError, "attachments must be Pikuri::Attachments, got #{attachments.map(&:class)}"
        end
        unless system.all? { |block| block.is_a?(String) && !block.strip.empty? }
          raise ArgumentError, "system: blocks must be non-blank Strings, got #{system.inspect}"
        end

        blank = text.to_s.strip.empty?
        items = system.map { |block| Item.new(kind: :system, content: block) }
        items << Item.new(kind: :user, content: blank ? '' : text, attachments:) unless blank && attachments.empty?
        locked do
          refuse_attachments!(attachments)
          deliver(items)
        end
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

      # Drop every message waiting for the agent. Their count is
      # {Status#pending}, and {Event::PendingChanged} reports each change.
      #
      # @return [Array<Pikuri::Agent::Control::Interloper::Item>] what was
      #   dropped; empty once closing, so no event follows {Event::Closed}
      def discard_pending
        locked do
          next [] if closed?
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

      # Start over: close the agent and boot a fresh one with an empty history;
      # {Event::Cleared} tells the listener, even when there was no agent yet.
      # Everything outside the history goes with the old agent too — a task
      # list, activated skills, an MCP server's state (+pikuri:D_agent_is_one_conversation+).
      #
      # A clear while booting starts that boot over from the empty history,
      # on the same thread, so two agents never exist at once.
      #
      # @return [Symbol] +:cleared+, +:busy+ while a turn runs, or
      #   +:discarded+ when closed
      def clear
        locked do
          next :discarded if closed?
          next :busy if @state == :running

          old = @agent
          dropped = old ? old.interloper.size : @waiting.size
          @agent = nil
          @trifecta = nil
          @waiting.clear
          @history = nil
          @effects << Event::Cleared.new
          @effects << Event::PendingChanged.new(count: 0) if dropped.positive?
          if @state == :booting
            @boot_generation += 1
            @run_after_boot = false
            @effects << Event::Booting.new
          elsif old
            old.interloper.on_change = nil
            start_boot(retiring: old)
          end
          :cleared
        end
      end

      # Retire the conversation and release its agent.
      #
      # Refused while a turn runs, or while a boot has a message waiting to
      # become one. A boot nothing waits on closes: it would lose nothing.
      #
      # A turn +force+ cuts short is still saved by the {Saver}, as any
      # cancelled turn does, so a quitting host keeps what was said. A host
      # deleting the conversation needs no guard against that late save:
      # {Store#delete} wins over it.
      #
      # @param force [Boolean] cancel a running turn or boot and close once it
      #   unwinds, rather than refuse
      # @return [Symbol] +:closed+, +:closing+ (a turn or boot was under way;
      #   {Event::Closed} follows once it unwinds and has saved) or +:busy+
      def close(force: false)
        agent = nil
        result = locked do
          next :closed if closed?

          if %i[booting running].include?(@state)
            next :busy unless force || (@state == :booting && @waiting.empty?)

            @closing = true
            @cancellable.cancel!
            @title_cancellable.cancel!
            next :closing
          end
          agent = @agent
          @state = :closed
          @title_cancellable.cancel!
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

      # Block until a {#close} has run its course: the agent released and
      # {Event::Closed}, the last event, heard by the listener. A title request
      # still in flight may outlive it, but emits nothing more; {#wait_settled}
      # waits that out too.
      #
      # Never call it from the listener: +Closed+ waits for the event being
      # heard, so the wait runs out its whole +timeout+.
      #
      # @param timeout [Numeric] seconds
      # @return [Boolean] whether it closed in time — true means nothing more
      #   reaches the listener
      def wait_closed(timeout)
        wait_until(timeout) { @agent_released }
      end

      # Block until nothing of this conversation is in flight: no boot, no
      # turn, and none of its threads still running — a turn's title included
      # — so every event they emit has reached the listener.
      #
      #   conv.submit('how do I keep an avocado?')
      #   conv.wait_settled(5)   # TurnEnded heard, the title landed, the save done
      #
      # The +:idle+ state alone comes too early: a turn goes idle under the
      # lock and only then emits {Event::TurnEnded}, with its title already
      # asked on a thread of its own. Specs are the main user.
      #
      # @param timeout [Numeric] seconds
      # @return [Boolean] whether it settled in time
      def wait_settled(timeout)
        wait_until(timeout) { @threads.zero? && !%i[booting running].include?(@state) }
      end

      # Start the boot of a +:new+ conversation; any other state ignores it.
      # {Conversations#open} calls it for +boot: true+; a host whose listener
      # reads the conversation back opens with +boot: false+ and calls it once
      # it holds the conversation.
      #
      # @return [void]
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
      #
      # Events are counted in +@emitting+ from the critical section that
      # queued them until the listener has heard them, so {#release} holds
      # {Event::Closed} back for an event that passed its +closed?+ check
      # before a close on another thread.
      def locked
        effects = []
        spawns = []
        result = @lock.synchronize do
          @effects = effects
          @spawns = spawns
          yield.tap { @emitting += 1 unless effects.empty? }
        ensure
          @effects = nil
          @spawns = nil
        end
        unless effects.empty?
          begin
            effects.each { |e| emit(e) }
          ensure
            @lock.synchronize do
              @emitting -= 1
              @changed.broadcast
            end
          end
        end
        spawns.each { |name, task| spawn(name, &task) }
        result
      end

      def emit(event)
        @listener.on_event(event)
      rescue StandardError => e
        # A listener's bug must not strand the state machine mid-transition.
        LOGGER.error("conversation #{@id}: listener raised on #{event.class}: #{e.class}: #{e.message}")
      end

      # Hand +items+ (empty for a blank submit) to the agent, or keep them for
      # the agent-to-be. Under the lock.
      def deliver(items)
        return :discarded if closed?

        case @state
        when :new, :booting
          unless items.empty?
            @waiting.concat(items)
            @effects << Event::PendingChanged.new(count: @waiting.size)
          end
          return :ignored if @waiting.empty?

          @run_after_boot = true
          start_boot if @state == :new
          :started
        when :idle
          # A trailing user message is the turn's own; run_loop drains what
          # went into the interloper ahead of it, so the order holds.
          message = items.last if items.last&.kind == :user
          (message ? items[...-1] : items).each { |item| inject(@agent, item) }
          if message
            start_turn(message.content, message.attachments)
          else
            return :ignored unless @agent.interloper.pending?

            start_turn(nil, [])
          end
          :started
        when :running
          return :ignored if items.empty?

          items.each { |item| inject(@agent, item) }
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
        transport = locked do
          if @next_transport
            @transport = @next_transport
            @next_transport = nil
            @effects << Event::ModelPending.new(transport: nil)
          end
          @transport
        end
        begin
          # The lookup that loads no model, so #status and #submit know the
          # model's inputs before the first turn.
          Probe.modalities(transport)
        rescue StandardError => e
          return boot_failed(e)
        end
        facts = Probe.facts(transport)

        loop do
          # Read after the probe, the long wait (a dead server's connect
          # timeout): a clear landing there costs no rebuild, and a close
          # builds nothing.
          closing, history, generation = locked do
            @state = :closed if @closing
            [@closing, @history, @boot_generation]
          end
          return release(nil) if closing

          begin
            agent = @build.call(self, facts, history, @cancellable)
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
            # Cleared mid-build: this agent holds the history the clear dropped.
            next :stale unless generation == @boot_generation

            @agent = agent
            @trifecta = trifecta
            agent.interloper.on_change = method(:pending_changed)
            first = @waiting.pop if @waiting.last&.kind == :user
            @waiting.each { |item| inject(agent, item) }
            @waiting.clear
            @effects << Event::Ready.new(trifecta:)
            @cap = facts.context_window
            @effects << Event::ContextCap.new(cap: @cap)
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
          when :stale then agent.close
          when :close then release(agent)
          when :turn then run_turns(first&.content, first&.attachments || [])
          end
          break unless outcome == :stale
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
        closing = false
        loop do
          transport = locked do
            if @next_transport
              @transport = @next_transport
              @next_transport = nil
              @effects << Event::ModelPending.new(transport: nil)
            end
            @effects << Event::TurnStarted.new(user_message: message, attachments:)
            @transport
          end

          outcome, error = begin
            facts = probe(transport)
            # One door for both: a picked model switches the chat, and the
            # same model with newly learnt facts is adopted silently.
            @agent.run_loop(user_message: message, attachments:, transport: facts)
            [:completed, nil]
          rescue Pikuri::Agent::Control::Cancellable::Cancelled
            [:cancelled, nil]
          rescue StandardError => e
            [:failed, e]
          end

          history = save
          title(history) if history

          restart = locked do
            closing = @closing
            again = !closing && outcome == :completed && @agent.interloper.pending?
            if closing
              @state = :closed
            elsif again
              @cancellable.reset!
            else
              @state = :idle
            end
            @effects << Event::TurnEnded.new(outcome:, error:, restarting: again)
            again
          end
          break unless restart

          message = nil
          attachments = []
        end
        # Only a close this thread finished: once :idle, a close from the
        # TurnEnded listener or another thread has released the agent itself.
        release(@agent) if closing
      end

      # Learn the turn's model before its first request: size its server's
      # permits from the slot count, and announce the cap when it is news.
      # After {Event::TurnStarted}, so a UI shows the message during a router's
      # cold load. The asking is skipped when nothing is left to learn.
      #
      # @return [Pikuri::Agent::ChatTransport] +transport+ with what is known
      def probe(transport)
        server = Probe.server(transport)
        unless transport.context_window && transport.modalities && Throttle.sized?(server)
          slots = Probe.props(transport).total_slots
          Throttle.default(server, slots) if slots && Throttle.key_for(server)
        end
        facts = Probe.facts(transport)
        locked do
          unless facts.context_window == @cap
            @cap = facts.context_window
            @effects << Event::ContextCap.new(cap: @cap)
          end
        end
        facts
      end

      # Snapshot the history and hand it to the {Saver}, on the turn's
      # thread: the conversation goes idle only once the host has saved.
      #
      # @return [Pikuri::Agent::History, nil] the snapshot; +nil+ when taking it
      #   raised
      def save
        history = @agent.export_history
        locked { @history = history }
        begin
          @saver&.save(self, history)
        rescue StandardError => e
          # A host hook that raises must not strand the conversation in :running.
          LOGGER.error("conversation #{@id}: saver raised #{e.class}: #{e.message}")
        end
        history
      end

      # Ask the {Titler} for a name, once, on a thread of its own: after the
      # turn rather than beside it, so the title never takes the permit a small
      # server's only slot the turn is waiting for. A turn whose history holds
      # no user text yet (a bare turn delivering a skill) leaves it for the
      # next.
      def title(history)
        opener = history.messages.find do |m|
          m.role.to_s == 'user' && m.kind == 'user' && !m.content.to_s.strip.empty?
        end&.content
        titler = locked do
          next nil if @titler.nil? || opener.nil? || closed?

          @titler.tap { @titler = nil }
        end
        return unless titler

        spawn("title #{@id}") do
          name = titler.title_for(opener, cancellable: @title_cancellable)
          locked { @effects << Event::Titled.new(title: name) if name && !closed? }
        rescue Pikuri::Agent::Control::Cancellable::Cancelled
          nil
        rescue StandardError => e
          # A failed title leaves the name the conversation has; the next
          # opening of the conversation asks again.
          LOGGER.error("conversation #{@id}: titling failed: #{e.class}: #{e.message}")
        end
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
      # seconds — then report {Event::Closed}, the last event.
      def release(agent)
        spawn("close #{@id}") do
          agent&.close
        ensure
          begin
            # Waits for events being heard, not for the threads: a title's HTTP
            # call outlives a cancel, and Closed would wait for its whole answer.
            @lock.synchronize { @changed.wait(@lock) while @emitting.positive? }
            emit(Event::Closed.new)
            @on_closed&.call(self)
          ensure
            # Only now, so a waiter wakes once nothing more reaches the listener.
            @lock.synchronize do
              @agent_released = true
              @changed.broadcast
            end
          end
        end
      end

      # Counted from before the thread exists to after its last event, so
      # {#wait_settled} needs no thread names — a thread names itself only
      # once it runs.
      def spawn(name, &task)
        @lock.synchronize { @threads += 1 }
        Thread.new do
          Thread.current.name = name
          Thread.current.report_on_exception = false
          task.call
        rescue Exception => e # rubocop:disable Lint/RescueException
          LOGGER.error("#{name}: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
        ensure
          @lock.synchronize do
            @threads -= 1
            @changed.broadcast
          end
        end
      end

      # Block on +@changed+ until the block, run under the lock, holds.
      #
      # @return [Boolean] false when +timeout+ ran out first
      def wait_until(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @lock.synchronize do
          until yield
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false if remaining <= 0

            @changed.wait(@lock, remaining)
          end
          true
        end
      end
    end
  end
end
