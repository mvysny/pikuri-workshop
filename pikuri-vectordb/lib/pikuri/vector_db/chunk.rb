# frozen_string_literal: true

module Pikuri
  module VectorDb
    # A unit of text after chunking, before storage. The {Corpus} pairs a Chunk
    # with its vector for {Backend#upsert}; {Tools::Search} surfaces query hits
    # as +Chunk+s wrapped in +Backend::Result+s.
    #
    # Fields:
    #
    # * +id+ — opaque backend-unique identifier, composed as +"source:ordinal"+
    #   (readable, deterministic, stable across reindexes). Incremental reindex
    #   replaces by +source+ not id, so the content hash rides in +metadata+,
    #   not the id. **Not for citation** — that's +source+; the LLM never sees +id+.
    # * +source+ — the user-facing reference (relative path, URL, connector doc
    #   ID), surfaced verbatim by {Tools::Search} as the citation. One source
    #   makes many chunks, so it is *not* unique within a backend — +id+ is.
    # * +text+ — the chunk content: fed to the embedder, surfaced to the LLM as
    #   the snippet.
    # * +metadata+ — an open Hash, since source types differ. The {Corpus}
    #   always sets:
    #   * +ordinal:+ — the chunk's 0-based position within its file; the
    #     sweep reads the +ordinal: 0+ chunk as the file's one manifest row.
    #   * +hash:+ — SHA-256 of the file's bytes, same on every chunk of one
    #     file, so that one row tells whether the file changed.
    #   * +first_line:+ / +last_line:+ — the chunk's line range, per
    #     {Pikuri::Extractor}'s == Lines; a valid +offset:+ for the paged
    #     readers over the same file.
    #   Only the line range reaches the LLM, as a search hit's
    #   +lines 1210-1248+; +ordinal:+ and +hash:+ are bookkeeping.
    #
    # No +vector+ field: the vector rides alongside only in transit between
    # {Embedder} and {Backend#upsert} and is absent on the query side (callers
    # see +Backend::Result+), so query chunks carry no inert +vector: nil+ and
    # +upsert+ takes the parallel-array shape backend clients already expect.
    # A frozen value object — partial reindex builds new Chunks with the same
    # +id+ and lets +#upsert+ overwrite.
    Chunk = Data.define(:id, :source, :text, :metadata)
  end
end
