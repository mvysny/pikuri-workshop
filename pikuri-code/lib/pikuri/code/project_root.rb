# frozen_string_literal: true

require 'pathname'

module Pikuri
  module Code
    # Climb from a working directory toward the project root, looking for a VCS
    # marker (+.git+ / +.hg+ / +.svn+). A coding host uses it to decide the
    # {Pikuri::Workspace::Filesystem} +project_root:+ — the writable
    # containment ceiling and (under {Bash::Sandbox::Bubblewrap}) the
    # bind-mount root, so +git+/+make+ can climb inside the sandbox to find
    # +<repo>/.git+ / +<repo>/Makefile+:
    #
    #   launch_cwd   = Pathname.new(Dir.pwd)
    #   project_root = Pikuri::Code::ProjectRoot.find(cwd: launch_cwd) || launch_cwd
    #
    # == Why VCS-only markers
    #
    # Build-system fallbacks (+Gemfile+, +pyproject.toml+, +package.json+,
    # +pom.xml+, +build.gradle+, ...) were rejected: they aren't reliable root
    # markers in multi-module setups (a Gradle subproject, a Maven module, a
    # yarn-workspaces package each has its own), so climbing for them lands on
    # the nearest subtree root — and a wrong project_root means the sandbox
    # bind-mounts the wrong tree and +git+ can't see the real +.git+. VCS markers
    # sit only at the actual root (or a submodule root, the user's intended
    # boundary when they cd'd in).
    #
    # If no marker is found within the safe-climb bounds, {.find} returns +nil+
    # and the caller falls back to the launch +cwd+ (losing visibility to sibling
    # code; +git init+ or invoke from the project root to fix).
    #
    # == Safety bounds
    #
    # The climb refuses to enter the home directory or a system root
    # ({DENIED_CLIMB_ROOTS}) — reaching either means "left the project tree" and
    # the climb stops. The starting +cwd+ is always considered even if banned
    # (the user invoked there); only ancestors are gated.
    #
    # == Priority
    #
    # All {VCS_MARKERS} are checked at each ancestor before climbing, so the
    # *nearest* VCS marker wins regardless of type.
    module ProjectRoot
      # Climb-up boundary. Overlaps {Pikuri::Workspace::Filesystem::DENIED_PROJECT_ROOTS}
      # but kept separate — different semantics (climb boundary vs. project_root
      # rejection), may drift apart.
      DENIED_CLIMB_ROOTS = %w[
        / /etc /var /proc /sys /dev /boot /root
        /usr /opt /lib /lib64 /bin /sbin /tmp
      ].map { |p| Pathname.new(p) }.freeze

      # VCS metadata dirs/files. +.git+ is the common case; +.hg+/+.svn+ for the
      # rare users on those. +File.exist?+ matches both a directory (normal
      # checkout) and a regular file (+.git+ in a worktree/submodule).
      VCS_MARKERS = %w[.git .hg .svn].freeze

      # Find the nearest ancestor of +cwd+ containing any of {VCS_MARKERS}. See
      # the class header for the safety bounds and priority.
      #
      # @param cwd [String, Pathname] starting dir; +realpath+'d so symlinked
      #   checkouts don't bounce out of the tree.
      # @return [Pathname, nil] the matching ancestor, or +nil+ if none found
      #   within the safe-climb bounds (caller falls back to +cwd+).
      def self.find(cwd:)
        current = Pathname.new(cwd).realpath
        home = Pathname.new(Dir.home).realpath
        loop do
          return current if VCS_MARKERS.any? { |m| current.join(m).exist? }

          parent = current.parent
          return nil if parent == current     # at the filesystem root
          return nil if parent == home        # crossing into $HOME
          return nil if DENIED_CLIMB_ROOTS.include?(parent)

          current = parent
        end
      end
    end
  end
end
