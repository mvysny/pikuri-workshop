# frozen_string_literal: true

module Pikuri
  module Os
    # One-call wiring for the offline OS-helper agent. Adding this single
    # extension to an +Agent.new+ block gives the complete surface — the
    # five workspace file tools, +bash+ (net-severable, with the
    # passive-command detector), the file-index tools, and the machine grounding +
    # +MACHINE.md+ memory folded into the system prompt.
    #
    # A composite: +configure+ adds {Pikuri::Workspace::Extension} and
    # {Pikuri::Code::Extension} as sub-extensions, then layers on the
    # OS-specific tools and prompt sections.
    #
    # == Confirmation policy
    #
    # The caller passes the *human* confirmer. The file tools get it via
    # {Pikuri::Workspace::Extension} with +confirm_all_writes: true+: since
    # this agent roams the full disk (no containment), *every* writable
    # Write/Edit confirms with a diff and an unwritable target
    # short-circuits to "ask the user to sudo" (see
    # {Pikuri::Workspace::WriteGate}, book/os-assistant.md). +Bash+ gets the same
    # confirmer plus a {Pikuri::Code::Bash::PassiveCommandDetector}, so
    # provably passive commands skip the prompt and everything else
    # reaches the human — bash mutations and file-tool writes both always
    # confirm.
    #
    # The detector is built +allow_git: true+, so passive git verbs skip
    # the prompt too (no per-repo trust prompt). Safe here *only because*
    # {Pikuri::Code::Bash::GIT_HARDENING} neutralizes the hostile
    # +core.fsmonitor+ vector that fires on a plain +git status+; the
    # accepted residual is diff-driver execution on an attacker-written
    # +.git/config+ (confined to non-clone-delivered repos). Full detail:
    # {Pikuri::Code::Bash::PassiveCommandDetector}'s +allow_git:+ yardoc.
    #
    # == Sandbox
    #
    # The +sandbox+ is the caller's choice (default {Pikuri::Code::Bash::Sandbox::NONE}).
    # The OS-helper binary passes {Pikuri::Code::Bash::Sandbox::FullFsNoNet}
    # for the net-severed, full-filesystem posture; that decision (and its
    # fail-loud probe) lives in the binary, so a differently-hosted client
    # can isolate differently.
    #
    # == Degradation
    #
    # The file-index tools run on the index {FileIndex.pick} finds ready.
    # When none is, the extension logs each index's reason and omits the
    # tools: the agent still works through bash and the file tools.
    class Extension
      include Pikuri::Agent::Extension

      LOGGER = Pikuri.logger_for('Os::Extension')

      # @param filesystem [Pikuri::Workspace::Filesystem] the host fs view
      #   for the file tools and bash (typically
      #   {Pikuri::Code::WholeDisk} for full-host access).
      # @param confirmer [Pikuri::Workspace::Confirmer] the *human*
      #   confirmer; Bash is auto-gated on top of it (see "Confirmation
      #   policy").
      # @param sandbox [Pikuri::Code::Bash::Sandbox] bash subprocess
      #   isolation; defaults to {Pikuri::Code::Bash::Sandbox::NONE}.
      # @param plan_mode [Pikuri::Code::PlanMode, nil] guards the file tools'
      #   filesystem and is handed to {Pikuri::Code::Extension}, so one
      #   instance drives the whole posture. +nil+ leaves plan mode unavailable.
      # @param memory [MachineMemory] the MACHINE.md reader.
      # @param system_info [SystemInfo] the boot-time machine facts.
      # @param file_index_backends [Array<Module>] file-index backends in
      #   preference order, handed to {FileIndex.pick}.
      def initialize(filesystem:, confirmer:,
                     sandbox: Pikuri::Code::Bash::Sandbox::NONE, plan_mode: nil,
                     memory: MachineMemory.new, system_info: SystemInfo.new,
                     file_index_backends: FileIndex::BACKENDS)
        @filesystem = filesystem
        @confirmer = confirmer
        @sandbox = sandbox
        @plan_mode = plan_mode
        @memory = memory
        @system_info = system_info
        @file_index_backends = file_index_backends
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        c.add_extension(Pikuri::Workspace::Extension.new(
                          filesystem: @plan_mode ? @plan_mode.guard(@filesystem) : @filesystem,
                          confirmer: @confirmer, confirm_all_writes: true
                        ))
        c.add_extension(Pikuri::Code::Extension.new(
                          filesystem: @filesystem,
                          confirmer: @confirmer,
                          passive_detector: Pikuri::Code::Bash::PassiveCommandDetector.new(allow_git: true),
                          sandbox: @sandbox,
                          plan_mode: @plan_mode
                        ))

        add_file_index_tools(c)
        nil
      end

      # Two grounding sections: the machine facts and the MACHINE.md notes
      # (or an affordance pointing at where to record them). System-info is
      # memoized at its source (re-pull on clear is free); the memory
      # section is read **fresh**, so MACHINE.md edits surface on a
      # "/clear".
      #
      # @return [Array<String>]
      def system_prompt_snippets
        [@system_info.prompt_section, @memory.prompt_section || empty_memory_affordance]
      end

      private

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def add_file_index_tools(c)
        backend = FileIndex.pick(@file_index_backends)
        c.add_tool FileindexSearch.new(backend: backend)
        c.add_tool FileindexRead.new(backend: backend)
      rescue FileIndex::Unavailable => e
        LOGGER.warn("#{e.message}\nfileindex_search / fileindex_read are off on this host.")
      end

      # System-prompt line shown when MACHINE.md doesn't exist yet, so the
      # agent still knows where to record durable facts.
      #
      # @return [String]
      def empty_memory_affordance
        <<~SECTION.chomp
          # Notes about this machine

          No durable notes recorded yet. You can record lasting facts about this
          computer's setup by creating and editing #{@memory.path}.
        SECTION
      end
    end
  end
end
