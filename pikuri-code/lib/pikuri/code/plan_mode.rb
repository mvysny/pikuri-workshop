# frozen_string_literal: true

module Pikuri
  module Code
    # The plan-mode flag: while it is on, +write+ and +edit+ refuse, and the
    # model is told to add the change to its plan and call +exit_plan_mode+.
    # The host builds one, guards the file tools' filesystem with it, and hands
    # the same instance to {Extension}, which wires the enter/exit tools, the
    # per-turn reminder and {PlanModeChanged}:
    #
    #   plan_mode = Pikuri::Code::PlanMode.new
    #   Pikuri::Agent.new(...) do |c|
    #     c.add_extension Pikuri::Workspace::Extension.new(
    #       filesystem: plan_mode.guard(filesystem), confirmer:)
    #     c.add_extension Pikuri::Code::Extension.new(filesystem:, confirmer:, plan_mode:)
    #   end
    #   plan_mode.activate!   # a /plan slash command; the model has enter_plan_mode
    #
    # The flag outlives the agents built on it (a +/clear+ builds the next one
    # on the same flag), so a subscriber removes itself with {#remove_on_change}.
    #
    # == What it does NOT gate: a shell
    #
    # Only the writes that go through {#guard}'s filesystem. A shell command is
    # Turing-complete with no reliable static "does this write" test (+sed -i+,
    # a redirect, a Makefile target), so plan mode makes no attempt at +bash+,
    # which stays under its own confirmer. Enforcement on the file tools is
    # still the point: an outside-model review (Grok 4.6, 2026-08) rated a
    # posture it couldn't talk its way past over being told to plan first.
    #
    # == Thread-safety
    #
    # Thread-safe. The host and the model's tools may flip it from different
    # threads; {#on_change} callbacks run outside the lock, on the flipping
    # thread, so a re-entrant one can't deadlock the next flip.
    class PlanMode
      # What a refused +write+ or +edit+ tells the model, after the path.
      #
      # @return [String]
      REFUSAL = 'you are in plan mode (read-only). Add this change to your plan and ' \
                'call exit_plan_mode to present it; you can apply it once the user approves.'

      # @param active [Boolean] +true+ starts in plan mode (a +--plan+ flag).
      def initialize(active: false)
        @mutex = Mutex.new
        @active = active
        @on_change = []
      end

      # @return [Boolean]
      def active?
        @mutex.synchronize { @active }
      end

      # Idempotent: no {#on_change} when already active.
      #
      # @return [void]
      def activate! = flip(true)

      # Idempotent: no {#on_change} when already inactive.
      #
      # @return [void]
      def deactivate! = flip(false)

      # Wrap +filesystem+ so +resolve_for_write+ raises while plan mode is on.
      # Hand the result to +Workspace::Extension+; +write+ and +edit+ show the
      # error's message to the model.
      #
      # @param filesystem [Pikuri::Workspace::Filesystem]
      # @return [Guard] a filesystem that answers everything else as +filesystem+ does
      def guard(filesystem) = Guard.new(filesystem, self)

      # Register a callback fired once per real transition, with the new state.
      #
      #   cb = plan_mode.on_change { |active| c.emit_event(PlanModeChanged.new(active: active)) }
      #   c.on_close { plan_mode.remove_on_change(cb) }
      #
      # Callbacks fire in registration order; one that raises aborts the fan-out.
      #
      # @yieldparam active [Boolean] the new state
      # @return [Proc] the registered block, for {#remove_on_change}
      # @raise [ArgumentError] when called without a block
      def on_change(&blk)
        raise ArgumentError, 'on_change requires a block' unless block_given?

        @mutex.synchronize { @on_change << blk }
        blk
      end

      # Remove the first registration of +callable+. A flip already fanning
      # out on another thread may still call it once.
      #
      # @param callable [Proc] what {#on_change} returned
      # @return [Boolean] whether it was registered
      def remove_on_change(callable)
        @mutex.synchronize do
          index = @on_change.index { _1 == callable }
          @on_change.delete_at(index) if index
          !index.nil?
        end
      end

      # @return [String]
      def to_s = "PlanMode(#{active? ? 'on' : 'off'})"

      private

      def flip(target)
        callbacks = @mutex.synchronize do
          next nil if @active == target

          @active = target
          @on_change.dup
        end
        callbacks&.each { |cb| cb.call(target) }
        nil
      end
    end
  end
end
