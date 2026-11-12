# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-tasks gem: sets up the per-gem Zeitwerk
# loader. See {Pikuri::Tasks} for the namespace overview.
module Pikuri
  module Tasks
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-tasks'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load
  end
end
