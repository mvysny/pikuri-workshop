# frozen_string_literal: true

require_relative '../version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-skills'
  spec.version     = Pikuri::Workshop::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Agent Skills standard support for pikuri.'
  spec.description = <<~DESC
    pikuri-skills implements the Agent Skills standard
    (agentskills.io) for pikuri-core agents: a +Pikuri::Skill::Catalog+
    that discovers skill folders under .pikuri/skills, .claude/skills,
    and .agents/skills; a +Pikuri::Skill::SkillTool+ that loads a
    skill's body on demand; and a +Pikuri::Skill::Extension+ that wires
    both into a +Pikuri::Agent+ via +c.add_extension(...)+ in the
    +Agent.new+ block.
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
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # The Extension protocol the catalog/tool hook into lives in
  # pikuri-core; pinned to the pikuri
  # release this workshop was built against.
  spec.add_dependency 'pikuri-core', Pikuri::Workshop::PIKURI
end
