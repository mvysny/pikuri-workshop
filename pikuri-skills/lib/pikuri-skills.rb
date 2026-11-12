# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-skills gem: a per-gem Zeitwerk loader
# rooted at this +lib/+, contributing +Pikuri::Skill::{Catalog,
# SkillTool, Extension}+ and +Pikuri::Bundle::Base+ to the shared
# +Pikuri::+ namespace.
module Pikuri
  module Skill
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-skills'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load
  end
end
