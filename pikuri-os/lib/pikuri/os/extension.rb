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
    # The file-index tools need a usable index backend. The extension wires
    # them on the first of {FILE_INDEX_BACKENDS} that is
    # {LocalSearch.available? usable} — {LocalSearch} (GNOME, zero-setup),
    # then {Recoll} (DE-independent, but only with a built index). When none
    # is usable it logs and omits the tools — the agent still constructs and
    # works (bash + file tools).
    class Extension
      include Pikuri::Agent::Extension

      LOGGER = Pikuri.logger_for('Os::Extension')

      # @return [Array<Module>] file-index backends in preference order; the
      #   first one whose +#available?+ is true backs the fileindex tools.
      FILE_INDEX_BACKENDS = [LocalSearch, Recoll].freeze

      # @param filesystem [Pikuri::Workspace::Filesystem] the host fs view
      #   for the file tools and bash (typically
      #   {Pikuri::Workspace::Filesystem::AllowAll} for full-host access).
      # @param confirmer [Pikuri::Workspace::Confirmer] the *human*
      #   confirmer; Bash is auto-gated on top of it (see "Confirmation
      #   policy").
      # @param sandbox [Pikuri::Code::Bash::Sandbox] bash subprocess
      #   isolation; defaults to {Pikuri::Code::Bash::Sandbox::NONE}.
      # @param read_only [Pikuri::Workspace::ReadOnly, nil] the shared
      #   read-only flag; when present it is threaded into both
      #   {Pikuri::Workspace::Extension} (gates Write/Edit) and
      #   {Pikuri::Code::Extension} (wires plan mode), so one instance
      #   drives the whole posture. +nil+ leaves plan mode unavailable.
      # @param memory [MachineMemory] the MACHINE.md reader.
      # @param system_info [SystemInfo] the boot-time machine facts.
      # @param file_index_backends [Array<Module>] file-index backends in
      #   preference order; defaults to {FILE_INDEX_BACKENDS}. The first
      #   usable one backs the fileindex tools; if none is usable they are
      #   omitted.
      def initialize(filesystem:, confirmer:,
                     sandbox: Pikuri::Code::Bash::Sandbox::NONE, read_only: nil,
                     memory: MachineMemory.new, system_info: SystemInfo.new,
                     file_index_backends: FILE_INDEX_BACKENDS)
        @filesystem = filesystem
        @confirmer = confirmer
        @sandbox = sandbox
        @read_only = read_only
        @memory = memory
        @system_info = system_info
        @file_index_backends = file_index_backends
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        c.add_extension(Pikuri::Workspace::Extension.new(
                          filesystem: @filesystem, confirmer: @confirmer, read_only: @read_only,
                          confirm_all_writes: true
                        ))
        c.add_extension(Pikuri::Code::Extension.new(
                          filesystem: @filesystem,
                          confirmer: @confirmer,
                          passive_detector: Pikuri::Code::Bash::PassiveCommandDetector.new(allow_git: true),
                          sandbox: @sandbox,
                          read_only: @read_only
                        ))

        backend = @file_index_backends.find(&:available?)
        if backend
          c.add_tool FileindexSearch.new(backend: backend)
          c.add_tool FileindexRead.new(backend: backend)
        else
          tried = @file_index_backends.map(&:label).join(' / ')
          LOGGER.warn("no usable file index (tried #{tried}); fileindex_search / " \
                      'fileindex_read disabled on this host.')
        end

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
