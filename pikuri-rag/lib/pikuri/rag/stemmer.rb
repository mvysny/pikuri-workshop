# frozen_string_literal: true

module Pikuri
  module Rag
    # Stemmers: what a word is indexed and searched under, computed in Ruby
    # before FTS5 sees the text, so the table stays plain FTS5 and the
    # stemmer swaps without touching SQL. Here the Finnish one from
    # +pikuri-stemmers+:
    #
    #   stemmer = Pikuri::Stemmers::Voikko.new(::Voikko.new(language: 'fi'))
    #   stemmer.stems('tietokoneella')         # => ["tietokone"]                  a query word
    #   stemmer.index_stems('tietokoneella')   # => ["tietokone", "tieto", "kone"] a document word
    #   stemmer.id                             # => "voikko-fi+compounds"
    #
    # A stemmer is a duck answering those three, plus +#close+:
    #
    # * +#stems(word)+ → +Array<String>+, the forms a query word searches
    #   for: lower-cased, never empty, an unknown word answering itself.
    #   Several is normal, one per reading of an ambiguous word; the query ORs
    #   them.
    # * +#index_stems(word)+ → +Array<String>+, the forms a document word is
    #   indexed under; a superset of +#stems+. The extra forms are why a
    #   query for "kone" finds "tietokone" while one for "tietokone" does not
    #   find every "kone".
    # * +#id+ → +String+, naming the stemmer and its configuration. The index
    #   stores it and rebuilds on a mismatch, so it must change whenever any
    #   word's stems do.
    # * +#close+ — release what the stemmer holds open (Voikko's dictionary
    #   handle); idempotent. The {Backend::Fts5} it was handed calls it.
    #
    # +word+ is one token of {Query.tokenize}: lower-case letters and digits.
    module Stemmer
    end
  end
end
