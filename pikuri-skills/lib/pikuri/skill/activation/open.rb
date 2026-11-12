# frozen_string_literal: true

module Pikuri
  module Skill
    class Activation
      # An {Activation} with no gate at all: every skill the catalog holds is
      # in play, +paths:+ or not, and promoting is a no-op because there is
      # nothing left to promote.
      #
      #   open = Activation::Open.new(catalog: catalog)
      #   open.get('writing-rdoc')      # => #<Skill …> — gated, and reachable anyway
      #   open.activate([rdoc])         # => [] — nothing to announce
      #
      # What {Extension} falls back to when the agent was built without an
      # +interloper:+. A promotion reaches the model only through mid-loop
      # injection, so an agent with no interloper has no channel to un-hide a
      # skill on — and a library must not hide what it cannot bring back. The
      # gate is off there, exactly as it was before +paths:+ existed.
      #
      # Thread-safe.
      class Open
        # @param catalog [Pikuri::Skill::Catalog] held, never mutated
        def initialize(catalog:)
          @catalog = catalog
        end

        # @return [Pikuri::Skill::Catalog]
        attr_reader :catalog

        # @param name [String]
        # @return [Boolean] true for any name the catalog holds
        def in_play?(name) = !@catalog.get(name).nil?

        # @param name [String]
        # @return [Pikuri::Skill::Catalog::Skill, nil]
        def get(name) = @catalog.get(name)

        # @return [Array<String>] every name the catalog holds, sorted
        def names = @catalog.list.map(&:name).sort

        # @param skills [Array<Pikuri::Skill::Catalog::Skill>]
        # @return [Array] always empty: nothing here was ever withheld, so
        #   announcing would introduce a skill the model has had all along
        def activate(_skills) = []

        # @return [void] no-op: there is never anything to clear
        def reset = nil
      end
    end
  end
end
