# frozen_string_literal: true

module Pikuri
  module Code
    # The +bash+ tool — run an arbitrary shell command in the workspace.
    # +Code::Bash.new(filesystem: fs, confirmer: c)+ produces a tool whose
    # {Pikuri::Tool#to_ruby_llm_tool} wiring is identical to any bundled tool's
    # (filesystem + confirmer captured by the +execute+ closure).
    #
    # == Confirmation
    #
    # Every command is confirmed (unless a +passive_detector+ pre-approves it).
    # Bash composes a semantic {Pikuri::Workspace::Confirmer::Request} — a
    # question plus +$ <command>+ detail — and hands it to the confirmer, which
    # owns ALL presentation and medium-appropriate escaping of the raw bytes
    # (terminal neutralizes control bytes, web client HTML-escapes). The request
    # carries the command verbatim so each renderer escapes for its own medium.
    # The *observation* echo (+$ ...+ in the tool result) passes through
    # {.visible}, so the model can't smuggle a +\r\033[2K rm -rf ~/+ behind it
    # either. Execution uses the raw command; only displays are sanitized.
    #
    # == Subprocess wiring
    #
    #   timeout --signal=TERM --kill-after=5s <timeout>s bash -c <command>
    #
    # +bash -c+ (no +-l+) — no profile/rc sourcing. +timeout(1)+ from GNU
    # coreutils handles the SIGTERM-then-SIGKILL race (Ruby's +Timeout.timeout+
    # can't reliably kill subprocesses); +--kill-after=5s+ gives 5s to handle
    # SIGTERM before SIGKILL. The environment is de-bundlerized first, or a
    # +bundle exec+ against another project would pick up *pikuri's* Gemfile.
    # See {.subprocess_env} and {Pikuri::BundlerEnv}.
    #
    # == Timeout detection
    #
    # GNU +timeout+ exits +124+ after SIGTERM, +137+ after escalating to
    # SIGKILL; both are treated as "timed out". +125+ is also accepted:
    # uutils-coreutils 0.2.2 (the Rust reimplementation on some distros)
    # mis-reports +125+ instead of +124+ when +--kill-after+ is in play.
    # False-positive risk on real GNU coreutils is low (fixed, well-formed
    # argv). Caveat: +137+ is ambiguous — the OOM-killer also exits +137+; v1
    # accepts the mis-classification (the observation says "sent SIGTERM, then
    # SIGKILL" regardless).
    #
    # == Output handling
    #
    # Combined stdout+stderr (popen2e), head+tail truncated at {OUTPUT_HEAD} +
    # {OUTPUT_TAIL} bytes with a marker reporting bytes-omitted and total — the
    # model needs the scale to decide whether to re-run with +head+/+grep+.
    #
    # == Backgrounded subprocesses
    #
    # Plain +cmd &+ does NOT detach — the child inherits our combined-output
    # pipe, so {Pikuri::Subprocess#wait} blocks on +io.read+ until it exits. The
    # model must redirect fds to genuinely background: +cmd >/dev/null 2>&1 &+.
    # Such commands stay in our pgroup and get SIGTERM on pikuri exit via
    # {Pikuri::Subprocess.cleanup!}; +nohup+ / +setsid+ plus redirection opt out.
    #
    # == Sharing
    #
    # +P_one_agent+, but only because of the {Pikuri::Workspace::Confirmer}: with
    # a shared {Confirmer::Terminal} two agents fight over one human's
    # keystrokes. In substance this tool is stateless — every call spawns its
    # own subprocess, and the {Pikuri::Workspace::Filesystem}, {Bash::Sandbox}
    # and +passive_detector+ it holds are immutable — so under
    # {Confirmer::AutoApprove} nothing stops one instance serving every agent.
    #
    # Concurrency the *commands* create is not pikuri's to serialize: ten agents
    # running +bundle install+ in one workspace will corrupt each other's work
    # exactly as ten shells would.
    class Bash < Pikuri::Tool
      # @return [Logger]
      LOGGER = Pikuri.logger_for('Bash')

      # @return [Integer] default value of the +timeout+ parameter (seconds).
      DEFAULT_TIMEOUT = 120

      # @return [Integer] hard upper bound on the +timeout+ parameter.
      MAX_TIMEOUT = 600

      # @return [String] grace period between SIGTERM and SIGKILL,
      #   passed to +timeout --kill-after=...+.
      KILL_AFTER = '5s'

      # Git config keys forced onto every git invocation, threaded in via
      # {.git_hardening_delta}. What each key does:
      #
      # * +core.fsmonitor=false+ — the headline vector: a repo-local
      #   +core.fsmonitor = <cmd>+ runs +<cmd>+ on every index refresh (plain
      #   +git status+/+diff+, no +.gitattributes+ needed). +false+ is git's
      #   default, so legitimate status/diff are unaffected.
      # * +core.pager=cat+ — belt-and-suspenders; auto-paging is already inert
      #   under our non-TTY pipe, but a forced +cat+ makes it a no-op regardless.
      #
      # Why this exists — the config-execution vector that makes even a *passive*
      # git command an unconfirmed RCE without it, the narrow diff-driver
      # residual it deliberately does NOT close (+diff.external+ /
      # +.gitattributes+ +.textconv+, uncloseable via environment), and the tie
      # to {PassiveCommandDetector}'s +allow_git:+ — lives in
      # +pikuri-code/design/architecture.md+ (*Passive git needs Bash's hardening*).
      #
      # @return [Array<Array(String, String)>] +[key, value]+ pairs.
      GIT_HARDENING = [
        ['core.fsmonitor', 'false'],
        ['core.pager', 'cat']
      ].freeze

      # @return [Integer] bytes preserved from the start of the output
      #   when the combined-output stream exceeds {OUTPUT_HEAD} + {OUTPUT_TAIL}.
      OUTPUT_HEAD = 15 * 1024

      # @return [Integer] bytes preserved from the end of the output.
      OUTPUT_TAIL = 15 * 1024

      # Description shown to the LLM. opencode-shape: summary + +Usage:+
      # bullets. Per-parameter constraints (default, max) live in the
      # parameter descriptions.
      #
      # The +Avoid ... cat / rg / find+ bullet is load-bearing, not etiquette —
      # a shell read skips the +cat -n+ numbering {Pikuri::Workspace::Edit}
      # anchors on, the byte caps, the read-before-edit ledger and the path
      # gate. (An outside-model review — Grok 4.6, 2026-08 — called the split
      # the right bet; nothing tests that the model obeys the bullet.)
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Run a bash command in the workspace.

        Usage:
        - Use for tasks the dedicated tools can't do: git, tests, package managers, multi-step shell pipelines.
        - IMPORTANT: Avoid using this tool to run `cat`, plain `head` or `tail`, `sed`, `awk`, `rg`, `find` or `echo` commands, unless explicitly instructed or after you have verified that a dedicated tool cannot accomplish your task. Instead, use the appropriate dedicated tool as this will provide a much better experience for the user, respect the workspace and produce cleaner output.
        - Working directory is ALWAYS the project root: `pwd` returns it, and relative paths in commands resolve from there. To operate in a subfolder, chain `cd` in the same command (`cd src/foo && make test`) — `cd` does NOT persist across calls; each call starts fresh at the project root.
        - stdin is closed; interactive commands hang until timeout. Use non-interactive flags (`apt -y`, `git commit -m`).
        - Plain `cmd &` does NOT detach — the backgrounded process inherits our output pipe and blocks. To genuinely background, redirect fds: `cmd >/dev/null 2>&1 &`. Add `nohup` or `setsid` to survive pikuri exit.
        - Combined stdout+stderr is returned. Suppress either via `2>/dev/null` etc.
        - Large outputs are head+tail-truncated. Pipe through `head`/`tail`/`grep`/`wc` to control volume.
        # Git
        - Interactive flags (`-i`, e.g. `git rebase -i`, `git add -i`) are not supported in this environment.
        - Use the `gh` CLI (if available) for GitHub operations (PRs, issues, API).
        - Commit or push only when the user asks.
      DESC

      # @param filesystem [Pikuri::Workspace::Filesystem] captured for +chdir+;
      #   commands always run in +filesystem.project_root+ (explicit +chdir:+
      #   even when the process already chdir'd there, so a sub-agent or
      #   embedding host gets the same cwd). Bash does NOT path-resolve
      #   arguments — the +command+ is opaque shell syntax.
      # @param confirmer [Pikuri::Workspace::Confirmer] consulted before every
      #   command that +passive_detector+ does not pre-approve.
      # @param passive_detector [#passive?, nil] optional predicate over the
      #   raw command string ({PassiveCommandDetector}); +true+ runs with no
      #   prompt, +false+/+nil+ falls through to +confirmer+. The
      #   passive-auto-gate seam, kept separate so "how to ask" ({Confirmer})
      #   and "what may skip asking" (this) stay composable axes.
      # @param sandbox [Code::Bash::Sandbox] filesystem-sandbox seam (default
      #   {Sandbox::NONE}). Pass {Sandbox::Bubblewrap.new(filesystem:)} for an
      #   isolated subprocess; see {Sandbox}.
      # @raise [RuntimeError] if +bash+ or +timeout+ aren't on +PATH+.
      # @return [Bash]
      def initialize(filesystem:, confirmer:, sandbox: Sandbox::NONE, passive_detector: nil)
        Bash.send(:check_binaries!)
        # Without a sandbox, bash runs with pikuri's UID + filesystem view —
        # anything the user can read the LLM can read (+cat ~/.ssh/id_*+, +aws
        # configure list+), with the per-command Confirmer the only defense. Warn
        # only when the host opted out (or never opted in); Bubblewrap fixes it.
        if sandbox.equal?(Sandbox::NONE)
          LOGGER.warn(
            'Code::Bash is unsandboxed: commands run under your UID and can read ' \
            'sensitive files (~/.ssh, AWS credentials, browser sessions, ...). ' \
            'Use Sandbox::Bubblewrap or an outer container for isolation.'
          )
        end
        super(
          name: 'bash',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :command,
                              'Bash command to execute. Multi-line is fine. ' \
                              'Example: "ls -la lib/".'
            p.optional_string :description,
                              'Short 3-7 word label shown to the user alongside ' \
                              'the command, e.g. "Run unit tests".'
            p.optional_integer :timeout,
                               "Timeout in seconds. Defaults to #{DEFAULT_TIMEOUT}, " \
                               "max #{MAX_TIMEOUT}, e.g. 300."
          },
          execute: ->(command:, description: nil, timeout: DEFAULT_TIMEOUT) {
            Bash.run(filesystem: filesystem, confirmer: confirmer, sandbox: sandbox,
                     passive_detector: passive_detector,
                     command: command, description: description, timeout: timeout)
          },
          # Both inbound axes come from the *sandbox*, not the workspace: the
          # workspace governs what the LLM observes through the file tools, the
          # sandbox governs what bash sees. Scope the workspace to a vouched-for
          # repo and +cat ~/Downloads/*+ still works under a full-root bind.
          #
          # Note what this does *not* claim: +:human_reviewed+, though a
          # +Confirmer+ is right there. The human approves a *command* — a
          # program, not a payload. Behind a pipe, a heredoc, +$(…)+ or a script
          # file, the bytes that egress are computed at runtime and were never on
          # screen, so approving +curl+ approves an intent. That failure of the
          # payload-visibility clause is what keeps a coding agent over a private
          # repo loud, and it is deliberately a literal here rather than
          # something a rule engine could talk itself out of.
          #
          # The destination axis is left to derive: a shell picks its own host,
          # so a live leg here is always +:attacker_reachable+.
          trifecta_legs: Pikuri::Tool::TrifectaLegs.new(
            private: filesystem.private?,
            untrusted: sandbox.confined_to_workspace? && filesystem.trusted? ? :none : :hard,
            egress_payload_review: sandbox.egress? ? :unreviewed : :no_egress
          )
        )
      end

      # Bounds-check, confirm, spawn, and render the observation. Returns
      # either +"$ ...\n<out>\n\nexit status: N"+ on a normal exit, or
      # +"Error: ..."+ on rejection / timeout / bad inputs.
      #
      # @param filesystem [Pikuri::Workspace::Filesystem]
      # @param confirmer [Pikuri::Workspace::Confirmer]
      # @param sandbox [Code::Bash::Sandbox] wraps the spawned argv.
      # @param passive_detector [#passive?, nil] passive-command pre-approval
      #   predicate; a +true+ verdict skips the prompt. See {#initialize}.
      # @param command [String] raw command as supplied by the LLM
      # @param description [String, nil] optional short label for the user
      # @param timeout [Integer] seconds before SIGTERM is sent
      # @return [Pikuri::Tool::Result] the transcript (+"exit 0, 41 lines"+)
      #   once the command ran, or {Pikuri::Tool::Result.error} on a rejection,
      #   a timeout or bad inputs
      def self.run(filesystem:, confirmer:, command:, description:, timeout:,
                   sandbox: Sandbox::NONE, passive_detector: nil)
        return Pikuri::Tool::Result.error('empty bash command.') if command.strip.empty?
        return Pikuri::Tool::Result.error("timeout must be >= 1, got #{timeout}") if timeout < 1
        return Pikuri::Tool::Result.error("timeout must be <= #{MAX_TIMEOUT}, got #{timeout}") if timeout > MAX_TIMEOUT

        # A command the detector deems passive (provably observe-only) runs
        # without a prompt; everything else is confirmed by the human.
        unless passive_detector&.passive?(command)
          request = compose_request(command: command, description: description, timeout: timeout)
          case decision = confirmer.ask(request: request)
          in Pikuri::Workspace::Confirmer::Rejected | Pikuri::Workspace::Confirmer::Redirected
            return decision.observation('the bash command')
          in Pikuri::Workspace::Confirmer::Approved
            # fall through to execution (the command is non-editable, so the
            # approved detail is the same command we already hold)
          end
        end

        argv = sandbox.wrap([
          'timeout', '--signal=TERM', "--kill-after=#{KILL_AFTER}", "#{timeout}s",
          'bash', '-c', command
        ])
        result = Pikuri::Subprocess.spawn(*argv, chdir: filesystem.project_root.to_s,
                                                 env: subprocess_env(filesystem)).wait

        output = truncate(result.output)
        exit_code = result.status.exitstatus

        # 124 (GNU SIGTERM), 137 (GNU SIGKILL), 125 (uutils-coreutils
        # 0.2.2 bug when --kill-after is set). See class header.
        if exit_code == 124 || exit_code == 137 || exit_code == 125
          Pikuri::Tool::Result.error("command timed out after #{timeout}s (sent SIGTERM, then SIGKILL).\n\n" \
                                     "$ #{visible(command)}\n#{output}")
        else
          Pikuri::Tool::Result.new(
            content: "$ #{visible(command)}\n#{output}\n\nexit status: #{exit_code}",
            summary: "exit #{exit_code}, #{Pikuri::Tool.pluralize(output.lines.size, 'line')}"
          )
        end
      end

      # Compose the semantic confirmation request:
      #
      # * question — +OK to run bash[: <desc>][ \[Timeout: Ns\]]+
      # * detail — +$ <command>+, the command VERBATIM (the confirmer
      #   escapes for its medium; see the class header's Confirmation
      #   section)
      #
      # Colon after +bash+ is dropped when there's no description, since a
      # trailing colon with nothing after it reads as broken. Timeout
      # suffix appears only when non-default.
      #
      # @return [Pikuri::Workspace::Confirmer::Request]
      def self.compose_request(command:, description:, timeout:)
        question = +'OK to run bash'
        desc_clean = description&.strip
        question << ": #{desc_clean}" if desc_clean && !desc_clean.empty?
        question << " [Timeout: #{timeout}s]" if timeout != DEFAULT_TIMEOUT

        Pikuri::Workspace::Confirmer::Request.new(question: question, detail: "$ #{command}")
      end
      private_class_method :compose_request

      # Environment for the bash subprocess: the de-bundlerized base
      # ({Pikuri::BundlerEnv.clean_delta}), then git hardening
      # ({.git_hardening_delta}), then the filesystem's git identity
      # ({Pikuri::Workspace::Filesystem#env}). The three deltas touch disjoint
      # keys (bundler vars / +GIT_CONFIG_*+ / +GIT_AUTHOR_*+ +
      # +GIT_COMMITTER_*+), so merge order is immaterial.
      #
      # @param filesystem [Pikuri::Workspace::Filesystem]
      # @return [Hash{String=>(String,nil)}] +env:+ delta for
      #   {Pikuri::Subprocess.spawn} (a +nil+ value unsets the key).
      def self.subprocess_env(filesystem)
        Pikuri::BundlerEnv.clean_delta.merge(git_hardening_delta).merge(filesystem.env)
      end
      private_class_method :subprocess_env

      # Emit {GIT_HARDENING} as a +GIT_CONFIG_COUNT+ / +GIT_CONFIG_KEY_<n>+ /
      # +GIT_CONFIG_VALUE_<n>+ env delta. This protocol has the same top
      # precedence as command-line +-c+, so it overrides a hostile repo-local
      # +core.fsmonitor+ regardless of what the repo says.
      #
      # Via *environment*, not by rewriting the model's command, because the
      # command is opaque shell syntax we refuse to parse, and env applies
      # uniformly to *every* git in the command — each link of a +&&+/+|+ chain,
      # and any git a script underneath forks — with no parsing.
      #
      # Indices are offset past any +GIT_CONFIG_COUNT+ already inherited, so our
      # keys append rather than clobber a host's; the higher index also wins
      # under git's last-wins rule on a duplicate key.
      #
      # @return [Hash{String=>String}]
      def self.git_hardening_delta
        base = ENV['GIT_CONFIG_COUNT'].to_i
        delta = {}
        GIT_HARDENING.each_with_index do |(key, value), i|
          delta["GIT_CONFIG_KEY_#{base + i}"] = key
          delta["GIT_CONFIG_VALUE_#{base + i}"] = value
        end
        delta['GIT_CONFIG_COUNT'] = (base + GIT_HARDENING.size).to_s
        delta
      end
      private_class_method :git_hardening_delta

      # Neutralize control bytes for the *observation* echo (+"$ ..."+ in the
      # tool result) — without this a model could craft +command: "\rrm -rf
      # ~/"+ that visually overwrites the echo line after the user read it.
      # Delegates to {Pikuri::Sanitizer} (preserves +\n+, visualizes the rest).
      # The echo is passive, so {Pikuri::Sanitizer::Warning}s are dropped here —
      # they surface at the confirmation prompt, before the user approves.
      #
      # @param command [String]
      # @return [String]
      def self.visible(command)
        Pikuri::Sanitizer.sanitize(command).text
      end
      private_class_method :visible

      # Head+tail-truncate +output+ to {OUTPUT_HEAD} + {OUTPUT_TAIL}
      # bytes with a marker reporting both bytes-omitted and total.
      # No-op when the output already fits.
      #
      # @param output [String]
      # @return [String]
      def self.truncate(output)
        total = output.bytesize
        return output if total <= OUTPUT_HEAD + OUTPUT_TAIL

        omitted = total - (OUTPUT_HEAD + OUTPUT_TAIL)
        head = output.byteslice(0, OUTPUT_HEAD)
        tail = output.byteslice(total - OUTPUT_TAIL, OUTPUT_TAIL)
        "#{head}\n... [#{omitted} bytes omitted; total was #{total} bytes] ...\n#{tail}"
      end
      private_class_method :truncate

      # Verify +bash+ and GNU +timeout+ are reachable on +PATH+. Routed
      # through {Pikuri::Subprocess.spawn} to honor the subprocess seam
      # (no direct +system+ / +backtick+ in +lib/+). +bash+ missing
      # surfaces as +Errno::ENOENT+ from +popen2e+; +timeout+ missing
      # surfaces as a non-zero exit from +command -v+.
      #
      # @return [void]
      # @raise [RuntimeError] if either binary is missing
      def self.check_binaries!
        result = Pikuri::Subprocess.spawn('bash', '-c', 'command -v timeout >/dev/null', chdir: '/').wait
        raise "Code::Bash requires GNU coreutils 'timeout' on PATH" unless result.status.success?
      rescue Errno::ENOENT
        raise "Code::Bash requires 'bash' on PATH"
      end
      private_class_method :check_binaries!
    end
  end
end
