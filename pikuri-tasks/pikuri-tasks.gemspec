# frozen_string_literal: true

require_relative '../version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-tasks'
  spec.version     = Pikuri::Workshop::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Per-session in-memory task list + tools for pikuri.'
  spec.description = <<~DESC
    pikuri-tasks gives a pikuri-core agent an in-memory task list it
    can use to plan and track multi-step work. A +Pikuri::Tasks::List+
    holds the per-Agent state; four tools (+task_create+,
    +task_in_progress+, +task_completed+, +task_delete+) mutate it via
    content-as-identifier (no item IDs to hallucinate).
    +Pikuri::Tasks::Extension+ wires the list and tools onto an
    +Pikuri::Agent+ via +c.add_extension(...)+ inside the +Agent.new+
    block.

    The list lives in process memory only — nothing is written to disk.
    Sub-agents do not inherit the parent's list (consistent with the
    "sub-agents do not inherit extensions" rule).
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

  # Extension protocol + Tool base class live in pikuri-core;
  # pinned to the pikuri release this workshop was built against.
  spec.add_dependency 'pikuri-core', Pikuri::Workshop::PIKURI
end
