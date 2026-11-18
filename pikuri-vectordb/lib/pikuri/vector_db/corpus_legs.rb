# frozen_string_literal: true

module Pikuri
  module VectorDb
    # The one derivation from a corpus's +private:+ / +trusted:+ declaration to
    # the {Pikuri::Tool::TrifectaLegs} every tool that returns corpus content
    # carries. An extension over a corpus calls it once and hands the result to
    # each reading tool:
    #
    #   legs = Pikuri::VectorDb::CorpusLegs.derive(private: true, trusted: false)
    #   legs.private                # => true
    #   legs.untrusted              # => :hard   (:none once the owner vouches)
    #   legs.egress_payload_review  # => :no_egress, always — retrieval never leaves the machine
    #
    # What the two inputs mean — the three clauses behind +trusted: true+ in
    # particular — is {Corpus#private?} / {Corpus#trusted?}'s to say;
    # this module only maps them.
    module CorpusLegs
      # @param private [Boolean] the corpus may hold data worth exfiltrating.
      # @param trusted [Boolean] every byte in the corpus is the user's own,
      #   reviewed in the form the model reads it.
      # @return [Pikuri::Tool::TrifectaLegs]
      def self.derive(private:, trusted:)
        Pikuri::Tool::TrifectaLegs.new(
          private: private,
          untrusted: trusted ? :none : :hard,
          egress_payload_review: :no_egress
        )
      end
    end
  end
end
