# frozen_string_literal: true

module Pikuri
  module Tasks
    # Domain event emitted after every {List} mutation (add / status
    # change / delete), wired by {Extension#bind} via
    # {Pikuri::Agent::ExtensionContext#emit_event}. Carries a frozen
    # whole-list snapshot ({List#items}), so a consumer needs no +List+
    # reference — render or serialize the payload as-is.
    #
    # A batch +task_create+ emits one event per added item, so a renderer
    # should treat the latest snapshot as authoritative (last-wins), not
    # diff event-by-event. Fired on the agent's thread — a listener
    # feeding another thread serializes inside +on_event+ and hands off
    # only the immutable result (see {List}'s thread-confinement note).
    #
    # A terminal that renders unknown events through +to_s+ prints:
    #
    #   · tasks: 1/3 done, now: write the spec
    #   · tasks: none                              (after a /clear)
    ListChanged = Data.define(:items) do
      # @return [String] the done count and the task in progress, one line
      def to_s
        return 'tasks: none' if items.empty?

        done = items.count { |item| item.status == 'completed' }
        current = items.find { |item| item.status == 'in_progress' }
        line = "tasks: #{done}/#{items.size} done"
        current ? "#{line}, now: #{current.content}" : line
      end
    end
  end
end
