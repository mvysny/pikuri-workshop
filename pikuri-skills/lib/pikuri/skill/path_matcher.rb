# frozen_string_literal: true

module Pikuri
  module Skill
    # Parses a skill's +paths:+ frontmatter key — **gitignore pattern syntax**,
    # ripgrep's flavour of it — and answers whether a touched file fires what it
    # parsed:
    #
    #   patterns = PathMatcher.parse('{app,lib}/**/*.rb, docs', path: md)
    #   # => ["{app,lib}/**/*.rb", "docs"]
    #   PathMatcher.match?(patterns, 'lib/pikuri/agent.rb')   # => true
    #   PathMatcher.match?(patterns, 'spec/agent_spec.rb')    # => false
    #   PathMatcher.parse(nil, path: md)                      # => [] — advertised always
    #
    # A scalar comma-splits; a trailing +/**+ goes, because gitignore matches a
    # directory and its contents either way and +src+ / +src/**+ should compare
    # equal.
    #
    # == Implementation details
    #
    # {UNCONDITIONAL} is an inversion trap worth knowing before you author
    # frontmatter: +paths: []+, +paths: ["**"]+ and a bare +paths:+ with
    # nothing under it all mean *advertise unconditionally* — the opposite of
    # what "this skill matches no paths" is meant to say, and where an
    # unreadable value lands too, which is why that one warns. Both harnesses
    # that honour the key read it this way; hiding a skill from the model is a
    # different key's job.
    #
    # Gitignore syntax is the rules a +.gitignore+ author already has, and they
    # are emphatically not minimatch's: a slash-less pattern floats to any depth
    # (+build.gradle+ fires on +app/build.gradle+), a pattern carrying a slash
    # anywhere is rooted at the workspace root (+src/main+ never fires on
    # +vendor/src/main+), a bare directory covers everything beneath it, and
    # +{app,lib}+ expands. {match?} gets the directory rule by walking the
    # touched path's ancestors, and reads no filesystem — a +write+ to a path
    # that does not exist yet still fires. +COMPARISON.md+ (*Skills →
    # Frontmatter*) carries the measurement behind each rule.
    module PathMatcher
      # The normalized form of "no gate": this skill is advertised on every
      # turn, like a skill that never mentioned +paths:+ at all.
      UNCONDITIONAL = [].freeze

      LOGGER = Pikuri.logger_for('Skills')
      private_constant :LOGGER

      # +FNM_PATHNAME+ keeps a +*+ inside one path segment, +FNM_EXTGLOB+
      # expands +{app,lib}+ — which ripgrep's gitignore accepts and git itself
      # does not, so the harnesses honouring +paths:+ are the ones to follow —
      # and +FNM_DOTMATCH+ lets +**+ descend into +.claude/+.
      FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
      private_constant :FNMATCH_FLAGS

      module_function

      # @param value [String, Array<String>, nil] the raw frontmatter +paths:+
      #   value; +nil+ when the key is absent
      # @param path [String] the SKILL.md location, used in warnings only
      # @return [Array<String>] frozen normalized patterns, or {UNCONDITIONAL}
      def parse(value, path:)
        return UNCONDITIONAL if value.nil?

        patterns = coerce(value)
        if patterns.nil?
          LOGGER.warn("#{path}: 'paths:' must be a string or a list of strings, got " \
                      "#{value.class}; ignored, so the skill stays unconditional")
          return UNCONDITIONAL
        end

        normalize(patterns)
      end

      # Whether a touched file fires any of these patterns.
      #
      #   PathMatcher.match?(['ideas'], 'ideas/sub/note.md')          # => true
      #   PathMatcher.match?(['src/main'], 'other/src/main/A.java')   # => false — rooted
      #
      # @param patterns [Array<String>] as {parse} returns; {UNCONDITIONAL}
      #   matches nothing, since a skill with no gate is never asked
      # @param path [String] the touched file, relative to the workspace root
      # @return [Boolean]
      # @raise [ArgumentError] on an absolute path — the caller resolves a
      #   model-supplied one against the workspace root first, and a path left
      #   absolute would quietly match against the wrong tree
      def match?(patterns, path)
        raise ArgumentError, "path must be workspace-relative, got #{path.inspect}" if path.start_with?('/')

        segments = path.delete_prefix('./').split('/')
        ancestors = (1..segments.size).map { |depth| segments.first(depth).join('/') }
        patterns.any? do |pattern|
          glob = glob_for(pattern)
          ancestors.any? { |ancestor| File.fnmatch?(glob, ancestor, FNMATCH_FLAGS) }
        end
      end

      # gitignore's two structural rules as one fnmatch glob: a slash roots the
      # pattern at the workspace, its absence floats it to any depth. Decide
      # that *before* dropping the suffixes — a +src/**+ that survived
      # normalization is rooted, and stripping first would float it onto
      # +other/src/+.
      def glob_for(pattern)
        bare = pattern.chomp('/')
        glob = bare.delete_suffix('/**').delete_prefix('/')
        bare.include?('/') ? glob : "**/#{glob}"
      end
      private_class_method :glob_for

      def coerce(value)
        case value
        when String then split_top_level(value)
        when Array then value.all?(String) ? value.flat_map { |s| split_top_level(s) } : nil
        end
      end
      private_class_method :coerce

      def normalize(patterns)
        cleaned = patterns.map { |p| p.strip.delete_suffix('/**') }.reject(&:empty?)
        return UNCONDITIONAL if cleaned.empty? || cleaned.all?('**')

        cleaned.freeze
      end
      private_class_method :normalize

      # Comma-split that leaves +{js,ts}+ intact.
      def split_top_level(str)
        parts = [+'']
        depth = 0
        str.each_char do |char|
          case char
          when '{' then depth += 1
          when '}' then depth -= 1 if depth.positive?
          when ','
            if depth.zero?
              parts << +''
              next
            end
          end
          parts.last << char
        end
        parts.map(&:strip).reject(&:empty?)
      end
      private_class_method :split_top_level
    end
  end
end
