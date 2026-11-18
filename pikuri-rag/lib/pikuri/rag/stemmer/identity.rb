# frozen_string_literal: true

module Pikuri
  module Rag
    module Stemmer
      # The default stemmer: every word stands for itself.
      #
      #   Pikuri::Rag::Stemmer::Identity.stems('meetings')   # => ["meetings"]
      #   Pikuri::Rag::Stemmer::Identity.id                  # => "identity"
      #
      # Not a no-op in effect: the +porter+ tokenizer still stems English after
      # it, so "meetings" still finds "meeting". Part of the stemmer duck; see
      # {Stemmer} for the contract.
      module Identity
        # @return [String] +"identity"+.
        def self.id = 'identity'

        # @param word [String] one {Query.tokenize} token.
        # @return [Array<String>] +[word]+.
        def self.stems(word) = [word]

        # @param word [String] one {Query.tokenize} token.
        # @return [Array<String>] +[word]+.
        def self.index_stems(word) = [word]

        # A no-op: nothing is held open.
        #
        # @return [void]
        def self.close = nil
      end
    end
  end
end
