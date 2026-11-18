# frozen_string_literal: true

module Pikuri
  module Rag
    module Backend
      # A {Pikuri::VectorDb::Backend} that is really two: a vector store and a
      # keyword store, written together and read separately. Hand it wherever
      # the bare vector backend went:
      #
      #   hybrid = Pikuri::Rag::Backend::Hybrid.new(
      #     vectors:  Pikuri::VectorDb::Backend::InMemory.new,
      #     keywords: Pikuri::Rag::Backend::Fts5.new
      #   )
      #   corpus = Pikuri::VectorDb::Corpus.new(backend: hybrid, source: '~/notes',
      #                                           embedder: embedder)
      #   corpus.index_all!                               # fills both, one extraction
      #
      #   hybrid.query(vector: v, top_k: 5)                # the vector leg
      #   hybrid.keyword_query(match: '"acme"', top_k: 5)  # the keyword leg
      #   hybrid.find(terms: ['"acme"'])                   # every matching document
      #
      # Because it is a duck rather than a subclass, the whole vectordb
      # indexing pipeline drives it unchanged: one walk, one extraction per
      # file, one content hash. Both stores hold the same
      # {Pikuri::VectorDb::Chunk}s, so both legs answer with the same ids and
      # the same +source+ citations — which is what makes fusing them a hash
      # lookup rather than a heuristic.
      #
      # A third index would be a third store here, not a rewrite: the writes
      # fan out and the reads stay separate, which is the whole of this class.
      #
      # It owns both stores and {#close}s both.
      #
      # == Which keyword store to pair with which vector store
      #
      # * {Pikuri::VectorDb::Backend::InMemory} → +Fts5.new+ (in RAM). Both
      #   reload from the corpus every boot, which is the teaching shape.
      # * Qdrant → +Fts5.new(store:)+ on a file under {Pikuri::Paths.cache},
      #   keyed by the collection name, so the two persist together.
      #
      # A mismatch is *correct* rather than broken — "Indexed means both
      # stores hold it" below makes the boot sweep repair whichever store is
      # behind — but a persistent vector store beside an in-RAM keyword index
      # pays a full re-embed at every boot. Guidance, not a check: nothing here
      # can tell whether the vector store persists.
      #
      # Thread-safe, by holding no state of its own — both stores lock (see
      # {Fts5}) or serialize server-side.
      #
      # == Implementation details
      #
      # *Writes reach the keyword store first.* The embed already happened by
      # the time any write is reached ({Pikuri::VectorDb::Corpus} embeds
      # before writing), so the only thing that can fail *between* the two is
      # the vector store's network call — and the local write is the one that
      # cannot.
      #
      # *"Indexed" means both stores hold it*, which is a correctness invariant
      # rather than tidiness, and the only reason {#count} and
      # {#sources_with_hashes} do not simply delegate. It is what makes a
      # persisted Qdrant collection beside a fresh in-RAM keyword index
      # converge: the {Pikuri::VectorDb::Watcher}'s boot sweep sees the
      # keyword-less sources as unindexed and +replace_source+s them into both,
      # and +index_if_empty!+ sees +0+ and fills both. Without it, that pairing
      # boots to a silently empty +rag_search_keywords+.
      #
      # The same rule repairs a half-written pair: a raise between the two
      # writes leaves one store ahead, the intersection excludes that source,
      # and the next sweep reindexes it into both.
      class Hybrid
        # @param vectors [#upsert, #query, #delete_all, #count, #delete_by_source,
        #   #replace_source, #sources_with_hashes, #source_indexed?] any
        #   {Pikuri::VectorDb::Backend} implementation.
        # @param keywords [Fts5] the keyword store. Duck-typed like everything
        #   else here, but nothing else implements the shape.
        # @return [Hybrid]
        def initialize(vectors:, keywords:)
          @vectors = vectors
          @keywords = keywords
        end

        # @return [Fts5] the keyword store, whose +#store+ a host prints at
        #   boot.
        attr_reader :keywords

        # @return [#stems, #index_stems, #id] the keyword store's
        #   {Fts5#stemmer}, which a {Pikuri::Rag::Query} against {#keyword_query}
        #   or {#find} must be built with.
        def stemmer = @keywords.stemmer

        # Insert-or-replace by +chunk.id+ in both stores.
        #
        # @param chunks [Array<Pikuri::VectorDb::Chunk>]
        # @param vectors [Array<Array<Float>>] parallel to +chunks+; the
        #   keyword store takes none.
        # @return [void]
        # @raise [ArgumentError] from the vector store, on empty input, length
        #   mismatch or vector-dim mismatch.
        def upsert(chunks:, vectors:)
          @keywords.upsert(chunks: chunks)
          @vectors.upsert(chunks: chunks, vectors: vectors)
          nil
        end

        # Replace every chunk of one document in both stores — the
        # incremental-reindex unit.
        #
        # @param source [String] the {Pikuri::VectorDb::Chunk#source} replaced.
        # @param chunks [Array<Pikuri::VectorDb::Chunk>]
        # @param vectors [Array<Array<Float>>] parallel to +chunks+.
        # @return [void]
        # @raise [ArgumentError] from the vector store, as {#upsert}.
        def replace_source(source:, chunks:, vectors:)
          @keywords.replace_source(source: source, chunks: chunks)
          @vectors.replace_source(source: source, chunks: chunks, vectors: vectors)
          nil
        end

        # Drop one document from both stores; no-op when absent.
        #
        # @param source [String]
        # @return [void]
        def delete_by_source(source)
          @keywords.delete_by_source(source)
          @vectors.delete_by_source(source)
          nil
        end

        # @return [void] empties both stores.
        def delete_all
          @keywords.delete_all
          @vectors.delete_all
          nil
        end

        # @param vector [Array<Float>]
        # @param top_k [Integer]
        # @return [Array<Pikuri::VectorDb::Backend::Result>] top-k nearest by
        #   cosine.
        def query(vector:, top_k:) = @vectors.query(vector: vector, top_k: top_k)

        # @param match [String] an FTS5 +MATCH+ expression from
        #   {Pikuri::Rag::Query}.
        # @param top_k [Integer]
        # @return [Array<Pikuri::VectorDb::Backend::Result>] bm25-ranked, best
        #   first. See {Fts5#keyword_query} for the score's scale.
        def keyword_query(match:, top_k:) = @keywords.keyword_query(match: match, top_k: top_k)

        # @param terms [Array<String>] one expression per word, from
        #   {Pikuri::Rag::Query.terms}.
        # @return [Array<DocumentMatch>] every document holding all of them.
        #   See {Fts5#find}.
        def find(terms:) = @keywords.find(terms: terms)

        # The membership gate +rag_read+ consults — one store, deliberately not
        # the intersection the two reads above use.
        #
        # While the stores disagree, the keyword leg can cite a source the read
        # tool then refuses. That refusal is the right one ("not in the indexed
        # corpus … run +rag_reindex+") and the next sweep closes the window,
        # whereas an intersecting gate would make a *correctly* indexed
        # document unreadable whenever the keyword half was the one lagging.
        #
        # @param source [String]
        # @return [Boolean] whether the *vector* store holds this source.
        def source_indexed?(source) = @vectors.source_indexed?(source)

        # @return [Integer] chunk count, or +0+ when either store is empty (see
        #   the class's "Indexed means both stores hold it").
        def count
          @keywords.count.zero? ? 0 : @vectors.count
        end

        # @return [Hash{String => String, nil}] +source+ → content hash, for
        #   the sources *both* stores hold (see the class's "Indexed means both
        #   stores hold it"). The hashes are the vector store's, which the
        #   corpus wrote first.
        def sources_with_hashes
          known = @keywords.sources_with_hashes
          @vectors.sources_with_hashes.select { |source, _hash| known.key?(source) }
        end

        # Close both stores. A server's container stays up: the server owns
        # it, not the store.
        #
        # @return [void]
        def close
          @keywords.close
          @vectors.close
          nil
        end
      end
    end
  end
end
