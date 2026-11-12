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
    ListChanged = Data.define(:items)
  end
end
