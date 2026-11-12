# frozen_string_literal: true

module Pikuri
  module Code
    # The +enter_plan_mode+ tool: turns on the shared
    # {Pikuri::Workspace::ReadOnly} flag. Once active, Write/Edit refuse and the
    # {Extension}'s per-turn reminder steers the model to research and propose;
    # the model exits via {ExitPlanMode}, or the host flips the same flag from a
    # key binding / slash command. Entry is just as often host-initiated as
    # model-driven — either way the flag is the single source of truth. (It
    # gates Write/Edit, not Bash — see {Pikuri::Workspace::ReadOnly}.)
    #
    # Sharing: +P_shared_locked+ — the flag it flips is thread-safe, so nothing
    # breaks. Decide the *semantics* on purpose, though: agents sharing one flag
    # share one plan mode, so this agent entering it disables writes for all of
    # them. Per-agent plan mode means a {Pikuri::Workspace::ReadOnly} each.
    class EnterPlanMode < Pikuri::Tool
      # @return [String]
      DESCRIPTION = <<~DESC
        Enter plan mode: a read-only posture for researching and designing a change before writing any of it.

        Usage:
        - Reach for this before a non-trivial change — new features, multi-file edits, refactors, or anything with several valid approaches — so the user can sign off on the approach before code is written.
        - Skip it for small, unambiguous edits (a typo, an obvious one-line fix) and for pure research questions.
        - While in plan mode the file-editing tools are disabled; explore and reason freely, then present a plan with exit_plan_mode for approval.
        - When unsure, prefer entering: alignment up front is cheaper than redone work.
      DESC

      # @param read_only [Pikuri::Workspace::ReadOnly] the shared
      #   read-only flag to activate.
      # @return [EnterPlanMode]
      def initialize(read_only:)
        super(
          name: 'enter_plan_mode',
          description: DESCRIPTION,
          parameters: Parameters::EMPTY,
          execute: -> { EnterPlanMode.run(read_only: read_only) },
          # No legs: flips a local mode flag.
          trifecta_legs: Pikuri::Tool::TrifectaLegs::NONE
        )
      end

      # Activate plan mode (idempotent) and return the observation that
      # confirms the posture to the model.
      #
      # @param read_only [Pikuri::Workspace::ReadOnly]
      # @return [Pikuri::Tool::Result] tool observation, carrying +"Plan mode on"+
      def self.run(read_only:)
        read_only.activate!
        Pikuri::Tool::Result.new(
          content: 'You are now in plan mode (read-only): research and design only, do not edit ' \
                   'files. When the plan is ready, call exit_plan_mode to present it for approval.',
          summary: 'Plan mode on'
        )
      end
    end
  end
end
