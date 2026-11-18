# frozen_string_literal: true

module Pikuri
  module Rag
    # The two halves of hybrid retrieval, and they compose rather than nest:
    #
    # * {Backend::Fts5} — the keyword store, an SQLite FTS5 table of chunks.
    #   Searchable on its own, and the only thing here that speaks SQL.
    # * {Backend::Hybrid} — a {Pikuri::VectorDb::Backend} that holds a vector
    #   store *and* a keyword store, fans writes out to both, and keeps their
    #   reads separate for the search tool to fuse.
    #
    # The vector store is whichever one the host already chose;
    # +pikuri-vectordb+ owns those. So a third index is a third store handed
    # to {Hybrid}, not another wrapper around it — which is the reason the
    # composition lives in its own class instead of inside the SQL.
    module Backend
    end
  end
end
