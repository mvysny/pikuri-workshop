# frozen_string_literal: true

module Pikuri
  module Code
    # An {Pikuri::Agent::Extension} wiring pikuri-code's own tools: {Bash}, the
    # plan-mode pair ({EnterPlanMode} / {ExitPlanMode}), and {GitClone} as a
    # sub-agent-only tool. Owns only this surface — callers add Skill / Tasks /
    # Mcp / SubAgent extensions themselves.
    #
    # == Plan mode is opt-in via the read-only flag
    #
    # The plan-mode tools, {PLAN_MODE_PROMPT}, and the per-turn reminder are
    # wired only when the host passes a {Pikuri::Workspace::ReadOnly} flag via
    # +read_only:+ — and it must be the *same* instance handed to the
    # file-editing tools (via {Pikuri::Workspace::Extension}'s +read_only:+), so
    # their refusal and this reminder stay in lockstep. With no flag, {Bash} +
    # {GitClone} still install but plan mode is unavailable. The transition is a
    # {PlanModeChanged} domain event emitted from {#bind} — a pikuri-code
    # concern, not a core event (the loop never reads plan mode).
    #
    # == Usage
    #
    #   read_only = Pikuri::Workspace::ReadOnly.new
    #   Pikuri::Agent.new(...) do |c|
    #     c.add_extension Pikuri::Workspace::Extension.new(
    #       filesystem:, confirmer:, read_only: read_only
    #     )
    #     c.add_extension Pikuri::Code::Extension.new(
    #       filesystem: filesystem,
    #       confirmer: confirmer,
    #       sandbox: sandbox,
    #       read_only: read_only
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

      # Reason clause for a write/edit refusal *when plan mode is why the
      # workspace is read-only*. Handed to {Pikuri::Workspace::ReadOnly} (via
      # the host) so a refused Write/Edit names the recovery path
      # (+exit_plan_mode+) instead of the generic
      # {Pikuri::Workspace::ReadOnly::DEFAULT_MESSAGE}, which can't assume plan
      # mode is the cause.
      #
      # @return [String]
      PLAN_MODE_READONLY_MESSAGE =
        'you are in plan mode (read-only). Add this change to your plan and ' \
        'call exit_plan_mode to present it; you can apply it once the user approves.'

      # @param filesystem [Pikuri::Workspace::Filesystem]
      # @param confirmer [Pikuri::Workspace::Confirmer]
      # @param sandbox [Pikuri::Code::Bash::Sandbox]
      # @param read_only [Pikuri::Workspace::ReadOnly, nil] the shared read-only
      #   flag (same instance handed to {Pikuri::Workspace::Extension}). When
      #   present, plan-mode tools + prompt + reminder + event are wired; +nil+
      #   leaves plan mode unavailable.
      # @param passive_detector [#passive?, nil] passive-command pre-approval
      #   predicate handed to {Bash} only ({Bash::PassiveCommandDetector}); the
      #   +exit_plan_mode+ gate always uses the bare +confirmer+.
      def initialize(filesystem:, confirmer:, sandbox: Bash::Sandbox::NONE, read_only: nil,
                     passive_detector: nil)
        @filesystem       = filesystem
        @confirmer        = confirmer
        @sandbox          = sandbox
        @read_only        = read_only
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

        # Plan mode rides the host-owned read-only flag; only wire its
        # tools when one was supplied (see the class header). The prompt
        # half is contributed by {#system_prompt_snippets}.
        if @read_only
          c.add_tool EnterPlanMode.new(read_only: @read_only)
          c.add_tool ExitPlanMode.new(read_only: @read_only, confirmer: @confirmer)
        end

        # Sub-agent-only (never visible to the parent) — it exists solely for
        # the GIT_REPO_RESEARCHER persona.
        c.add_sub_agent_tool GitClone.new(filesystem: @filesystem)
        nil
      end

      # @return [Array<String>] the plan-mode prompt, only when the
      #   read-only flag is wired (so the prompt and the plan-mode tools
      #   appear together); otherwise none.
      def system_prompt_snippets = @read_only ? [PLAN_MODE_PROMPT] : []

      # Bridge plan-mode transitions onto the listener stream so UI chrome can
      # render the posture — both model-driven ({EnterPlanMode} / {ExitPlanMode})
      # and host-driven flips. No-op when plan mode isn't wired.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext]
      # @return [void]
      def bind(ctx)
        return nil unless @read_only

        @read_only.on_change { |active| ctx.emit_event(PlanModeChanged.new(active: active)) }
        nil
      end

      # Inject {PLAN_MODE_REMINDER} on every turn plan mode is active — the
      # soft half of the defense, re-asserting the posture
      # even when the *host* engaged it and the model never saw a tool call.
      # +nil+ (inject nothing) when plan mode is off or unwired.
      #
      # @param _ctx [Pikuri::Agent::ExtensionContext]
      # @param _content [String]
      # @param _attachments [Array<Pikuri::Attachment>]
      # @return [String, nil]
      def on_user_message(_ctx, _content, _attachments)
        return nil unless @read_only&.active?

        PLAN_MODE_REMINDER
      end
    end
  end
end
