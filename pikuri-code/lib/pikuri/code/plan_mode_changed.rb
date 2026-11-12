# frozen_string_literal: true

module Pikuri
  module Code
    # Domain event emitted onto the listener stream whenever plan mode
    # transitions — model-driven ({EnterPlanMode} / {ExitPlanMode}) or
    # host-driven. Wired by {Extension#bind} through the shared
    # {Pikuri::Workspace::ReadOnly} flag's +on_change+. A pikuri-code *domain*
    # event, not a core {Pikuri::Agent::Event} — the loop never reads plan
    # mode; listeners that don't care no-op on it (the demo
    # {Pikuri::Agent::Listener::Terminal} renders it generically via {#to_s}).
    #
    # Carries only the new posture, so a UI listener can render an indicator
    # without touching the flag. A host flip fires on the host's thread, a model
    # flip on the agent's — treat the boolean as the latest authoritative state.
    PlanModeChanged = Data.define(:active) do
      # @return [String] human-facing label; the Terminal demo prints it
      #   verbatim, so the wording lives here, not in core.
      def to_s
        "plan mode: #{active ? 'on (read-only)' : 'off'}"
      end
    end
  end
end
