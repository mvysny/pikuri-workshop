# frozen_string_literal: true

module Pikuri
  class Conversations
    module Throttle
      # A counting semaphore whose wait is cancellable, obtained from
      # {Throttle.for} rather than built directly:
      #
      #   Throttle.for(base).acquire(cancellable:) { post_request }
      #
      # +permits+ +nil+ means unlimited, and then {#acquire} is a bare +yield+ —
      # which is what makes an unsized (cloud) server free of every lock here.
      #
      # Thread-safe.
      class Semaphore
        # @return [Integer, nil] how many permits exist; +nil+ for unlimited
        attr_reader :permits

        # @param permits [Integer, nil] concurrent permits, or +nil+ for unlimited
        def initialize(permits)
          @permits = permits
          @available = permits
          @mutex = Mutex.new
          @cv = ConditionVariable.new
        end

        # Run the block holding one permit, waiting for one first.
        #
        # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] polled
        #   while waiting, so a cancel lands on a request parked in this queue
        #   rather than after the server finally answers it
        # @yield with the permit held
        # @return [Object] the block's value
        # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] if cancelled
        #   before the permit was taken — nothing was sent
        def acquire(cancellable: nil)
          return yield if @permits.nil?

          take(cancellable)
          begin
            yield
          ensure
            release
          end
        end

        # @return [Integer, nil] permits not currently held; +nil+ for unlimited
        def available
          @permits.nil? ? nil : @mutex.synchronize { @available }
        end

        # @return [String] +"1/2 permits"+ or +"unlimited"+
        def to_s
          @permits.nil? ? 'unlimited' : "#{available}/#{@permits} permits"
        end

        private

        def take(cancellable)
          @mutex.synchronize do
            loop do
              cancellable&.check!
              if @available.positive?
                @available -= 1
                return
              end

              # A timed wait that re-checks the flag rather than a plain +wait+:
              # +cancel!+ stays a bare flag write, callable from a SIGINT trap,
              # so it can signal no condition variable and the waiter polls.
              @cv.wait(@mutex, Pikuri::Agent::Control::Cancellable::SLICE_SECONDS)
            end
          end
        end

        def release
          @mutex.synchronize do
            @available += 1
            # +broadcast+, not +signal+: a +signal+ can wake exactly the waiter
            # about to raise Cancelled, stranding the permit until another
            # release.
            @cv.broadcast
          end
        end
      end
    end
  end
end
