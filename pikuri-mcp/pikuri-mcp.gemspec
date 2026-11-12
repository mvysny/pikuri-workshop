# frozen_string_literal: true

require_relative '../version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-mcp'
  spec.version     = Pikuri::Workshop::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Model Context Protocol (MCP) support for pikuri.'
  spec.description = <<~DESC
    pikuri-mcp adds Model Context Protocol support to pikuri-core
    agents: a +Pikuri::Mcp::Registry+ for declaring stdio + HTTP MCP
    servers, the +Pikuri::Mcp::Servers+ runtime that spawns them, a
    +Pikuri::Mcp::Synthesizer+ that LLM-fills missing server
    descriptions, a +Pikuri::Mcp::Verifier+ that screens server
    surfaces for prompt-injection patterns before any tool is
    advertised to the LLM, and a +Pikuri::Mcp::Extension+ that wires
    everything into a +Pikuri::Agent+ via +c.add_extension(...)+ in
    the +Agent.new+ block.
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

  # The Extension protocol the Mcp::Extension hooks into lives in
  # pikuri-core; pinned to the pikuri
  # release this workshop was built against.
  spec.add_dependency 'pikuri-core', Pikuri::Workshop::PIKURI

  # MCP client + server. Used by Pikuri::Mcp::Servers to spawn and
  # talk to external MCP servers. The gem owns subprocess lifecycle,
  # JSON-RPC framing, and the tools/list / tools/call round-trips;
  # pikuri-mcp's Mcp::ClientWrapper adapts that into a per-server
  # transport with restart-on-stdio-death retry.
  spec.add_dependency 'mcp', '~> 0.17'
end
