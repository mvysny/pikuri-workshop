# frozen_string_literal: true

require_relative '../version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-code'
  spec.version     = Pikuri::Workshop::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'In-repo coding-agent shell tool (Bash) + pikuri-code binary.'
  spec.description = <<~DESC
    pikuri-code adds the shell-and-dev-loop layer on top of
    pikuri-workspace's filesystem tools: a +Pikuri::Code::Bash+ that
    runs commands via the +Pikuri::Subprocess+ chokepoint with
    +Confirmer+ gating (optionally wrapped in a
    +Pikuri::Code::Bash::Sandbox::Bubblewrap+ filesystem sandbox),
    plus the demo +bin/pikuri-code+ binary that wires file + shell +
    web tools into an interactive coding agent rooted at the current
    working directory. The +Pikuri.prompt+ search path picks up this
    gem's +prompts/coding-system-prompt.txt+ automatically on require.
  DESC

  spec.homepage = 'https://github.com/mvysny/pikuri-workshop'
  spec.license  = 'MIT'

  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'source_code_uri'       => "#{spec.homepage}/tree/master",
    'changelog_uri'         => "#{spec.homepage}/blob/master/CHANGELOG.md",
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir[
    'lib/**/*.rb',
    'prompts/*.txt',
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # +Pikuri::Tool+ + +Pikuri::Subprocess+ live in pikuri-core;
  # pinned to the pikuri release this workshop was built against.
  spec.add_dependency 'pikuri-core',      Pikuri::Workshop::PIKURI

  # +Pikuri::Workspace::Filesystem+ + +Pikuri::Workspace::Confirmer+ live
  # in pikuri-workspace; +Pikuri::Code::Bash+ takes both via constructor.
  spec.add_dependency 'pikuri-workspace', Pikuri::Workshop::PIKURI

  # +Pikuri::SubAgent::Persona+ — the record type the bundled
  # +GIT_REPO_RESEARCHER+ persona is an instance of. Its +tool_names+
  # also name the web tools, resolved against whatever the host wires,
  # so pikuri-web is the host's dependency, not this gem's. Pinned like
  # pikuri-core.
  spec.add_dependency 'pikuri-subagents', Pikuri::Workshop::PIKURI
end
