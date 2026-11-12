# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'
require 'pikuri-subagents'

# Entry file for the pikuri-code gem: appends the gem's +prompts/+ to
# +Pikuri::PROMPT_DIRS+ and mounts a Zeitwerk loader at this +lib/+ root, so
# +lib/pikuri/code/bash.rb+ autoloads as +Pikuri::Code::Bash+ and
# +.../bash/sandbox.rb+ as +Pikuri::Code::Bash::Sandbox+.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  module Code
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-code'
    LOADER.push_dir(__dir__)
    LOADER.ignore(File.expand_path('pikuri-code.rb', __dir__))
    # +GIT_REPO_RESEARCHER+ is an +ALL_CAPS+ value constant in a file
    # whose name Zeitwerk would map to +GitRepoResearcher+; same trick
    # +pikuri-subagents+ uses for +RESEARCHER+ / +FILE_MINER+. Ignore here,
    # require_relative below once {Pikuri::SubAgent::Persona} is loaded.
    LOADER.ignore(File.expand_path('pikuri/code/git_repo_researcher.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end

require_relative 'pikuri/code/git_repo_researcher'
