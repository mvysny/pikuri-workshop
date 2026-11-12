# frozen_string_literal: true

module Pikuri
  module Lsp
    # Whether a server has finished indexing, and the wait that blocks until it
    # has. One rule for every server: **no progress token open, and nothing said
    # for {SETTLE} seconds.** Fed from the server's notification stream, drained
    # by whoever is waiting — two different threads:
    #
    #   readiness = Readiness.new(server_id: 'java')
    #   client.on_notification { |method, params| readiness.observe(method, params) }
    #
    #   readiness.wait(cancellable: cancellable, alive: -> { client.alive? }) do |progress|
    #     emitter.call(progress)     # ServerProgress, on *this* thread
    #   end
    #
    # The gate exists because the alternative is a lie: ruby-lsp answers a
    # +definition+ sent mid-index with a successful +[]+, and an agent reads that
    # as "this symbol has no definition" and proceeds. There is nothing in +[]+ to
    # reason about, which is why this is the one case where pikuri waits instead
    # of relaying.
    #
    # == Why a debounce, and why one rule fits every server
    #
    # Quiescence alone is a false edge: jdtls's long-lived +Initialize Workspace+
    # token is *bracketed* by transient ones — a plain two-file project produced
    # eight — and there every token was closed **0.9s before the server could
    # answer**. The debounce is not the timeout pikuri removed: it never abandons
    # the wait, it only refuses to call an idle moment the end.
    #
    # One rule covers both reference servers because their failure modes are
    # opposite. jdtls *defers* mid-index requests and flushes the backlog when it
    # is ready, so waiting too long costs latency and nothing else; ruby-lsp
    # answers early and wrongly, so waiting is the only defense. No per-server
    # predicate, no knob.
    #
    # == Two edges it cannot see, both relayed rather than papered over
    #
    # * A server whose *first* token opens more than {SETTLE} after its handshake
    #   is briefly called ready before it ever began. Both measured servers open
    #   theirs within milliseconds of +initialized+, so this is the residual cost
    #   of a generic gate rather than an observed one.
    # * A token the server opens and never closes waits forever — the no-clock
    #   stance working as intended, with the human as the timeout via
    #   +cancellable+.
    #
    # Thread-safe: {#observe} runs on the server's reader thread while {#wait}
    # runs on the caller's, which is what the {Mailbox} is here for.
    class Readiness
      # Seconds of quiet, after the last token closes, before the index is
      # called built. Above the 0.9s gap jdtls was measured to need, with margin;
      # the cost is that much added to a first call against a warm server.
      SETTLE = 1.5

      # How often {#wait} wakes with nothing parked, to re-check readiness,
      # liveness and cancellation.
      TICK = 0.1

      # @param server_id [String] the registry entry's id, carried on every
      #   {ServerProgress} this emits.
      # @param settle [Float] seconds of quiet that end the wait. Overridden in
      #   tests; there is deliberately no configuration seam for it.
      def initialize(server_id:, settle: SETTLE)
        @server_id = server_id
        @settle = settle
        @mutex = Mutex.new
        @mailbox = Mailbox.new
        @open = {}
        @quiet_since = now
      end

      # Take one server notification into account. Anything that is not
      # +$/progress+ is ignored, so this can be handed the whole stream.
      #
      # Runs on the reader thread: it only records state and parks a
      # {ServerProgress} for {#wait} to emit, because
      # {Pikuri::Agent::ExtensionContext#emit_event} is the agent thread's.
      #
      # @param method [String] the notification method.
      # @param params [Hash, nil] its +params+ member.
      # @return [void]
      def observe(method, params)
        return unless method == '$/progress'

        token = params&.fetch('token', nil).to_s
        value = params&.fetch('value', nil)
        return unless value.is_a?(Hash)

        progress = record(token, value)
        @mailbox.push(token, progress) if progress
        nil
      end

      # @return [Boolean] whether every task the server announced has ended and
      #   it has been quiet since — the gate's whole rule.
      def ready?
        @mutex.synchronize { @open.empty? && (now - @quiet_since) >= @settle }
      end

      # Block until the server is ready, yielding progress as it arrives.
      #
      # Returns immediately when the gate is already open, so a warm server
      # costs one predicate. Otherwise it yields every {ServerProgress} the
      # server sends — coalesced, so a three-minute wait yields *current* state
      # rather than replaying the backlog — and finally a +done: true+ for every
      # task still in flight, however the wait ended and whether or not this wait
      # was the one that announced it: a host that drew a bar must be told to
      # take it down even when the server never sent the +end+.
      #
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] polled
      #   every {TICK}; this is what makes an unbounded wait acceptable.
      # @param alive [Proc] answers whether the server can still become ready.
      #   Without it a dead child would be waited on forever.
      # @yieldparam progress [ServerProgress]
      # @return [Boolean] +true+ when the server is ready, +false+ when +alive+
      #   went false first. Cancellation raises instead.
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] on cancellation.
      def wait(cancellable: nil, alive: -> { true })
        # Tracked by title, not token: the host draws its bars off what it was
        # shown, and a ServerProgress carries no token for it to key on.
        shown = []
        @mailbox.drain(tick: TICK) do |progress|
          cancellable&.check!
          # Liveness first: a child that died without ever announcing a task is
          # *quiet*, and quiet is half of what this gate calls ready.
          break false unless alive.call
          break true if ready?
          next unless progress

          progress.done ? shown.delete(progress.title) : shown |= [progress.title]
          yield progress
        end
      ensure
        (shown | open_titles).each do |title|
          yield ServerProgress.new(server_id: @server_id, title: title, done: true)
        end
      end

      # Forget everything: a restarted server has an empty index, so its previous
      # tokens say nothing and the quiet clock starts over.
      #
      # @return [void]
      def reset!
        @mutex.synchronize do
          @open.clear
          @quiet_since = now
        end
        nil
      end

      private

      # @return [Array<String>] titles of the tasks the server has not ended.
      #   The union with what a wait showed is what guarantees no bar outlives
      #   its wait — including a task announced before the wait even started.
      def open_titles
        @mutex.synchronize { @open.values.uniq }
      end

      # @return [ServerProgress, nil] what to park, or +nil+ for a +kind+ no
      #   +WorkDoneProgress+ defines.
      def record(token, value)
        @mutex.synchronize do
          @quiet_since = now
          # A report or end whose begin we never saw is titled by its token: the
          # spec requires the begin first, so that is a server bug to relay, not
          # to invent a title for.
          case value['kind']
          when 'begin' then title = @open[token] = (value['title'] || token).to_s
          when 'report' then title = (@open[token] ||= token)
          when 'end' then title = @open.delete(token) || token
          else return nil
          end
          ServerProgress.new(server_id: @server_id, title: title,
                             message: value['message'], percentage: value['percentage'],
                             done: value['kind'] == 'end')
        end
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
