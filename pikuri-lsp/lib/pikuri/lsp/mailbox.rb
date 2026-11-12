# frozen_string_literal: true

module Pikuri
  module Lsp
    # A thread boundary that keeps only the *newest* value per key. A producer
    # thread pushes; one consumer thread drains, and the block runs on the
    # consumer's thread:
    #
    #   mailbox = Mailbox.new
    #   Thread.new { mailbox.push('token-1', progress) }   # the reader thread
    #
    #   mailbox.drain(tick: 0.1) do |value|                # nil on an idle tick
    #     cancellable&.check!
    #     break if ready?
    #     emit.call(value) if value
    #   end
    #
    # {#drain} loops until the block +break+s — the consumer has to poll its own
    # exit conditions anyway, so it gets one place to do it. No +stop_when:+
    # predicate, no sentinel value.
    #
    # It exists for the one shape a queue gets wrong. ruby-lsp emits hundreds of
    # +$/progress+ reports while it indexes, and a consumer blocked for three
    # minutes would replay every one of them — a burst of stale percentages
    # racing to catch up. Coalescing per key means the first drain yields
    # *current* state and then tracks live, which makes +Thread::Queue+ the wrong
    # primitive: it faithfully preserves exactly what this discards.
    #
    # Per key rather than one global latest because concurrent tasks are normal —
    # jdtls holds "Importing project" and "Building workspace" open at once. The
    # key is a parameter, so nothing here knows what the value is.
    #
    # Thread-safe, and that is its whole purpose. One consumer only: two threads
    # draining would each see an arbitrary half of the values.
    class Mailbox
      def initialize
        @mutex = Mutex.new
        @pushed = ConditionVariable.new
        @latest = {}
      end

      # Park +value+ under +key+, replacing whatever was parked there, and wake
      # the consumer.
      #
      # @param key [Object] what to coalesce on, e.g. a progress token.
      # @param value [Object] the newest state for that key.
      # @return [void]
      def push(key, value)
        @mutex.synchronize do
          @latest[key] = value
          @pushed.signal
        end
        nil
      end

      # Yield parked values on this thread until the block breaks, waking every
      # +tick+ seconds to yield +nil+ so the consumer can check its own exit
      # conditions. Values arrive in the order their keys were first pushed;
      # +nil+ means the mailbox was empty, not that anything ended.
      #
      # @param tick [Float] seconds between idle yields. A push wakes the wait
      #   early, so this bounds the *idle* latency, not the live one.
      # @yieldparam value [Object, nil] the newest value for one key, or +nil+ on
      #   an idle tick.
      # @return [Object] whatever the block broke with.
      def drain(tick:)
        loop do
          parked = take_all
          if parked.empty?
            yield nil
            @mutex.synchronize { @pushed.wait(@mutex, tick) if @latest.empty? }
          else
            parked.each { |value| yield value }
          end
        end
      end

      # @return [Integer] how many keys are parked. For tests and diagnostics;
      #   a consumer polls by draining.
      def size
        @mutex.synchronize { @latest.size }
      end

      private

      # Atomically: everything parked, and an empty mailbox. Nothing is yielded
      # under the mutex — the producer must stay free to push while the consumer
      # works.
      def take_all
        @mutex.synchronize do
          values = @latest.values
          @latest.clear
          values
        end
      end
    end
  end
end
