# pikuri-rag — AGENTS.md

The retrieval *system*: hybrid vector + FTS5 search fused at one backend over
`pikuri-vectordb`'s primitive. Owns the keyword half and the fusion; the
vector store, corpus and watcher stay `pikuri-vectordb`'s, reused byte-for-byte.

## Invariants

- **RAG seam (two stores composed).** The keyword half is its own backend (`Rag::Backend::Fts5`, the only file speaking SQL) and `Rag::Backend::Hybrid` holds *both* stores — never a sibling indexer, so the vectordb `Corpus` / `Watcher` stay reusable byte-for-byte. "Indexed" means both stores hold it; the membership gate is the vector store alone. See {Pikuri::Rag::Backend::Fts5}, {Pikuri::Rag::Backend::Hybrid}, `design/decisions.md` `D_rag_gem`.
- **Model text never reaches `MATCH`.** Every FTS5 `MATCH` term comes from `Rag::Query` as quoted phrases (a word's stems ORed), so the query mini-language is inert in model text. See {Pikuri::Rag::Query}.
- **Exclusive with `VectorDb::Extension`** on one agent — the retrieval *system* over the vectordb *primitive*, not a second copy of it.

Maintenance: the root `AGENTS.md`'s rules.
