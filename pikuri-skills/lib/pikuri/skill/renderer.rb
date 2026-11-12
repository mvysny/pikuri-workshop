# frozen_string_literal: true

module Pikuri
  module Skill
    # Turns {Catalog::Skill} data into the Agent Skills XML the model actually
    # reads. Three renders, all stateless:
    #
    # - {format_catalog} — the +<available_skills>+ inventory for the system
    #   prompt (advertises what's loadable):
    #
    #     <available_skills>
    #       <skill>
    #         <name>pdf-tools</name>
    #         <description>Extracts text from PDFs.</description>
    #       </skill>
    #     </available_skills>
    #
    # - {format_promotion} — the same inventory shape, injected mid-loop when a
    #   touched file brings gated skills into play. Carries +<when-to-use>+
    #   where the catalog block doesn't, since a promotion is a pitch for one
    #   moment rather than a resident line item.
    #
    # Neither inventory render carries the skill's path, only {format_skill}
    # does — which the standard sanctions outright ("if your dedicated
    # activation tool provides the skill directory path in its result, you can
    # omit +location+ from the catalog"). An inventory entry is a routing
    # decision, and a path is unusable until the body names what to read; on a
    # 28-skill catalog the duplicate ran ~400 resident tokens.
    #
    # - {format_skill} — one skill's body block, injected when the skill is
    #   loaded (by the +skill+ tool or a host-driven load):
    #
    #     <skill name="pdf-tools" location="/repo/.pikuri/skills/pdf-tools/SKILL.md">
    #     Sidecar paths in this skill (e.g. scripts/, references/) are relative to /repo/.pikuri/skills/pdf-tools.
    #
    #     <the SKILL.md body>
    #     </skill>
    #
    # Presentation lives here, not on {Catalog} (which stays pure discovery /
    # validation / holding) nor on {SkillTool} (a callable action): both
    # renders have callers in different classes whose only shared handle is
    # the catalog data, so a stateless module reached with that data fits
    # both without handle-passing.
    module Renderer
      module_function

      # The +<available_skills>+ inventory block, or +""+ for an empty list (so
      # callers concatenate unconditionally). Leads with two blank lines;
      # callers joining prompt sections +lstrip+ as needed.
      #
      # @param skills [Array<Pikuri::Skill::Catalog::Skill>] what to advertise —
      #   the caller has already dropped whatever it means to withhold
      # @return [String]
      def format_catalog(skills)
        return '' if skills.empty?

        lines = [
          '',
          '',
          'The following skills provide specialized instructions for specific tasks.',
          "When a skill matches the task, load it with the `skill` tool *before* answering from your own knowledge — the skill's instructions take precedence over your training. If none matches, just proceed normally.",
          '',
          '<available_skills>'
        ]
        skills.each { |skill| lines.concat(entry_lines(skill, trigger: false)) }
        lines << '</available_skills>'
        lines.join("\n")
      end

      # The mid-loop promotion block: skills a touched file just brought into
      # play, in the same shape the catalog block uses *and carrying the same
      # instruction*, so the model reads it the way it reads the resident one.
      #
      # The trailing instruction is not decoration. Announced as mere
      # availability, a promotion loses to whatever the model already believes
      # is a sufficient answer — observed on a local Qwen3.6, which named the
      # promoted skill in its own reasoning, resolved to load it, then read a
      # neighbouring source file instead and imitated its style. Imitation
      # transmits *presence* and never *absence*, so every rule of the form
      # "delete this" was lost. Hence the precedence clause names inferred
      # house style alongside training, and the +if none matches+ escape rides
      # with it so a coarse glob's false positive is cheap to decline.
      #
      # @param skills [Array<Pikuri::Skill::Catalog::Skill>] newly in play;
      #   never empty (a caller with nothing to announce injects nothing)
      # @return [String]
      def format_promotion(skills)
        lines = [
          'These skills just became relevant to the files you are working with, and are now loadable:',
          '',
          '<available_skills>'
        ]
        skills.each { |skill| lines.concat(entry_lines(skill, trigger: true)) }
        lines << '</available_skills>'
        lines << ''
        lines << 'If one matches what you are about to do, load it with the `skill` tool first — its ' \
                 'instructions take precedence over your training and over any convention you infer ' \
                 'from the surrounding code. If none matches, just proceed normally.'
        lines.join("\n")
      end

      # One skill's +<skill>+ body block: the wrapper carries +name+ and
      # +location+ so the model resolves relative sidecar paths against the
      # skill's directory via the +read+ tool.
      #
      # @param skill [Pikuri::Skill::Catalog::Skill]
      # @return [String]
      def format_skill(skill)
        base_dir = File.dirname(skill.location)
        <<~OUT
          <skill name="#{escape_xml(skill.name)}" location="#{escape_xml(skill.location)}">
          Sidecar paths in this skill (e.g. scripts/, references/) are relative to #{base_dir}.

          #{skill.body}
          </skill>
        OUT
      end

      # One +<skill>+ element. With +trigger:+, a declared +when-to-use+ rides
      # along and {Trigger} keeps the two fields from saying the same thing
      # twice — the description loses the tail it duplicates, the value loses
      # the connective the tag already supplies.
      def entry_lines(skill, trigger:)
        show_trigger = trigger && !skill.when_to_use.nil?
        description = show_trigger ? Trigger.strip_suffix(skill.description) : skill.description

        lines = ['  <skill>', "    <name>#{escape_xml(skill.name)}</name>",
                 "    <description>#{escape_xml(description)}</description>"]
        lines << "    <when-to-use>#{escape_xml(Trigger.strip_prefix(skill.when_to_use))}</when-to-use>" if show_trigger
        lines << '  </skill>'
      end
      private_class_method :entry_lines

      # @param str [String]
      # @return [String] +str+ with XML metacharacters entity-escaped.
      def escape_xml(str)
        str.gsub('&', '&amp;')
           .gsub('<', '&lt;')
           .gsub('>', '&gt;')
           .gsub('"', '&quot;')
           .gsub("'", '&apos;')
      end
      private_class_method :escape_xml
    end
  end
end
