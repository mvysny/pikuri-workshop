# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for vector-store backends. Two ship: {InMemory} (pure-Ruby
    # cosine, RAM-only — the audit-friendly educational default, pairs with
    # {Server::InMemory}) and {Qdrant} (the persistent option — see
    # +pikuri-vectordb/design/architecture.md+ for why Qdrant — pairs with
    # {Server::Qdrant}). Another engine is one more class behind the protocol
    # below.
    #
    # == Backend protocol
    #
    # Duck-typed, like pikuri's other seams (+Confirmer+, +Filesystem+,
    # +Sandbox+) — no base class. Every backend implements, so the {Corpus} and
    # {Tools::Search} consume them interchangeably:
    #
    # * +#upsert(chunks:, vectors:)+ — insert-or-replace by +chunk.id+; parallel
    #   equal-length arrays, +ArgumentError+ on empty/mismatch, returns +nil+.
    # * +#query(vector:, top_k:)+ — top-k nearest by cosine, descending
    #   +Array<Result>+ (empty when the store is); +ArgumentError+ on +top_k+ <= 0.
    # * +#delete_all+ — empty the store (nuke-and-reload reindex); +nil+.
    # * +#count+ — stored chunk count, +Integer+.
    # * +#delete_by_source(source)+ — scoped counterpart to +#delete_all+; no-op
    #   when absent; +nil+.
    # * +#replace_source(source:, chunks:, vectors:)+ — delete-by-source then
    #   upsert as one op (the incremental-reindex unit); atomic on {InMemory},
    #   two HTTP calls elsewhere (see each backend). +nil+.
    # * +#sources_with_hashes+ — +Hash{String => String, nil}+, each indexed
    #   +source+ → content hash; the boot-sweep reference
    #   {Corpus#reconcile_plan} diffs against disk. Inherently O(sources)
    #   (removal detection needs the whole set), so once-per-boot, never
    #   per-request.
    # * +#source_indexed?(source)+ — +Boolean+; the scoped counterpart for
    #   {VectorDb::Tools::Read}'s membership gate, distinct so a hot path never
    #   fetches the full manifest to test one key.
    # * +#close+ — release what the backend holds open; idempotent, and no
    #   other call follows it. The {Corpus} that owns the backend calls it.
    #
    # The four after +#count+ exist for incremental reindex + auto-watch;
    # nuke-and-reload uses only the first four.
    #
    # Because it is a duck, the protocol is *decoratable*: a wrapper that
    # delegates all nine calls to an inner backend and does something extra on
    # the writes (mirror every chunk into a second index, say) is a backend to
    # {Corpus}, {Watcher} and the tools alike, with no change to any of them.
    #
    # == Vector-dim contract
    #
    # The first +#upsert+ establishes the vector dim for the backend's lifetime;
    # later +#upsert+/+#query+ must match or raise +ArgumentError+ — an embedder
    # swap mid-session would otherwise silently corrupt the index.
    module Backend
    end
  end
end
