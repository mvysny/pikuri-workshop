# frozen_string_literal: true

require 'monitor'

module Pikuri
  module VectorDb
    module Backend
      # Pure-Ruby vector store — the educational default backend, the "small
      # enough to audit" first stop before users promote to {Qdrant}
      # for persistence. Holds a Hash from chunk id to +[Chunk, vector]+;
      # +#query+ scores cosine similarity against every stored vector, O(n) per
      # query — fine for thousands of chunks (a notes folder), slow for millions.
      #
      # Deliberately no persistence (RAM-only; reloads from sources every boot,
      # which is *why* it's the teaching shape — the boot code path is the one a
      # newcomer inspects to learn what "indexing" means) and no approximate-search
      # index (exhaustive scan; HNSW/IVF adds complexity that teaches nothing once
      # the cosine math is clear).
      #
      # == Thread-safe (the one backend that locks)
      #
      # Every method runs under a reentrant +Monitor+ — real concurrency once
      # auto-watch is wired (the main thread queries while the {Watcher} thread
      # replaces/deletes). The lock's load-bearing job is {#replace_source}: it
      # holds the monitor across the delete-then-upsert so a concurrent +#query+
      # never sees the zero-chunk gap. +Monitor+ not +Mutex+ because
      # +#replace_source+ re-enters via +#delete_by_source+ + +#upsert+. Qdrant
      # needs no client-side lock — the server serializes.
      #
      # Cosine (not dot product) so the backend works whether or not the embedder
      # pre-normalizes; the readable two-pass {#cosine} is intentional over a
      # single-loop micro-opt — this is the file the newcomer reads.
      class InMemory
        # @return [InMemory]
        def initialize
          # id (String) → [Chunk, vector (Array<Float>)]
          @entries = {}
          # Vector dim; +nil+ until the first +#upsert+ locks it, then enforced
          # on every +#upsert+/+#query+ — see the Backend "Vector-dim contract".
          @dim = nil
          # Reentrant — see the class header's "Thread-safe" section.
          @lock = Monitor.new
        end

        # Insert-or-replace by +chunk.id+. Parallel arrays of
        # equal length; raises on empty input or length mismatch.
        # Vector dimension is locked at first upsert; raises on
        # any subsequent vector of a different dim.
        #
        # @param chunks [Array<Chunk>]
        # @param vectors [Array<Array<Float>>]
        # @return [void]
        # @raise [ArgumentError] on empty input, length mismatch,
        #   or vector-dim mismatch.
        def upsert(chunks:, vectors:)
          raise ArgumentError, 'upsert called with empty chunks/vectors' if chunks.empty?
          if chunks.size != vectors.size
            raise ArgumentError, "size mismatch: #{chunks.size} chunks vs #{vectors.size} vectors"
          end

          @lock.synchronize do
            expected = @dim || vectors.first.size
            vectors.each_with_index do |v, i|
              next if v.size == expected

              raise ArgumentError, "vector #{i} has dim #{v.size}, expected #{expected}"
            end
            @dim ||= expected

            chunks.zip(vectors).each { |chunk, vector| @entries[chunk.id] = [chunk, vector] }
          end
          nil
        end

        # Cosine-similarity nearest neighbor search. Returns the
        # top-k {Backend::Result}s in descending score order;
        # empty array when the store has no entries.
        #
        # @param vector [Array<Float>] query vector; must match
        #   the stored vector dim.
        # @param top_k [Integer] number of results to return;
        #   must be positive.
        # @return [Array<Backend::Result>]
        # @raise [ArgumentError] on +top_k+ <= 0 or query-vector
        #   dim mismatch.
        def query(vector:, top_k:)
          raise ArgumentError, "top_k must be positive (got #{top_k})" if top_k <= 0

          @lock.synchronize do
            return [] if @entries.empty?

            if vector.size != @dim
              raise ArgumentError, "query vector dim #{vector.size}, stored dim #{@dim}"
            end

            scored = @entries.values.map do |chunk, stored|
              Result.new(chunk: chunk, score: cosine(vector, stored))
            end
            scored.sort_by { |r| -r.score }.first(top_k)
          end
        end

        # Drop every stored chunk. Used by the v1 nuke-and-reload
        # reindex flow; the embedder dim lock is also released so
        # a reindex with a different embedder model starts clean.
        #
        # @return [void]
        def delete_all
          @lock.synchronize do
            @entries.clear
            @dim = nil
          end
          nil
        end

        # @return [Integer] current chunk count.
        def count
          @lock.synchronize { @entries.size }
        end

        # Remove every chunk whose +source+ matches. The scoped
        # counterpart to {#delete_all} — drops one document's chunks
        # without touching the rest. No-op (and no error) when the
        # source isn't present. The dim lock is left intact: unlike
        # {#delete_all}, a per-source delete doesn't imply an
        # embedder change.
        #
        # @param source [String] the {Chunk#source} to purge, e.g.
        #   +"notes/cooking.md"+.
        # @return [void]
        def delete_by_source(source)
          @lock.synchronize do
            @entries.reject! { |_id, (chunk, _vector)| chunk.source == source }
          end
          nil
        end

        # Atomically replace all chunks for one +source+ (delete-then-upsert
        # under a single monitor hold — the point: a concurrent {#query} sees
        # the old or new chunks, never the empty gap). The incremental-reindex
        # unit (see {Corpus#reindex_file!}).
        #
        # @param source [String] the {Chunk#source} being replaced.
        # @param chunks [Array<Chunk>] the new chunk set (each +chunk.source+
        #   should equal +source+).
        # @param vectors [Array<Array<Float>>] parallel to +chunks+.
        # @return [void]
        # @raise [ArgumentError] on empty input, length or vector-dim mismatch.
        def replace_source(source:, chunks:, vectors:)
          @lock.synchronize do
            delete_by_source(source)
            upsert(chunks: chunks, vectors: vectors)
          end
          nil
        end

        # The boot-sweep reference: each indexed +source+ → the content hash on
        # its chunks, which {Corpus#reconcile_plan} diffs against disk. A chunk
        # with no +hash+ metadata maps to +nil+, which the diff treats as
        # "changed" and reindexes — self-healing.
        #
        # @return [Hash{String => String, nil}] +source+ → content hash. Empty
        #   when nothing is indexed (the InMemory case at every boot).
        def sources_with_hashes
          @lock.synchronize do
            result = {}
            @entries.each_value do |chunk, _vector|
              result[chunk.source] ||= chunk.metadata[:hash]
            end
            result
          end
        end

        # Is +source+ in the corpus? The scoped membership test
        # behind {VectorDb::Tools::Read}'s gate — a short-circuiting scan
        # rather than building the whole {#sources_with_hashes} map
        # just to read one key. See the Backend protocol yardoc.
        #
        # @param source [String] the {Chunk#source} to test.
        # @return [Boolean] true if at least one chunk has this source.
        def source_indexed?(source)
          @lock.synchronize do
            @entries.each_value.any? { |chunk, _vector| chunk.source == source }
          end
        end

        # A no-op: the chunks are plain Ruby objects, and a
        # {Server::InMemory} client's store belongs to that server, whose
        # +#close+ empties it.
        #
        # @return [void]
        def close = nil

        private

        # Cosine similarity (readable two-pass — see the class header).
        #
        # @param a [Array<Float>]
        # @param b [Array<Float>]
        # @return [Float] cosine in +[-1.0, 1.0]+, or +0.0+ if either vector is
        #   zero (degenerate but valid input).
        def cosine(a, b)
          dot = a.zip(b).sum { |x, y| x * y }
          mag_a = Math.sqrt(a.sum { |x| x * x })
          mag_b = Math.sqrt(b.sum { |x| x * x })
          return 0.0 if mag_a.zero? || mag_b.zero?

          dot / (mag_a * mag_b)
        end
      end
    end
  end
end
