# frozen_string_literal: true

module Pikuri
  module Skill
    # Discovery + validation of *skills* — Markdown files with YAML
    # frontmatter that the agent loads on demand via {SkillTool}.
    #
    # A skill is a directory containing a +SKILL.md+ whose frontmatter
    # declares +name+ and +description+. Sibling files (scripts,
    # references, templates) are sidecar content the LLM pulls in via
    # the regular +read+ tool against +File.dirname(location)+. Pikuri
    # implements the {https://agentskills.io/specification Agent Skills
    # standard} leniently — only a missing +description+ is fatal.
    #
    # Two concrete subclasses ship: {Empty} (the +EMPTY+ singleton)
    # and {Bundled} (the on-disk scanner). Hosts that read skills from
    # something other than the filesystem (virtual FS, hardcoded
    # registry) subclass directly.
    #
    # == +paths:+ is not access control
    #
    # A gated skill ({Skill#gated?}) is withheld from the catalog render and
    # refused by name until a matching file is touched — but nothing is
    # *restricted*, because the gated party controls the trigger: a model that
    # wants a hidden skill need only read a file its globs match. The honest
    # formulation is **unreachable by ignorance, not by permission**, and
    # ignorance is not a security boundary. Anything wanting a real
    # restriction wants +disable-model-invocation:+, which pikuri does not
    # implement.
    #
    # This catalog is itself deliberately *unfiltered*: frozen, session-less
    # holding, with the gate in its callers. So a host enumerating {#list} for
    # a skill picker re-exposes every gated skill — a picker asks
    # {Activation} instead.
    class Catalog
      # Frontmatter +name+ cap per the Agent Skills standard.
      MAX_NAME_LENGTH = 64

      # Frontmatter +description+ cap per the Agent Skills standard.
      MAX_DESCRIPTION_LENGTH = 1024

      LOGGER = Pikuri.logger_for('Skills')
      private_constant :LOGGER

      # A loaded skill record. Bodies are eager-loaded at scan time;
      # SKILL.md files are small and the tool's hot path stays IO-free.
      #
      # @!attribute [r] name
      #   @return [String] the name the model loads it by
      # @!attribute [r] description
      #   @return [String] what it does, and (often) when to use it
      # @!attribute [r] location
      #   @return [String] absolute path of the SKILL.md
      # @!attribute [r] body
      #   @return [String] everything after the frontmatter
      # @!attribute [r] paths
      #   @return [Array<String>] normalized +paths:+ patterns; empty means
      #     advertised unconditionally — see {PathMatcher} before reading an empty
      #     one as "matches nothing"
      # @!attribute [r] when_to_use
      #   @return [String, nil] the +when-to-use:+ trigger sentence, +nil+ when
      #     the frontmatter carried none. Answers *is this the moment?* where
      #     {#paths} answers *is this ecosystem in play?*; they compose.
      Skill = Data.define(:name, :description, :location, :body, :paths, :when_to_use) do
        # @return [Skill]
        def initialize(name:, description:, location:, body:,
                       paths: PathMatcher::UNCONDITIONAL, when_to_use: nil)
          super
        end

        # @return [Boolean] true when this skill stays withheld until a tool
        #   touches a file matching {#paths}
        def gated? = !paths.empty?
      end

      # The +untrusted+ trifecta leg {SkillTool} declares.
      #
      # +:hard+ in the base class: a subclass loading skills from somewhere
      # this class cannot see makes no claim about their provenance, and
      # silence buys the pessimistic value.
      #
      # @return [Symbol] +:none+ or +:hard+
      def untrusted_level = :hard

      # @return [Array<Skill>] skills in discovery order (which equals
      #   precedence order).
      # @raise [NotImplementedError] in the abstract base
      def list
        raise NotImplementedError, "#{self.class}#list must be implemented"
      end

      # @param name [String]
      # @return [Skill, nil]
      # @raise [NotImplementedError] in the abstract base
      def get(name)
        raise NotImplementedError, "#{self.class}#get must be implemented"
      end

      # @return [Boolean] true when {#list} is empty; an empty catalog
      #   contributes no tool and no prompt block.
      def empty?
        list.empty?
      end

      # Absolute paths of the skill directories this catalog covers.
      # Hosts wire these into +Pikuri::Workspace::Filesystem+'s
      # +readable:+ list so the LLM can +read+ sidecar files.
      #
      # @return [Array<String>]
      # @raise [NotImplementedError] in the abstract base
      def roots
        raise NotImplementedError, "#{self.class}#roots must be implemented"
      end

      # Null-object catalog. The +EMPTY+ constant is the singleton used
      # as the default when no skills are wired in.
      class Empty < Catalog
        def list
          [].freeze
        end

        def get(_name)
          nil
        end

        def roots
          [].freeze
        end

        # @return [Symbol] +:none+ — a catalog that loaded no bytes contributes
        #   no untrusted content, which is the union over zero skills
        def untrusted_level = :none
      end

      # Shared singleton for the no-skills case.
      EMPTY = Empty.new.freeze

      # On-disk catalog over a list of *search bases* (project root,
      # home dir, …). Under each base it scans +.pikuri/skills+ (the
      # user's own), +.claude/skills+ (Claude Code skills ride along)
      # and +.agents/skills+ (PI's cross-harness convention), in that
      # order; missing subdirs are skipped.
      #
      # == Precedence
      #
      # Bases left to right, subdirs in the order above; the *first*
      # skill seen for a name wins, later ones dropped with a warning.
      # Pass the project root first for "project beats global".
      #
      # == Validation
      #
      # The Agent Skills standard is enforced leniently: a missing
      # +description+ is the only hard failure (skill skipped). Name/dir
      # mismatch, oversized name/description, invalid name chars, a +paths:+
      # that is neither a string nor a list of them, and malformed YAML log a
      # warning and load anyway. A file with no frontmatter is skipped silently
      # (not meant as a skill). Note which way the +paths:+ failure falls: a
      # value this class cannot read leaves the skill advertised, never hidden.
      #
      # == Trust
      #
      #   Bundled.new(search_bases: [
      #     Pikuri::Bundle::Base.new(dir: project_root, trusted: repo_sources_are_mine),
      #     Pikuri::Bundle::Base.new(dir: Dir.home)
      #   ])
      #
      # Per-base {Pikuri::Bundle::Base#trusted} unions into one
      # {#untrusted_level} at scan time, because {SkillTool} declares its legs
      # once: a single skill from an unvouched base takes the whole catalog to
      # +:hard+. The union counts a skill at the point it *wins its name*, so
      # an untrusted base costs nothing when it is empty or when its skills all
      # lost a collision — a host may therefore name a base it knows nothing
      # about and still report +:none+ for the user who turns out to have no
      # skills there.
      #
      # A host that can *rule out* writes to a base may vouch for it without
      # asking anyone: +bin/pikuri-code+ does this for +Dir.home+, since skill
      # roots ride in the workspace's +readable:+ and never its +writable:+, so
      # nothing but the user's own hand puts a skill there.
      class Bundled < Catalog
        # Subdirectory names scanned under each search base, in
        # precedence order.
        SKILL_SUBDIRS = ['.pikuri/skills', '.claude/skills', '.agents/skills'].freeze
        private_constant :SKILL_SUBDIRS

        # @param search_bases [Array<Pikuri::Bundle::Base, String, Pathname>]
        #   directories under which to look for skill subdirs. Typical values:
        #   the project root and +Dir.home+. Processed left to right. A bare
        #   path means +Bundle::Base.new(dir: path)+ — untrusted, so the unsafe
        #   value is the one you get by saying nothing.
        # @return [Bundled]
        def initialize(search_bases:)
          super()
          @roots = []
          @skills = {}
          @untrusted = false

          search_bases.each do |entry|
            base = entry.is_a?(Bundle::Base) ? entry : Bundle::Base.new(dir: entry)
            SKILL_SUBDIRS.each do |sub|
              root = File.join(base.dir.to_s, sub)
              next unless File.directory?(root)

              @roots << root
              scan_root(root, trusted: base.trusted)
            end
          end

          @roots.freeze
          @skills.freeze
          @list = @skills.values.freeze
          freeze
        end

        # @return [Array<Skill>]
        def list
          @list
        end

        # @param name [String]
        # @return [Skill, nil]
        def get(name)
          @skills[name]
        end

        # @return [Array<String>] absolute paths of the existing skill
        #   directories this catalog covered, in scan order.
        attr_reader :roots

        # @return [Symbol] +:none+ when every skill this catalog stored came
        #   from a +trusted+ base, else +:hard+
        def untrusted_level = @untrusted ? :hard : :none

        private

        def scan_root(root, trusted:)
          Dir.children(root).sort.each do |entry|
            skill_dir = File.join(root, entry)
            next unless File.directory?(skill_dir)

            skill_md = File.join(skill_dir, 'SKILL.md')
            next unless File.file?(skill_md)

            skill = parse_skill(skill_md, parent_dir_name: entry)
            next if skill.nil?

            existing = @skills[skill.name]
            if existing
              LOGGER.warn(
                "skill name '#{skill.name}' at #{skill_md} is shadowed by " \
                "earlier entry at #{existing.location}"
              )
            else
              @skills[skill.name] = skill
              @untrusted ||= !trusted
            end
          end
        end

        # Read +path+ and return a {Skill}, or +nil+ if the file is
        # unusable (no frontmatter, no description, unreadable).
        def parse_skill(path, parent_dir_name:)
          raw = File.read(path)
          frontmatter, body = Bundle::Frontmatter.split(raw, path: path)

          if frontmatter.nil?
            LOGGER.warn("#{path}: no YAML frontmatter; skipped")
            return nil
          end

          description = frontmatter['description'].to_s.strip
          if description.empty?
            LOGGER.warn("#{path}: missing required 'description'; skipped")
            return nil
          end

          name = (frontmatter['name'] || parent_dir_name).to_s
          validate_name(name, parent_dir_name: parent_dir_name, path: path)
          validate_description(description, path: path)

          Skill.new(
            name: name,
            description: description,
            location: path,
            body: body,
            paths: PathMatcher.parse(frontmatter['paths'], path: path),
            when_to_use: when_to_use_of(frontmatter)
          )
        rescue Errno::ENOENT, Errno::EACCES => e
          LOGGER.warn("#{path}: #{e.class}: #{e.message}; skipped")
          nil
        end

        # Both spellings: the documented hyphenated key, and the underscore
        # slip, which would otherwise lose the field without a sound.
        def when_to_use_of(frontmatter)
          value = (frontmatter['when-to-use'] || frontmatter['when_to_use']).to_s.strip
          value.empty? ? nil : value
        end

        def validate_name(name, parent_dir_name:, path:)
          if name != parent_dir_name
            LOGGER.warn("#{path}: skill name '#{name}' does not match parent directory '#{parent_dir_name}'")
          end
          if name.length > MAX_NAME_LENGTH
            LOGGER.warn("#{path}: skill name exceeds #{MAX_NAME_LENGTH} chars (#{name.length})")
          end
          unless /\A[a-z0-9-]+\z/.match?(name)
            LOGGER.warn("#{path}: skill name '#{name}' contains invalid characters " \
                        "(allowed: lowercase a-z, 0-9, hyphens)")
          end
          if name.start_with?('-') || name.end_with?('-')
            LOGGER.warn("#{path}: skill name '#{name}' starts or ends with a hyphen")
          end
          return unless name.include?('--')

          LOGGER.warn("#{path}: skill name '#{name}' contains consecutive hyphens")
        end

        def validate_description(description, path:)
          return unless description.length > MAX_DESCRIPTION_LENGTH

          LOGGER.warn(
            "#{path}: description exceeds #{MAX_DESCRIPTION_LENGTH} chars (#{description.length})"
          )
        end
      end
    end
  end
end
