# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Tokenizer
      # Approximate token count at {CHARS_PER_TOKEN} characters per token — the
      # zero-dep default, no network round-trip.
      #
      #   CharHeuristic.new.count('abcdefghijklmnopq')   # => 5 (17 / 4, rounded up)
      #
      # English BPE tokenizers (GPT, llama, BGE, sentence-transformers) settle
      # around 3.5–4.5 chars/token on prose; code drops to ~3, CJK to ~1–2.
      # A corpus like that wants an exact tokenizer passed to the chunker
      # instead (see {Tokenizer}'s protocol).
      class CharHeuristic
        # Characters per token: the English-prose sweet spot.
        #
        # @return [Float]
        CHARS_PER_TOKEN = 4.0

        # Empty string counts 0; a short one rounds up to at least 1.
        #
        # @param text [String]
        # @return [Integer] approximate token count, +>= 0+.
        def count(text)
          return 0 if text.empty?

          (text.length / CHARS_PER_TOKEN).ceil
        end
      end
    end
  end
end
