# frozen_string_literal: true

require_relative '../version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-memory'
  spec.version     = Pikuri::Workshop::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Durable cross-conversation memory for pikuri, backed by mem0.'
  spec.description = <<~DESC
    pikuri-memory gives a pikuri-core agent durable, long-lived
    memory: facts about the user and their work that persist across
    conversations. It wires a +recall+ tool plus an automatic
    per-turn prefetch onto an agent via
    +c.add_extension Pikuri::Memory::Extension.new(...)+ inside the
    +Agent.new+ block — same opt-in shape as +pikuri-tasks+ /
    +pikuri-vectordb+. Recall is automatic and synchronous (embed +
    vector search, milliseconds); capture is automatic and
    asynchronous (an off-the-interaction-path extraction queue), so
    a turn never blocks on "what should I remember?".

    Storage is mem0 (https://github.com/mem0ai/mem0) reached over a
    thin Faraday HTTP client — the append-only +add+ / read-time
    +search+ model. Only the *user's own words* are fed to
    extraction (a write-side hygiene rule that structurally drops
    system/assistant/tool-sourced junk), and recalled context enters
    the chat as a +:system+ message so it is provenance-tagged and
    excluded from the next extraction pass. This release ships the
    Ruby client + extension + tool against a *bring-your-own* mem0
    endpoint; a self-managed mem0 sidecar supervisor (the
    +ChromaServer+-style docker pattern) is a follow-on.
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
    # The mem0 sidecar supervisor (Mem0Server) loads these at runtime —
    # they must ship in the gem.
    'docker/docker-compose.yml',
    'docker/*.patch',
    'docker/README.md',
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # pikuri-core ships the +Agent+ runtime + +Pikuri::Tool+ base
  # class the +recall+ tool subclasses, the +Extension+ protocol
  # (incl. the +on_user_message+ hook this gem rides), and Faraday
  # (the thin mem0 HTTP client's transport). mem0 owns embedding +
  # extraction, so pikuri never calls an embedder or LLM itself —
  # pikuri-core is the only dependency.
  spec.add_dependency 'pikuri-core', Pikuri::Workshop::PIKURI
end
