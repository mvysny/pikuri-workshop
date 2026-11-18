# frozen_string_literal: true

module Pikuri
  module Rag
    # Turns model-supplied text into safe FTS5 +MATCH+ input. Two shapes: a
    # list of terms to AND at the document level, and one OR expression to
    # rank by +bm25()+.
    #
    #   identity = Stemmer::Identity
    #   Query.terms('Acme pricing', stemmer: identity)        # => ['"acme"', '"pricing"']
    #   Query.any('what did we discuss?', stemmer: identity)  # => '"what" OR "did" OR "we" OR "discuss"'
    #   Query.terms('   ', stemmer: identity)                 # => []
    #
    # Each word is searched by its +#stems+, so a word with several readings
    # becomes an OR group within its term:
    #
    #   Query.terms('kadun hinnat', stemmer: finnish)   # => ['("katu" OR "katua")', '"hinta"']
    #
    # The stemmer must be the index's ({Backend::Fts5#stemmer}): the index
    # holds stems, so a query stemmed differently finds nothing.
    #
    # +MATCH+ is a mini-language — +AND+ / +OR+ / +NOT+, +*+ prefixes, +^+
    # anchors, +col:+ filters, phrase quotes, +()+ and +{}+ grouping — so a
    # stray quote or a leading +-+ in model text is an SQL *error*, not a
    # query that finds nothing. Every token comes out as a quoted phrase term,
    # which makes that syntax inert: +Query.any('acme OR initech')+ looks for
    # the literal word "or" alongside the two names. Not exposing the
    # operators is the point, so "Acme *or* Initech" is two searches.
    #
    # Nothing searchable comes back empty (or +nil+) rather than as an
    # expression that cannot match, so the caller answers the model instead of
    # asking SQLite a question with no terms in it.
    module Query
      # One term per word: its stem as a quoted phrase, or its stems as an OR
      # group of them.
      #
      #   Query.terms('Acme pricing', stemmer: Stemmer::Identity)   # => ['"acme"', '"pricing"']
      #
      # A list, not the juxtaposed +'"acme" "pricing"'+ FTS5 reads as an
      # implicit AND, because that AND is row-scoped and a row is a chunk —
      # so ANDing has to happen per document instead. {Fts5#find} does it, and
      # says what it costs.
      #
      # @param text [String] model-supplied terms, e.g. +"Acme pricing"+.
      # @param stemmer [#stems] the index's stemmer.
      # @return [Array<String>] one FTS5 expression per word; empty when
      #   +text+ holds no letters or digits.
      def self.terms(text, stemmer:)
        tokenize(text).map { |word| any_of(stemmer.stems(word)) }
      end

      # The OR form: any token may match, and +bm25()+ does the ranking.
      #
      # OR is right for +rag_search+, whose input is a natural-language
      # question: a twelve-word sentence ANDed matches nothing, and bm25's
      # inverse-document-frequency term already discounts the "what did we
      # discuss" words that appear in every document.
      #
      # @param text [String] model-supplied query, e.g.
      #   +"what did we agree about pricing?"+.
      # @param stemmer [#stems] the index's stemmer.
      # @return [String, nil] an FTS5 +MATCH+ expression ORing every stem of
      #   every word, or +nil+ when +text+ holds no letters or digits.
      def self.any(text, stemmer:)
        stems = tokenize(text).flat_map { |word| stemmer.stems(word) }.uniq
        return nil if stems.empty?

        stems.map { |stem| phrase(stem) }.join(' OR ')
      end

      # Split +text+ into lower-cased runs of letters and digits.
      #
      #   Query.tokenize("Acme's Q3 pricing — v2.1")
      #   # => ["acme", "s", "q3", "pricing", "v2", "1"]
      #
      # Unicode-aware (+\p{L}+ / +\p{N}+), so accented and non-Latin words
      # survive; punctuation is a separator, never a term. Lower-casing is
      # belt-and-braces — +unicode61+ folds case on its own — but it keeps the
      # expression readable in a log line.
      #
      # NFC first, so a decomposed "ö" (+o+ and a combining diaeresis, as macOS
      # and some PDFs write it) is one letter and stays inside its word, and a
      # {Stemmer} sees the composed form: Voikko finds no reading of an NFD
      # word.
      #
      # @param text [String, nil]
      # @return [Array<String>] possibly empty.
      def self.tokenize(text)
        text.to_s.unicode_normalize(:nfc).scan(/[\p{L}\p{N}]+/).map(&:downcase)
      end

      # One token as an FTS5 phrase term, internal +"+ doubled.
      #
      # @param token [String]
      # @return [String] e.g. +'"acme"'+.
      def self.phrase(token)
        %("#{token.gsub('"', '""')}")
      end
      private_class_method :phrase

      # @param stems [Array<String>] one word's stems, never empty.
      # @return [String] +'"katu"'+, or +'("katu" OR "katua")'+ for several.
      def self.any_of(stems)
        return phrase(stems.first) if stems.one?

        "(#{stems.map { |stem| phrase(stem) }.join(' OR ')})"
      end
      private_class_method :any_of
    end
  end
end
