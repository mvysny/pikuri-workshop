# frozen_string_literal: true

module Pikuri
  module Code
    # An {Pikuri::Agent::Extension} wiring pikuri-code's own tools: {Bash} and
    # the plan-mode pair ({EnterPlanMode} / {ExitPlanMode}). Owns only this
    # surface — callers add Skill / Tasks / Mcp / SubAgent extensions and
    # {GitRepoResearcher} themselves.
    #
    # == Plan mode is opt-in
    #
    # The plan-mode tools, {PLAN_MODE_PROMPT}, and the per-turn reminder are
    # wired only when the host passes a {PlanMode} via +plan_mode:+ — the
    # *same* instance whose {PlanMode#guard} wraps the file tools' filesystem,
    # so their refusal and this reminder stay in lockstep. With none, {Bash}
    # still installs but plan mode is unavailable. The transition
    # is a {PlanModeChanged} domain event emitted from {#configure}'s bridge — a
    # pikuri-code concern, not a core event (the loop never reads plan mode).
    #
    # == Usage
    #
    #   plan_mode = Pikuri::Code::PlanMode.new
    #   Pikuri::Agent.new(...) do |c|
    #     c.add_extension Pikuri::Workspace::Extension.new(
    #       filesystem: plan_mode.guard(filesystem), confirmer:
    #     )
    #     c.add_extension Pikuri::Code::Extension.new(
    #       filesystem: filesystem,
    #       confirmer: confirmer,
    #       sandbox: sandbox,
    #       plan_mode: plan_mode
    #     )
    #   end
    class Extension
      include Pikuri::Agent::Extension

      # Tool classes whose pre-registration is rejected — the extension
      # is the single owner of these, so a manually pre-registered copy
      # would shadow the wiring done here.
      TOOL_CLASSES = [Bash, EnterPlanMode, ExitPlanMode].freeze

      # Static plan-mode explainer, appended *once* (and so prefix-cached) when
      # plan mode is wired: mechanics + active-behavior contract, paid once. The
      # per-turn {PLAN_MODE_REMINDER} is then a one-line re-assertion at the
      # uncached tail. An extension-owned snippet that names its own tools (the
      # persona/extension carve-out to "no tool names in a main prompt").
      #
      # @return [String]
      PLAN_MODE_PROMPT = <<~PROMPT
        <plan_mode>
        You can work in plan mode — a read-only posture for researching and designing a change before writing any of it. Reach for enter_plan_mode before a non-trivial change (new features, multi-file edits, refactors, anything with several viable approaches); the user can also turn plan mode on directly. While it is active you will see a short reminder each turn.

        While in plan mode:
        - The file-editing tools are disabled and will refuse — do not try to create, overwrite, or edit files.
        - Explore freely: read files, search the codebase, and run read-only shell commands.
        - Work out a concrete plan — which files change, the change to each, and any trade-offs — and write it out.
        - Call exit_plan_mode with that plan to present it for approval. Only start implementing once the user approves.
        - If a requirement is genuinely ambiguous, ask the user directly rather than guessing.
        </plan_mode>
      PROMPT

      # One-line per-turn re-assertion, injected as a reference block while
      # plan mode is active (see {#on_user_message}). Deliberately tiny — it
      # lands at the uncached tail, while the substantive prose lives cached in
      # {PLAN_MODE_PROMPT}. Inlined rather than in +prompts/+ because it's one
      # line.
      #
      # @return [String]
      PLAN_MODE_REMINDER =
        'Reminder: you are in plan mode (read-only) — research, design, ' \
        'and brainstorm, but do not edit files.'

      # @param filesystem [Pikuri::Workspace::Filesystem]
      # @param confirmer [Pikuri::Workspace::Confirmer]
      # @param sandbox [Pikuri::Code::Bash::Sandbox]
      # @param plan_mode [PlanMode, nil] the flag whose {PlanMode#guard} wraps
      #   the file tools' filesystem. When present, plan-mode tools + prompt +
      #   reminder + event are wired; +nil+ leaves plan mode unavailable.
      # @param passive_detector [#passive?, nil] passive-command pre-approval
      #   predicate handed to {Bash} only ({Bash::PassiveCommandDetector}); the
      #   +exit_plan_mode+ gate always uses the bare +confirmer+.
      def initialize(filesystem:, confirmer:, sandbox: Bash::Sandbox::NONE, plan_mode: nil,
                     passive_detector: nil)
        @filesystem       = filesystem
        @confirmer        = confirmer
        @sandbox          = sandbox
        @plan_mode        = plan_mode
        @passive_detector = passive_detector
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        TOOL_CLASSES.each do |cls|
          if c.tools.any?(cls)
            raise "#{cls} cannot be pre-registered when adding Pikuri::Code::Extension"
          end
        end

        c.add_tool Bash.new(filesystem: @filesystem, confirmer: @confirmer, sandbox: @sandbox,
                            passive_detector: @passive_detector)

        if @plan_mode
          c.add_tool EnterPlanMode.new(plan_mode: @plan_mode)
          c.add_tool ExitPlanMode.new(plan_mode: @plan_mode, confirmer: @confirmer)
        end

        bridge_plan_mode(c) if @plan_mode
        nil
      end

      # @return [Array<String>] the plan-mode prompt, only when plan mode is
      #   wired (so the prompt and the plan-mode tools appear together)
      def system_prompt_snippets = @plan_mode ? [PLAN_MODE_PROMPT] : []

      # Inject {PLAN_MODE_REMINDER} on every turn plan mode is active — the
      # soft half of the defense, re-asserting the posture
      # even when the *host* engaged it and the model never saw a tool call.
      # +nil+ (inject nothing) when plan mode is off or unwired.
      #
      # @param _content [String]
      # @param _attachments [Array<Pikuri::Attachment>]
      # @return [String, nil]
      def on_user_message(_content, _attachments)
        return nil unless @plan_mode&.active?

        PLAN_MODE_REMINDER
      end

      private

      # Bridge plan-mode transitions onto the listener stream so UI chrome can
      # render the posture — both model-driven ({EnterPlanMode} / {ExitPlanMode})
      # and host-driven flips.
      #
      # The flag outlives this agent — a host's "/clear" closes the agent and
      # builds the next on the same flag — so the bridge unsubscribes on close.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def bridge_plan_mode(c)
        bridge = @plan_mode.on_change { |active| c.emit_event(PlanModeChanged.new(active: active)) }
        c.on_close { @plan_mode.remove_on_change(bridge) }
      end
    end
  end
end
