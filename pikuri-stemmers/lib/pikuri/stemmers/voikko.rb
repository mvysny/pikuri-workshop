# frozen_string_literal: true

module Pikuri
  module Stemmers
    # Finnish stemming by dictionary form, as the +stemmer:+ of
    # +Pikuri::Rag::Extension+ (the +Pikuri::Rag::Stemmer+ duck), over an
    # open handle of the +voikko+ gem:
    #
    #   stemmer = Pikuri::Stemmers::Voikko.new(::Voikko.new(language: 'fi'))
    #   stemmer.stems('kadulla')                    # => ["katu"]
    #   stemmer.stems('tulosta')                    # => ["tulostaa", "tulonen", "tulo", "tulos"]
    #   stemmer.stems('backend')                    # => ["backend"]   unknown, answers itself
    #   stemmer.index_stems('yrityskirjautumisen')  # => ["yrityskirjautua", "yritys", "kirjautua"]
    #
    # Needs, on the host: the distro's +libvoikko1+ and +voikko-fi+, and
    # +gem 'voikko', '~> 0.2'+ in its Gemfile. The host owns the handle's
    # +#close+.
    #
    # An English word is unknown to Voikko and answers itself, which leaves
    # it to FTS5's +porter+ as before, so a mixed corpus keeps its English
    # stemming.
    #
    # Thread-safe: it holds no state, and the +voikko+ gem locks each call
    # on the handle.
    class Voikko
      # @param voikko [#analyze, #language] an open +::Voikko+ handle; anything
      #   whose +#analyze(word)+ answers objects with +#base_form+ and
      #   +#morphemes+ will do.
      def initialize(voikko)
        @voikko = voikko
      end

      # @return [String] +"voikko-fi+compounds"+, the language being the
      #   handle's tag as opened. The suffix names {#index_stems}' compound
      #   split, so an index built by a stemmer without it rebuilds.
      def id = "voikko-#{@voikko.language}+compounds"

      # Every reading's dictionary form, lower-cased.
      #
      # @param word [String] one +Pikuri::Rag::Query.tokenize+ token.
      # @return [Array<String>] never empty; +[word]+ when Voikko does not
      #   know it.
      def stems(word)
        forms = @voikko.analyze(word).filter_map(&:base_form)
        forms.empty? ? [word.downcase] : forms.map(&:downcase).uniq
      end

      # {#stems}, plus each compound part's own {#stems}, so "kone" finds
      # "tietokone" (at the cost of longer bm25 document lengths).
      #
      #   index_stems('versionhallintajärjestelmää')
      #   # => ["versionhallintajärjestelmä", "versio", "hallinta", "järjestelmä"]
      #
      # A part that is no word alone answers itself as written: the
      # +pediassa+ of +wikipediassa+, the +esi+ of a prefixed word.
      #
      # @param word [String] one +Pikuri::Rag::Query.tokenize+ token.
      # @return [Array<String>] never empty.
      def index_stems(word)
        forms = @voikko.analyze(word).flat_map do |analysis|
          parts = analysis.morphemes || []
          part_stems = parts.size < 2 ? [] : parts.flat_map { |part| stems(part.text) }
          [analysis.base_form&.downcase, *part_stems]
        end.compact.uniq
        forms.empty? ? [word.downcase] : forms
      end
    end
  end
end
