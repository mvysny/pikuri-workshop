# frozen_string_literal: true

module Pikuri
  module Skill
    # Cuts the trigger sentence a skill author writes *twice* — once as the
    # tail of +description:+, once as the whole of +when-to-use:+ — down to one
    # copy, for a render that carries both fields:
    #
    #   description = 'Weekly work log from git history. Use when the user asks for a work log.'
    #   when_to_use = 'Use when: the user asks for a weekly summary.'
    #
    #   Trigger.strip_suffix(description)   # => "Weekly work log from git history"
    #   Trigger.strip_prefix(when_to_use)   # => "the user asks for a weekly summary."
    #
    # Apply {strip_suffix} *only* when +when_to_use+ is present and actually
    # rendered: for a skill that declared no +when-to-use:+, that tail is the
    # only "when" the model gets and cutting it throws the trigger away.
    #
    # == Implementation details
    #
    # The two match differently. {strip_suffix} searches *anywhere* and always
    # cuts to the end, unguarded — a mid-sentence "use whenever" takes the rest
    # with it — while {strip_prefix} is start-anchored and word-boundary
    # guarded, so "Use whenever you need X" survives. Both are
    # case-insensitive but ASCII-only, and the connectives carry single literal
    # spaces: a YAML +>-+ folded value is safe, a +|+ block with a newline
    # mid-connective is not.
    module Trigger
      # How an author introduces the trigger half, most specific first where
      # one is a prefix of another.
      CONNECTIVES = [
        'use this skill when',
        'use when',
        'auto-invoke when',
        'invoke when',
        'triggers on',
        'trigger on',
        'called when',
        'must trigger when',
        'must invoke when',
        'must be invoked when'
      ].freeze
      private_constant :CONNECTIVES

      module_function

      # Cut a description back to its capability half, dropping the earliest
      # connective and everything after it.
      #
      #   Trigger.strip_suffix('Renders charts. Triggers on "plot", "graph".')
      #   # => "Renders charts"
      #
      # @param description [String]
      # @return [String] unchanged when it carries no connective, or opens with
      #   one — nothing is ever cut off the front
      def strip_suffix(description)
        downcased = description.downcase(:ascii)
        position = CONNECTIVES.filter_map { |connective| downcased.index(connective) }.min
        return description if position.nil?

        head = description[0...position].rstrip.delete_suffix('.')
        head.empty? ? description : head
      end

      # Cut a leading connective, and the punctuation behind it, off a
      # +when-to-use+ value, so a renderer's own "Use when:" label isn't
      # doubled.
      #
      #   Trigger.strip_prefix('Use whenever you touch the loop')
      #   # => "Use whenever you touch the loop"   (guarded: "when" + "ever")
      #
      # @param when_to_use [String]
      # @return [String] unchanged when it opens with no connective, or is
      #   nothing but one
      def strip_prefix(when_to_use)
        value = when_to_use.lstrip
        downcased = value.downcase(:ascii)

        CONNECTIVES.each do |connective|
          next unless downcased.start_with?(connective)

          rest = value[connective.length..]
          next if rest.match?(/\A[[:alnum:]]/)

          stripped = rest.sub(/\A[:,\s]+/, '')
          return stripped.empty? ? when_to_use : stripped
        end
        when_to_use
      end
    end
  end
end
