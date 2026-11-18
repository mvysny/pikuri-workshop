# frozen_string_literal: true

require_relative '../version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-os'
  spec.version     = Pikuri::Workshop::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Offline Linux/OS helper agent + tools for pikuri.'
  spec.description = <<~DESC
    pikuri-os is the OS-integration layer for pikuri and the home of
    the +bin/pikuri-os+ demo: a single, local, network-severed
    agent that understands and operates the host OS (answer questions
    about the machine, find and open files, read logs and explain
    errors, advise on configuration). It is the federation's privacy-
    first +@os+ member shipped standalone — no egress, no MCP, no cloud.

    The gem holds the OS-specific surface (a single-file +MACHINE.md+
    resident memory and boot-time machine grounding) on top of
    pikuri-core's Agent + Tool framework, pikuri-workspace's file
    tools, pikuri-code's Bash + sandbox, and pikuri-fileindex's search
    over the desktop's file index. It deliberately does NOT depend on
    pikuri-mcp/-memory/-vectordb: severing those keeps the no-egress,
    "small enough to audit" posture honest.

    See +design/ideas/pikuri-os.md+ in the repo for the full design.
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

  # Agent runtime + Tool base class + Extension protocol live in
  # pikuri-core; the file tools + Confirmer live in
  # pikuri-workspace; Bash + Bash::Sandbox (the net-isolation seam this
  # agent rides) live in pikuri-code. pikuri-code is
  # pinned in lockstep, the other two to the pikuri release this
  # workshop was built against. The PDF extractor and
  # the --with-internet RESEARCHER that +bin/pikuri-os+ wires are the
  # binary's choices, reached through the root Gemfile, not this gem's.
  spec.add_dependency 'pikuri-code',      "= #{Pikuri::Workshop::VERSION}"
  spec.add_dependency 'pikuri-core',      Pikuri::Workshop::PIKURI
  spec.add_dependency 'pikuri-fileindex', Pikuri::Workshop::PIKURI
  spec.add_dependency 'pikuri-workspace', Pikuri::Workshop::PIKURI
end
