# frozen_string_literal: true

require 'pikuri-core'

module Pikuri
  # Stemmers for pikuri-rag's keyword index, one class per language
  # library, each a +stemmer:+ for +Pikuri::Rag::Extension+:
  #
  #   require 'voikko'
  #   voikko = Voikko.new(language: 'fi')
  #   Pikuri::Rag::Extension.new(backend: ..., source: '~/notes', embedder: ...,
  #                              stemmer: Pikuri::Stemmers::Voikko.new(voikko))
  #
  # The contract is +Pikuri::Rag::Stemmer+'s duck: +#stems+, +#index_stems+,
  # +#id+. A stemmer never requires its library — the host adds the gem,
  # opens the handle and closes it — so this gem pulls in no native code,
  # and each class's doc names what its language needs installed.
  module Stemmers
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-stemmers'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load
  end
end
