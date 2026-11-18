# Vector DB / RAG deferrals

Status: **v1 shipped, follow-ups deferred.** `pikuri-vectordb` shipped —
topical retrieval over a local corpus, wired onto an `Agent` via
`c.add_extension Pikuri::VectorDb::Extension.new(corpus:)`.
The hybrid half (a keyword index beside the vectors) shipped separately
as `pikuri-rag`; see `design/decisions.md` `D_rag_gem`.
Per-piece rationale (Extension / Backend `InMemory`+`Qdrant` /
Embedder / Reranker / Chunker / `bin/pikuri-corpus`) lives
in the gem's YARD headers, the inventory in [`../AGENTS.md`](../../AGENTS.md),
and [`../pikuri-vectordb/design/architecture.md`](../../pikuri-vectordb/design/architecture.md); the
three-model ops guidance graduated into the `book/` chapters. The
no-egress `pikuri-corpus` posture is documented in
[`../SECURITY.md`](../../SECURITY.md).
Only the deferrals stay here.

## Deferred

- **Classic-RAG-as-listener.** Auto-inject relevant chunks at the
  start of each turn (no tool call) — hermes' prefetch shape (see
  [`../pikuri-memory/design/architecture.md`](https://github.com/mvysny/pikuri-workshop/blob/master/pikuri-memory/design/architecture.md) §"The three
  retrieval tiers"). v1 ships agentic search only — fits the
  loop-agnostic ethos and the agent gets to refine queries. Add
  the listener variant if a concrete "the model forgot to search"
  pattern shows up.
- **Per-doc-type chunkers.** Markdown-heading-aware splitter,
  AST-aware code chunker, contextual chunking. All real quality
  wins, all separately scoped features. (Parent-document
  retrieval shipped instead as the `vectordb_read` tool — the
  agent reads the source document from the hit's first line,
  rather than the chunker stitching parent context onto every
  chunk.) A chunker reports position through `Chunker::Piece` into
  `Chunk#metadata`, so a heading-aware one adds `heading:
  "Chapter 7 > § 3"` the same way `first_line:` rides today.
- **A section reader.** `rag_read(source, around_line:,
  heading_level:)` answering the Markdown section that encloses a
  hit's range. Until a second corpus wants it, a host writes it as
  its own tool over the library API (`Chunk#metadata`'s line range,
  `Rag::Backend::DocumentMatch#first_lines`).
- **Onyx as a separate gem.** Onyx is a product (UI + connector
  framework + scheduler), not a vector DB. If pikuri wants Google
  Drive / Slack / Jira RAG, the right shape is `pikuri-onyx` —
  a thin tool gem that calls a self-hosted Onyx's search API over
  HTTP. Same precedent as MCP: integrate with the protocol, don't
  reimplement it. Onyx's heavy operational footprint stays opt-in
  and out of pikuri-vectordb's scope.
- **Memory growth tier integration.** `pikuri-memory` v1 shipped on
  its own external semantic store (mem0 + Qdrant; see
  [`../pikuri-memory/design/architecture.md`](https://github.com/mvysny/pikuri-workshop/blob/master/pikuri-memory/design/architecture.md) §"Why mem0"),
  *not* pikuri-vectordb — so the once-open "could memory ride the same
  primitive?" question is moot for now. Revisit only if consolidating
  the two stores onto one backend ever becomes worth it; not a v1 goal.
- **Configurable ignore rules.** `Corpus::DENYLIST` ships a fixed
  set (`.git`, `node_modules`, dot-files), and `exclude:` takes whole
  folders (the secretary's books); `.gitignore`-shaped patterns defer
  until someone asks.
- **Remembering unindexable files.** A file that yields no text
  (`.docx`, an image) is never stored, so every boot sweep reads it as
  new and tries again, an INFO line each. Harmless on a small tree; on a
  real `~/Documents` with hundreds of Office files it's noise and parse
  time on every start. A skip manifest keyed by hash would fix both.
- **Multi-source indexing.** `Corpus.new(source:)` takes a single
  file-or-directory root in v1. Indexing
  several disjoint roots into one collection (the user's notes dir +
  a checked-out repo + a downloads folder) is deferred — it needs a
  source-list API and a provenance story for which root a hit came
  from. Referenced from the `Corpus` yardoc
  (that yardoc is the source of truth). **The per-source `trusted:` /
  `private:` flag is part of that API** — design it in from day one
  rather than retrofitting: trust becomes per source, the union follows
  the `Bundle::Base` rule (one unvouched root indexed into the
  collection takes the whole tool set to `:hard`; `private` is true if
  any root claims it), and the legs are computed from the source list at
  `#configure` rather than from a single boolean. See `design/decisions.md`
  `D_corpus_trust_declaration`.
- **Additional reranker backends.** Only `Reranker::LlamaServer`
  ships. It reranks through ruby_llm, which also speaks Cohere's,
  OpenRouter's and Bedrock's rerank, so a hosted cross-encoder is
  mostly a `provider:` swap behind the same duck-typed
  `#rerank(query:, documents:)` protocol — deferred until someone
  wants a non-local reranker. Referenced from `VectorDb::Reranker`
  yardoc (that yardoc is the source of truth).
