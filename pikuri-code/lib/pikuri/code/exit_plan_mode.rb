# frozen_string_literal: true

module Pikuri
  module Code
    # The +exit_plan_mode+ tool: presents the finished plan for approval and, on
    # a yes, turns the shared {PlanMode} back off. The
    # plan is shown and the yes/no collected through the same
    # {Pikuri::Workspace::Confirmer} the +write+/+bash+ tools use, so
    # presentation + attacker-text sanitization live in one place. On approval
    # the flag flips off and the model is told to proceed; on a decline it stays
    # on and the observation steers a refine-and-re-present, never an edit. The
    # LLM-authored plan is passed as the request +detail+, so the Confirmer
    # neutralizes it before display.
    #
    # Sharing: as {EnterPlanMode} — +P_shared_locked+ on the flag, and sharing
    # it makes plan mode VM-wide. The {Pikuri::Workspace::Confirmer} pulls the
    # other way ({Confirmer::Terminal} is +P_one_agent+), so a shared instance
    # is only as shareable as the confirmer behind it.
    class ExitPlanMode < Pikuri::Tool
      # @return [String]
      DESCRIPTION = <<~DESC
        Exit plan mode by presenting your finished implementation plan for the user's approval.

        Usage:
        - Call this only once your plan is complete and unambiguous; pass the full plan as the `plan` argument.
        - The user is shown the plan and asked to approve. On approval you leave plan mode and may implement it; on a decline you stay in plan mode — refine the plan and call this again.
        - If a requirement is still unclear, ask the user directly first (without leaving plan mode) rather than presenting a half-formed plan.
        - Do not use this for pure research tasks — those never enter plan mode in the first place.
      DESC

      # @param plan_mode [PlanMode] the shared flag to deactivate on approval.
      # @param confirmer [Pikuri::Workspace::Confirmer] consulted to
      #   present the plan and collect the approval.
      # @return [ExitPlanMode]
      def initialize(plan_mode:, confirmer:)
        super(
          name: 'exit_plan_mode',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :plan,
                              'Your complete implementation plan, in Markdown, ' \
                              'shown to the user for approval. Cover the files ' \
                              'to change and the changes to each, e.g. ' \
                              '"## Plan\n1. Add X to foo.rb\n2. ...".'
          },
          wants_context: true,
          execute: ->(plan:, context:) {
            ExitPlanMode.run(plan_mode: plan_mode, confirmer: confirmer, plan: plan,
                             cancellable: context.cancellable)
          },
          # No legs: flips a local mode flag (behind a confirmer, which grades
          # nothing here — there is no leg to gate).
          trifecta_legs: Pikuri::Tool::TrifectaLegs::NONE
        )
      end

      # Renders bare: the one required argument is the whole Markdown plan, and
      # the confirmer is already showing it.
      #
      # @param _arguments [Hash] raw tool-call arguments; ignored
      # @return [String] +""+
      def describe_call(_arguments)
        ''
      end

      # Present +plan+ for approval; on yes deactivate plan mode, on no
      # keep it active. Returns the observation the model reacts to.
      #
      # @param plan_mode [PlanMode]
      # @param confirmer [Pikuri::Workspace::Confirmer]
      # @param plan [String] the LLM-authored plan to show the user
      # @param cancellable [Pikuri::Agent::Control::Cancellable] the calling
      #   turn's token, so a cancel reaches a confirmation still waiting on the
      #   human (+pikuri:D_confirmer_sees_the_cancel+).
      # @return [Pikuri::Tool::Result] +"Plan mode off"+ / +"Plan not
      #   approved"+ once the user has answered, or
      #   {Pikuri::Tool::Result.error} when there was no plan mode to exit
      def self.run(plan_mode:, confirmer:, plan:, cancellable:)
        unless plan_mode.active?
          return Pikuri::Tool::Result.error('not in plan mode, so there is nothing to exit. ' \
                                            'Proceed with the work directly.')
        end

        request = Pikuri::Workspace::Confirmer::Request.new(
          question: 'Approve this plan? (approving exits plan mode and lets the agent edit files)',
          detail: plan
        )

        case confirmer.ask(request: request, cancellable: cancellable)
        in Pikuri::Workspace::Confirmer::Approved
          plan_mode.deactivate!
          Pikuri::Tool::Result.new(
            content: 'Plan approved — you are no longer in plan mode. Implement the plan now.',
            summary: 'Plan mode off'
          )
        in Pikuri::Workspace::Confirmer::Rejected
          Pikuri::Tool::Result.new(
            content: 'The user did not approve the plan; you are still in plan mode (read-only). ' \
                     'Ask what they would like changed, revise the plan, and call exit_plan_mode ' \
                     'again when ready. Do not edit any files.',
            summary: 'Plan not approved'
          )
        in Pikuri::Workspace::Confirmer::Redirected(message:)
          Pikuri::Tool::Result.new(
            content: "The user did not approve the plan and said: #{message}\n" \
                     'You are still in plan mode (read-only). Revise the plan accordingly and ' \
                     'call exit_plan_mode again. Do not edit any files.',
            summary: 'Plan not approved'
          )
        end
      end
    end
  end
end
