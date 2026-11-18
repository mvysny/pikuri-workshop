# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for tokenizers: what {Chunker::FixedWindow} asks how full a
    # window is. One ships, {CharHeuristic}, the offline ~4-chars-per-token
    # rule.
    #
    # == Tokenizer protocol
    #
    # Duck-typed, single method: +#count(text) -> Integer+, +0+ for empty,
    # deterministic. Specs pass a one-token-per-word fake to get exact chunk
    # boundaries:
    #
    #   tokenizer = Object.new
    #   def tokenizer.count(text) = text.split.length
    #   Chunker::FixedWindow.new(size: 7, overlap: 2, tokenizer: tokenizer)
    #
    # A host whose corpus the heuristic miscounts (code, CJK) plugs an exact
    # tokenizer in the same way.
    module Tokenizer
    end
  end
end
