# pikuri-vectordb — AGENTS.md

The retrieval *primitive*: a corpus chunked, embedded and searched by meaning, with a swappable
backend (`InMemory`, or Qdrant in a container) and an optional reranker. `pikuri-rag` builds the
retrieval system on top of it.

## Invariants

- **Connection seam.** Every embed or rerank rides the `RubyLLM::Context` its `VectorDb::Embedder` or `Reranker::LlamaServer` built from its own `server:` and `api_key:`; nothing here calls the process-global `RubyLLM.configure`. pikuri's connection seam, extended to the two clients that live here. See {Pikuri::VectorDb::Embedder}.
- **Request seam.** `VectorDb::Embedder` and `Reranker::LlamaServer` take `Agent.new`'s `around_request:` hook and run it around one HTTP request, never around a reindex, so a host's throttle sees the watcher's embeds beside the chat's completions. See `pikuri:D_llm_request_throttle`.

Maintenance: the root `AGENTS.md`'s rules.
