# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-mcp gem: appends the gem's +prompts/+ to
# +Pikuri::PROMPT_DIRS+ and mounts a per-gem Zeitwerk loader at this +lib/+
# (contributing to the shared +Pikuri::+ namespace), so
# +lib/pikuri/mcp/registry.rb+ autoloads as +Pikuri::Mcp::Registry+, etc.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  module Mcp
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-mcp'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load
  end
end
