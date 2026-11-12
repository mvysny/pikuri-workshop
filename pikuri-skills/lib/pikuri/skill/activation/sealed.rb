# frozen_string_literal: true

module Pikuri
  module Skill
    class Activation
      # An {Activation} with the door welded shut: gated skills stay withheld
      # for the whole run, and promoting one raises.
      #
      #   sealed = Activation::Sealed.new(catalog: catalog)
      #   sealed.get('data-viz')      # => #<Skill …> — ungated skills load normally
      #   sealed.get('writing-rdoc')  # => nil — gated, and nothing can change that
      #   sealed.activate([rdoc])     # => raises
      #
      # What a spawned sub-agent's +skill+ tool resolves against. A sub-agent
      # inherits no extension, so no listener ever fires for it, and its prompt
      # carries no catalog at all — a gated skill is a name it was never told,
      # and reaching one through the parent's promotions would make the child's
      # surface depend on which files the parent happened to read.
      #
      # The raise is an assertion, not a policy: nothing can legitimately
      # promote here, so a caller that turns up is a wiring bug worth seeing.
      #
      # Thread-safe.
      class Sealed
        # @param catalog [Pikuri::Skill::Catalog] held, never mutated
        def initialize(catalog:)
          @catalog = catalog
        end

        # @return [Pikuri::Skill::Catalog] the unfiltered catalog behind this view
        attr_reader :catalog

        # @param name [String]
        # @return [Boolean] true only for a skill that declared no gate
        def in_play?(name)
          skill = @catalog.get(name)
          !skill.nil? && !skill.gated?
        end

        # @param name [String]
        # @return [Pikuri::Skill::Catalog::Skill, nil] +nil+ for a gated skill,
        #   the same answer a name that exists nowhere gets
        def get(name)
          in_play?(name) ? @catalog.get(name) : nil
        end

        # @return [Array<String>] sorted names of the ungated skills
        def names
          @catalog.list.reject(&:gated?).map(&:name).sort
        end

        # @param skills [Array<Pikuri::Skill::Catalog::Skill>]
        # @return [void] never returns
        # @raise [RuntimeError] always
        def activate(skills)
          raise "a sealed Activation cannot promote #{skills.map(&:name).join(', ')} — " \
                'nothing should path-activate a skill inside a sub-agent'
        end

        # @return [void] no-op: there is never anything to clear
        def reset = nil
      end
    end
  end
end
