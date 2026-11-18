# frozen_string_literal: true

require_relative '../version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-vectordb'
  spec.version     = Pikuri::Workshop::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Topical retrieval over a local corpus for pikuri: the vector-search primitive.'
  spec.description = <<~DESC
    pikuri-vectordb gives a pikuri-core agent a +vectordb_search+
    tool over a local document corpus — agentic search, the agent
    decides when to retrieve. This is the retrieval *primitive*:
    topical recall over long documents, pure geometry over meaning
    vectors. Completeness ("every note mentioning Acme") and
    exactness ("invoice #4471") need a keyword index beside the
    vectors, which is +pikuri-rag+ — it decorates whatever backend
    you pass here. Ships a swappable backend (a
    pure-Ruby +Backend::InMemory+ for teaching, plus a thin
    +Backend::Qdrant+ HTTP client for persistence), a chunker, an
    embedder over +/v1/embeddings+, and an optional
    +Reranker::LlamaServer+ that speaks +/v1/rerank+ against a
    cross-encoder model. Text extraction goes through
    +Pikuri::FileType.read_as_text+ in pikuri-core, which handles
    plain text / Markdown / PDF; HTML extraction is a deferred
    follow-up. Hosts wire the feature via
    +c.add_extension Pikuri::VectorDb::Extension.new(...)+ inside
    the +Agent.new+ block — same opt-in shape as +pikuri-tasks+ /
    +pikuri-skills+.

    Three model endpoints in the full setup — chat (via ruby_llm),
    an embedder (+/v1/embeddings+, via ruby_llm), and an optional reranker
    (HTTP +/v1/rerank+). A single +llama-server+ in router mode
    serves all three by default, loading each cached GGUF on
    demand; see the gem's README for details.
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

  # pikuri-core ships the +Agent+ runtime + +Pikuri::Tool+ base
  # class that the search tool subclasses, the embedder's ruby_llm wired
  # through ruby_llm, Faraday for HTTP, and the +Extractor+ registry
  # the corpus's text extraction routes through (plain text /
  # Markdown out of the box; a host indexing a PDF corpus registers
  # the pikuri-pdf extractor — deliberately not a dependency here, so
  # the lean no-PDF install stays lean). Pinned to the pikuri release
  # this workshop was built against.
  spec.add_dependency 'pikuri-core', Pikuri::Workshop::PIKURI
  # listen backs the optional +VectorDb::Watcher+ auto-watch daemon
  # (inotify on Linux, with a polling fallback). Only loaded when a
  # host actually starts a Watcher — +require 'listen'+ is deferred to
  # +Watcher#start+, so the rest of the gem loads without it present.
  spec.add_dependency 'listen', '~> 3.9'
end
