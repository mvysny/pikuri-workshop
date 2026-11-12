# frozen_string_literal: true

require 'set'

module Pikuri
  module Skill
    # Which of a catalog's gated skills are in play *this conversation*. A
    # skill declaring +paths:+ is withheld until a tool touches a matching
    # file; until it fires, it is unloadable by name and invisible to a
    # refusal's list of what does exist:
    #
    #   activation = Activation.new(catalog: catalog)
    #   activation.get('writing-rdoc')          # => nil — withheld, same as an unknown name
    #   activation.activate([rdoc])             # => [rdoc]  — announce these
    #   activation.activate([rdoc])             # => []      — already announced
    #   activation.get('writing-rdoc')          # => #<Skill name="writing-rdoc" …>
    #   activation.reset                        # a cleared conversation re-hides it
    #
    # == Implementation details
    #
    # Neither this state nor the gate lives on the {Catalog}: it is frozen,
    # session-less and shared, and a filtered +Catalog#get+ would also lie to
    # an installed-skills listing. The catalog keeps telling the truth about
    # what is on disk; every *invocation* route resolves through here instead.
    #
    # Thread-safe.
    class Activation
      # @param catalog [Pikuri::Skill::Catalog] held, never mutated
      def initialize(catalog:)
        @catalog = catalog
        @activated = Set.new
        @mutex = Mutex.new
      end

      # @return [Pikuri::Skill::Catalog] the unfiltered catalog behind this view
      attr_reader :catalog

      # @param name [String]
      # @return [Boolean] false for an unknown name, and for a gated skill
      #   whose path has not fired yet
      def in_play?(name)
        skill = @catalog.get(name)
        return false if skill.nil?

        !skill.gated? || @mutex.synchronize { @activated.include?(name) }
      end

      # {Catalog#get} as this conversation sees it.
      #
      # @param name [String]
      # @return [Pikuri::Skill::Catalog::Skill, nil] +nil+ when withheld —
      #   which is the same answer a name that exists nowhere gets, so a
      #   refusal cannot be read as "exists, but hidden"
      def get(name)
        in_play?(name) ? @catalog.get(name) : nil
      end

      # @return [Array<String>] sorted names in play; the only enumeration a
      #   refusal or a listing may recite
      def names
        @catalog.list.filter_map { |skill| skill.name if in_play?(skill.name) }.sort
      end

      # Record a promotion and answer what is new: a skill is announced at most
      # once per conversation, however many matching files are touched.
      #
      # @param skills [Array<Pikuri::Skill::Catalog::Skill>]
      # @return [Array<Pikuri::Skill::Catalog::Skill>] those not already
      #   activated, in the given order
      def activate(skills)
        @mutex.synchronize { skills.select { |skill| @activated.add?(skill.name) } }
      end

      # Re-hide every gated skill.
      #
      # @return [void]
      def reset
        @mutex.synchronize { @activated.clear }
        nil
      end
    end
  end
end
