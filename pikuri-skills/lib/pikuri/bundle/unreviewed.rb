# frozen_string_literal: true

module Pikuri
  module Bundle
    # The bundle files under a project that no commit vouches for: untracked,
    # gitignored, changed since +HEAD+, or a symlink. An agent with a +write+
    # tool can create +.claude/skills/x/SKILL.md+ without a prompt, and the
    # next session loads it, so a host grades such a project as untrusted
    # instead of asking the human "did you write these?":
    #
    #   roots = Pikuri::Skill::Catalog::Bundled.new(search_bases: [root]).roots
    #   Pikuri::Bundle::Unreviewed.files(repo: root, roots: roots)
    #   # => [".claude/skills/helpful/SKILL.md"]   untracked: an agent may have written it
    #   # => []                                    every file matches HEAD
    #   # => nil                                   not a git work tree: nothing to review against
    #
    # == Implementation details
    #
    # Compares bytes, not +git status+: each file's +git hash-object
    # --no-filters+ against its blob in +git ls-tree HEAD+. +status+ can run
    # a repo's clean filters and +core.fsmonitor+, which a project you didn't
    # write controls; hashing with filters off runs nothing from the repo.
    # Any git output this can't parse counts every file as unreviewed.
    module Unreviewed
      module_function

      # @param repo [Pathname, String] the project root; git runs here, and
      #   returned paths are relative to it
      # @param roots [Array<Pathname, String>] absolute bundle directories
      #   under +repo+ (a catalog's or a command registry's +roots+)
      # @return [Array<String>, nil] unvouched file paths, sorted; +nil+ when
      #   +repo+ is not inside a git work tree
      def files(repo:, roots:)
        repo = Pathname(repo).realpath
        return nil unless git(repo, 'rev-parse', '--is-inside-work-tree').status.success?

        on_disk = roots.map { |root| Pathname(root).realpath }
                       .flat_map { |root| walk(root) }
                       .map { |file| file.relative_path_from(repo).to_s }.uniq.sort
        return [] if on_disk.empty?

        committed = committed_blobs(repo, on_disk)
        current = current_blobs(repo, on_disk.reject { |path| (repo + path).symlink? })
        on_disk.reject { |path| committed[path] && committed[path] == current[path] }
      end

      # @return [Array<Pathname>] every file and symlink under +root+
      def walk(root)
        Dir.glob('**/*', File::FNM_DOTMATCH, base: root.to_s)
           .map { |rel| root + rel }
           .select { |path| path.symlink? || path.file? }
      end

      # @return [Hash{String => String}] path → blob id at HEAD; empty when
      #   there is no HEAD yet
      def committed_blobs(repo, paths)
        result = git(repo, 'ls-tree', '-r', '-z', 'HEAD', '--', *paths)
        return {} unless result.status.success?

        result.output.split("\0").filter_map do |entry|
          entry.match(/\A100(?:644|755) blob (\h+)\t(.+)\z/m)&.captures&.reverse
        end.to_h
      end

      # @return [Hash{String => String}] path → blob id of the bytes on disk
      def current_blobs(repo, paths)
        return {} if paths.empty?

        result = git(repo, 'hash-object', '--no-filters', '--', *paths)
        ids = result.output.lines(chomp: true)
        return {} unless result.status.success? && ids.size == paths.size && ids.all? { |id| id.match?(/\A\h+\z/) }

        paths.zip(ids).to_h
      end

      # @return [Pikuri::Subprocess::Result]
      def git(repo, *args)
        Pikuri::Subprocess.spawn('git', '--literal-pathspecs', '-c', 'core.fsmonitor=false', *args,
                                 chdir: repo).wait
      end

      private_class_method :walk, :committed_blobs, :current_blobs, :git
    end
  end
end
