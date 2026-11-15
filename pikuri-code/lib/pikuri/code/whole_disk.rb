# frozen_string_literal: true

module Pikuri
  module Code
    # A {Pikuri::Workspace::Filesystem} over the whole disk: every path
    # resolves, for reading and writing, except those under +denylist:+
    # (default {DEFAULT_CREDENTIAL_DENYLIST}: +~/.ssh+, +~/.aws+, …,
    # +/etc/shadow+):
    #
    #   # --yolo, inside a VM: the denylist keeps the file tools off your keys
    #   Pikuri::Code::WholeDisk.new(project_root:, private: private_repo)
    #
    #   # the OS assistant: its cut network is the wall, so no denylist
    #   Pikuri::Code::WholeDisk.new(project_root: Dir.pwd, denylist: [], private: true)
    #
    # The denylist is a floor, not a boundary: a co-wired {Bash} reads +~/.ssh+
    # whatever the file tools refuse. Under {Bash::Sandbox::FullFsNoNet}, where
    # nothing can carry a key out anyway, pass +denylist: []+; half a floor
    # there is for show. {Bash::Sandbox::Bubblewrap} refuses a WholeDisk, since
    # containing +bash+ to a subset of the disk is moot when the subset is the
    # disk.
    #
    # Over a plain Filesystem it also lifts the project-root guard, so
    # +project_root:+ may be +~+ (where an OS helper is usually started) or +/+
    # (in a container), and it refuses +trusted: true+.
    #
    # == Implementation details
    #
    # {#denied?} answers from the denylist too, so pikuri's +file_list+, +glob+
    # and +grep+ hide what they walk to on their own
    # (+pikuri:D_walked_path_denylist+). Each entry is realpath'd at check time
    # when it exists, so a +decoy → ~/.ssh/id_rsa+ symlink inside the
    # workspace is caught; a missing entry falls back to a literal-prefix
    # match, which stops the agent *creating* a credential folder you lack.
    class WholeDisk < Pikuri::Workspace::Filesystem
      # The credential floor an unconfigured WholeDisk keeps: read, write, and
      # {#denied?} for anything a tool walks to. Expanded via +ENV['HOME']+ at
      # load, unioned with the +/root+ variants (a dev container's default
      # user). Frozen.
      DEFAULT_CREDENTIAL_DENYLIST = begin
        homes = [ENV.fetch('HOME', nil), '/root'].compact.uniq
        per_home = %w[.ssh .aws .gnupg .docker .kube .netrc]
        user_paths = homes.flat_map { |h| per_home.map { |p| File.join(h, p) } }
        (user_paths + %w[/etc/shadow]).map { |p| Pathname.new(p) }.uniq.freeze
      end

      # @return [Array<Pathname>] paths refused for read and write, and hidden
      #   from walks
      attr_reader :denylist

      # @param project_root [String, Pathname] anchors relative paths and
      #   +bash+'s starting folder; not a containment ceiling, and not checked
      #   against {Pikuri::Workspace::Filesystem::DENIED_PROJECT_ROOTS}.
      # @param denylist [Array<String, Pathname>] paths refused for read or
      #   write (symlink-resolved descendant match); default
      #   {DEFAULT_CREDENTIAL_DENYLIST}. Shrink it, or pass +[]+, only where
      #   egress is already cut or confirmed; elsewhere that reopens
      #   credential exfiltration.
      # @param private [Boolean] as in {Pikuri::Workspace::Filesystem#private?};
      #   usually right, a whole disk is exactly where someone means it.
      # @param trusted [Boolean] must be +false+; see
      #   {Pikuri::Workspace::Filesystem#trusted?}.
      # @raise [ArgumentError] if +trusted: true+: no one vouched for every
      #   byte on a disk
      # @raise [Errno::ENOENT] if +project_root+ doesn't exist
      def initialize(project_root: Dir.pwd, denylist: DEFAULT_CREDENTIAL_DENYLIST,
                     private: false, trusted: false)
        raise ArgumentError, 'trusted: is not representable on WholeDisk; scope the workspace instead' if trusted

        super(project_root:, writable: ['/'], private:)
        @denylist = denylist.map { |p| Pathname.new(p) }.uniq.freeze
      end

      # @param path [String, Pathname]
      # @return [Pathname]
      # @raise [Pikuri::Workspace::Filesystem::Error] if the resolved path lands
      #   under the denylist
      def resolve_for_read(path) = refuse_denied(path, super)

      # @param path [String, Pathname]
      # @return [Pathname]
      # @raise [Pikuri::Workspace::Filesystem::Error] if the resolved path lands
      #   under the denylist
      def resolve_for_write(path) = refuse_denied(path, super)

      # The walked-path gate (see {Pikuri::Workspace::Filesystem#denied?}).
      # Symlink-resolves +path+ first, so a +decoy → ~/.ssh+ inside the
      # workspace is caught though nothing handed it to a +resolve_+ call.
      #
      # @param path [String, Pathname]
      # @return [Boolean]
      def denied?(path) = !denying_root(normalize(path)).nil?

      # @return [Array<Pathname>] the denylist, for +rg+ to prune up front
      def denied_roots = @denylist

      private

      # Lifts the base class's project-root guard; see the class header.
      def validate_project_root!(_canonical) = nil

      # @param path [String, Pathname] what the model asked for, for the message
      # @param resolved [Pathname] already realpath-based, so it goes to the
      #   containment test directly rather than through {#denied?}
      # @return [Pathname] +resolved+
      def refuse_denied(path, resolved)
        denied = denying_root(resolved)
        return resolved unless denied

        raise Pikuri::Workspace::Filesystem::Error,
              "path '#{path}' resolves under a denied credential location " \
              "('#{denied}'); this workspace's denylist blocks it."
      end

      # @param resolved [Pathname] symlink-resolved absolute path
      # @return [Pathname, nil] the denylist entry containing +resolved+
      def denying_root(resolved)
        @denylist.find do |denied|
          candidate = denied.exist? ? denied.realpath : denied
          resolved.ascend.include?(candidate)
        end
      end

      # @return [Pathname] symlink-resolved; a lexical cleanup for a path that
      #   doesn't exist, since creating a credential folder must stay blocked
      def normalize(path)
        Pathname.new(path).realpath
      rescue SystemCallError
        Pathname.new(path).expand_path.cleanpath
      end
    end
  end
end
