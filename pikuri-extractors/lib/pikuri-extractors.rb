# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-extractors gem: sets up the per-gem Zeitwerk
# loader. Requiring it defines {Pikuri::Extractors::Documents} + the
# shared {Pikuri::Extractors::DOCUMENTS} but registers nothing — a host
# opts in with +DOCUMENTS.register+ (see there).
module Pikuri
  module Extractors
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-extractors'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load
  end
end
