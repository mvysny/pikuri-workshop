# frozen_string_literal: true

require_relative '../version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-rag'
  spec.version     = Pikuri::Workshop::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Hybrid retrieval — keyword index beside the vectors — for pikuri.'
  spec.description = <<~DESC
    pikuri-rag is the retrieval *system* built on pikuri-vectordb's
    retrieval *primitive*. Vector search answers precision — top-k
    chunks on topic — and structurally cannot answer two other
    questions: completeness ("every note mentioning Acme", where
    top-k is a sample and cosine has no calibrated zero) and
    exactness ("invoice #4471", where rare tokens are what embedders
    rank worst). This gem adds the field's settled answer: an SQLite
    FTS5 keyword index beside the vectors, fused by reciprocal rank.

    Four tools under one prefix — +rag_search+ (hybrid top-k, fused,
    optionally reranked), +rag_search_keywords+ (every matching document by
    stemmed token match, with no cutoff), +rag_read+ and
    +rag_reindex+. The keyword index is its own backend
    (+Backend::Fts5+, the only class here that speaks SQL), paired with
    the host's vector store inside one +Backend::Hybrid+ that fans
    writes out to both — so the vectordb +Corpus+ and +Watcher+ are
    reused unchanged: one walk, one extraction per file, one content
    hash. Hosts wire it
    via +c.add_extension Pikuri::Rag::Extension.new(...)+ inside the
    +Agent.new+ block; it is mutually exclusive with
    +Pikuri::VectorDb::Extension+ on one agent.

    Stemming is FTS5's built-in +porter+ for English; another language
    plugs in through +stemmer:+. The threat model is pikuri-vectordb's,
    unchanged — same corpus declaration, inbound-only tools, same
    membership gate on the reader.
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

  # pikuri-vectordb ships everything the hybrid half composes over: the
  # +Backend+ protocol +Hybrid+ implements, the +Corpus+ /
  # +Watcher+ that fill it, the +Embedder+ / +Chunker+ / +Reranker+
  # ducks, +CorpusLegs.derive+, and +Tools::Read+ / +Tools::Reindex+,
  # which ship here verbatim under +family: 'rag'+.
  spec.add_dependency 'pikuri-vectordb', "= #{Pikuri::Workshop::VERSION}"
  # The entry file requires pikuri-core itself; pinned to the pikuri
  # release this workshop was built against.
  spec.add_dependency 'pikuri-core', Pikuri::Workshop::PIKURI
  # sqlite3 backs the FTS5 keyword index. The prebuilt gem ships a
  # SQLite with FTS5 and a working +porter+ tokenizer compiled in, so
  # the keyword half needs no external service — the same dependency
  # pikuri-thunderbird already takes for Gloda.
  spec.add_dependency 'sqlite3', '~> 2.9'
end
