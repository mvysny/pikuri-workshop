# pikuri-vectordb

Topical retrieval over a local corpus for the
[pikuri](https://github.com/mvysny/pikuri) AI-assistant toolkit:
semantic recall over a pile of files you point it at — your notes,
your docs, your contracts — where the *agent* decides when to
retrieve, same Thought → Tool-call → Observation loop as every other
tool.

This is the retrieval **primitive**, and what it answers is
*precision*: the top few chunks on the topic you asked about. Two
other questions need a keyword index beside the vectors —
*completeness* ("every note mentioning Acme", where top-k is a sample)
and *exactness* ("invoice #4471", where rare tokens are what embedders
rank worst). That is [`pikuri-rag`](../pikuri-rag/README.md), which
wraps your vector backend beside a keyword index and replaces this
extension's tool set with its own.

Build one `Corpus` per folder, then wire it onto each `pikuri-core`
agent the same way as `pikuri-tasks` / `pikuri-memory` —
`c.add_extension` inside the `Agent.new` block:

```ruby
require 'pikuri-vectordb'

corpus = Pikuri::VectorDb::Corpus.new(
  backend:  Pikuri::VectorDb::Backend::InMemory.new,
  source:   '~/notes',
  embedder: Pikuri::VectorDb::Embedder.new(server: ..., model: ...),
  private:  true,   # these documents are worth exfiltrating
  trusted:  true    # and every one of them is yours
)

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension Pikuri::VectorDb::Extension.new(corpus: corpus)
end
```

Those last two are what the corpus tells the lethal-trifecta map about
itself; both default off, so leaving them out prints the pessimistic
reading. `trusted: true` is a bigger claim than it looks — read
`Corpus#trusted?` (or the book's
[vector-DB chapter](../book/vectordb.md)) before you make it about a
folder holding PDFs or shared with anyone.

## What you get

Three tools, registered by the extension:

1. **`vectordb_search`** — embeds the query, pulls the top-k nearest
   chunks from the backend, optionally reranks them with a
   cross-encoder, and hands the agent a numbered list of
   `source lines 1210-1248` snippets, best first, as its next
   observation.
2. **`vectordb_read`** — parent-document retrieval: when a search
   surfaces a clean hit, the agent reads that document by its
   `source` path, starting at the hit's first line, instead of
   re-querying for more fragments of it.
3. **`vectordb_reindex`** — rebuilds the index from the source, on
   request.

The extension registers the tools and nothing else — *populating*
the index is the host's call, never something done behind your
back. Three equally valid shapes:

- Index at boot: `corpus.index_if_empty!`.
- Keep it live: run a `Pikuri::VectorDb::Watcher` around the
  corpus — a filesystem-event daemon (the `listen` gem) that sweeps
  once on boot and reindexes files as they change.
- Leave it empty and let the user drive: the agent calls
  `vectordb_reindex` when asked.

## One corpus per folder

Several agents reading the same folder share one corpus: build it
once and hand it to every agent's extension. Two corpora over one
folder each embed every file again. A different folder gets its own
corpus, and with Qdrant its own collection.

The corpus owns the backend you hand it, and closing it closes the
backend; closing an agent leaves it alone. A `Server::Qdrant` is not
part of it, so close that separately. At teardown, close in reverse
order — watcher, agents, corpus, server:

```ruby
watcher.close
agent.close
corpus.close
server.close   # if you started one
```

## Backends

Three implementations of one duck-typed interface
(`#upsert` / `#query` / `#delete_all` / `#count`) — swapping is a
one-line change:

- `Backend::InMemory` — the educational default. Pure-Ruby cosine
  over `Array<Float>`, ~40 lines, reads in one sitting. RAM-only:
  everything reloads from sources on every boot.
- `Backend::Qdrant` — thin Faraday HTTP client against a
  self-hosted [Qdrant](https://qdrant.tech), the persistent
  backend — [`design/architecture.md`](design/architecture.md) has the engine
  survey behind the pick.

`Server::Qdrant` runs it as a self-managed podman/docker container
(podman when it's installed): pinned image, a
container name pikuri owns (`pikuri-internal-qdrant`), data bind-mounted under
`~/.cache/pikuri/` so the corpus survives container recreation.

```ruby
# Supervised container (needs podman or docker on PATH):
backend = Pikuri::VectorDb::Server::Qdrant.ensure_running.client(
  collection: 'my-docs'
)

# Or point at a Qdrant you already run:
backend = Pikuri::VectorDb::Backend::Qdrant.new(
  host: 'localhost', port: 6333, collection: 'my-docs'
)
```

Collection naming is engine-specific so it lives on the backend
constructor, not on the Corpus — `Backend::InMemory` has no
collection concept.

## The indexing pipeline

What `vectordb_reindex` (and the `Watcher`) actually runs, piece by
piece — each swappable via the Corpus's keyword arguments (the
reranker via the Extension's):

- **Chunker** (`Chunker::FixedWindow`) — overlapping windows,
  default 512 tokens with 50 of overlap, so an answer straddling a
  boundary survives in at least one chunk.
- **Tokenizer** (`Tokenizer::CharHeuristic`) — counts tokens for
  the chunker, by the offline ~4-chars-per-token rule. Anything with
  a `count(text)` method plugs into `Chunker::FixedWindow` instead,
  for a corpus the rule miscounts.
- **Embedder** — calls an OpenAI-compatible `/v1/embeddings` over
  its own connection: `Embedder.new(server:, model:, api_key:)`, the
  same arguments as the chat's `ChatTransport.from_openai_server`.
  Tests inject a fake `#embed` without monkey-patching ruby_llm.
- **Reranker** (`Reranker::LlamaServer`, optional) — cross-encoder
  over `POST /v1/rerank`, on its own connection like the embedder's:
  `Reranker::LlamaServer.new(server:, model:, api_key:)`. Pass `reranker: nil` to skip it;
  retrieval falls back to vector-only top-k — less precision, same
  correctness.

Text extraction reuses `Pikuri::FileType.read_as_text` from
pikuri-core — plain text / Markdown out of the box; for a PDF
corpus, register pikuri's
[pikuri-pdf](https://github.com/mvysny/pikuri/tree/master/pikuri-pdf) extractor in your
host script (`Pikuri::Extractors::PDF.register` — `pikuri-corpus`
does exactly that). HTML extraction is a deferred follow-up.

## Demo: `pikuri-corpus`

From a source checkout (not installed by `gem install`). The bin lives in
`pikuri-rag`, whose `--hybrid` flag adds the keyword index; without it,
it runs this gem alone:

```sh
./pikuri-rag/bin/pikuri-corpus --qdrant --watch
```

A single recall agent over `book/` (this repo's book)
with **no egress** — its tools are the three above plus
`calculator`; no web search, no fetch, no bash. The corpus stands
in for private data, and an agent that can read it must not also be
able to send it out. `--qdrant` persists the index
across runs, `--watch` keeps it live, `--no-reranker` drops the
reranker requirement. The book's
[vector-DB chapter](../book/vectordb.md) is the full walkthrough.

## Three model endpoints

A full setup wants three LLM endpoints: chat (via `ruby_llm`), an
embedder (`/v1/embeddings`, via ruby_llm), and an optional reranker (HTTP
`/v1/rerank`). Recommended setup: **one `llama-server` running in
router mode** — started with no `--model` flag, it serves every
GGUF in `~/.cache/llama.cpp/` from a single port and loads
whichever model each request asks for. Requires a recent enough
`llama.cpp` build to include the
[model-management feature](https://huggingface.co/blog/ggml-org/model-management-in-llamacpp);
Ubuntu 26.04+ packages one. pikuri's
[first-conversation chapter](https://github.com/mvysny/pikuri/blob/master/book/chat.md)
walks through the setup; this book's
[vector-DB chapter](../book/vectordb.md) adds the embedder and
reranker on top.

If you'd rather pin the reranker in its own process — to avoid
paying the router's unload/reload cost on rerank requests —
`Reranker::LlamaServer` takes its own `server:` argument and
can point at a separate `llama-server`. Otherwise pikuri stays
agnostic: it just needs URLs.

Larger multi-model runtimes (Ollama, LM Studio, ...) expose
OpenAI-compatible endpoints and would also work, but pikuri's
"small enough to audit" ethos keeps the recommended path on
`llama.cpp` alone.

## Install

```ruby
# Gemfile
gem 'pikuri-vectordb'
```

Depends on `pikuri-core` and `listen` (filesystem events for the
`Watcher`; loaded only when a `Watcher` starts).

## Further reading

- **Book chapter:** [Agentic search and the vector
  DB](../book/vectordb.md) — concepts, model setup, the
  no-egress argument, `--qdrant --watch` day-to-day shape.
- **Design notes:** [`design/architecture.md`](design/architecture.md) — the engine survey
  behind Qdrant.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-vectordb> (once published),
  or run `bundle exec yard` in this directory for a local copy.
