# frozen_string_literal: true

require 'pikuri-core'

module Pikuri
  # Stemmers for pikuri-rag's keyword index, one class per language
  # library, each a +stemmer:+ for +Pikuri::Rag::Backend::Fts5+:
  #
  #   require 'voikko'
  #   Pikuri::Rag::Backend::Fts5.new(store: ...,
  #                                  stemmer: Pikuri::Stemmers::Voikko.new(Voikko.new(language: 'fi')))
  #
  # The contract is +Pikuri::Rag::Stemmer+'s duck: +#stems+, +#index_stems+,
  # +#id+, +#close+. A stemmer never requires its library — the host adds the
  # gem and opens the handle, and the stemmer closes it — so this gem pulls in
  # no native code, and each class's doc names what its language needs
  # installed.
  module Stemmers
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-stemmers'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load
  end
end
