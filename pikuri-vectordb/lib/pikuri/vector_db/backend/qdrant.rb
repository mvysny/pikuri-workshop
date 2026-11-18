# frozen_string_literal: true

require 'faraday'
require 'json'
require 'digest'

module Pikuri
  module VectorDb
    module Backend
      # Thin Faraday HTTP client against a self-hosted Qdrant server (1.x REST,
      # 1.8+), the persistent backend (see +pikuri-vectordb/design/architecture.md+
      # for why Qdrant). Same duck-typed {Backend} protocol as {InMemory} (same
      # method names, return shapes, and +ArgumentError+ contract on empty input
      # / non-positive +top_k+; the vector-dim contract diverges — see below).
      # Hand-rolled rather than a client-gem dep so the wire protocol stays
      # auditable in one readable file; the 1.x REST surface is stable, so
      # tracking it by hand is cheap.
      #
      # Two ways to get one: **bring your own** — +Qdrant.new(host:, port:,
      # collection:)+ against an existing deployment (this class is purely the
      # HTTP client); or **let pikuri manage it** — {Server::Qdrant.ensure_running}'s
      # +#client(collection:)+ returns a +Qdrant+ pointed at a supervised
      # container. Container lifecycle and HTTP wire protocol share nothing, so
      # each is its own class.
      #
      # Endpoints used are all under +/collections/{name}+ (+exists+, +PUT+ to
      # create, +points+ upsert, +points/search+, +points/count+,
      # +points/delete+, +points/scroll+, +DELETE+).
      #
      # == Point ids: chunk id → derived UUID
      #
      # Qdrant point ids must be unsigned ints or UUIDs, so the {Chunk}'s
      # readable +"source:ordinal"+ id can't be the point id. Each is derived as
      # the first 16 bytes of +SHA1(chunk.id)+ UUID-formatted: deterministic, so
      # re-upserting the same chunk id replaces the old point (collision
      # probability negligible at any corpus size). The real chunk id rides in
      # the payload's reserved +id+ key and is restored out, so callers never
      # see the UUID.
      #
      # == Contracts
      #
      # * *Payload*: Qdrant has no separate document store, so everything beyond
      #   the vector lives in the point payload — {RESERVED_PAYLOAD_KEYS} carry
      #   the fixed fields, +metadata+ is merged alongside. JSON round-trips
      #   Symbol keys to Strings, so {#upsert} stringifies and {#query}
      #   re-symbolizes — a queried {Chunk} looks identical to one stored in
      #   {InMemory}.
      # * *Cosine, no conversion*: created +distance: 'Cosine'+; Qdrant's +score+
      #   already *is* a similarity on {InMemory}'s scale, passed through
      #   untouched.
      # * *Vector-dim* diverges from {InMemory}: Qdrant fixes the dim at
      #   *collection creation*, so {#upsert} creates it with the first batch's
      #   size; a later mismatch is HTTP 4xx → +RuntimeError+, not the
      #   +ArgumentError+ InMemory raises. Same loud-failure shape; not worth
      #   parsing Qdrant's error envelope to coerce the class.
      # * *No payload indexes* (deliberate): every filtered call is an exact
      #   scan that works unindexed, milliseconds at pikuri's 10³–10⁵ scale.
      class Qdrant
        # Rows per +/scroll+ page in {#sources_with_hashes} — caps the parse
        # working set of the boot manifest on a large corpus (one row per file,
        # so a 50k-file corpus is ~50 localhost round trips, not one multi-MB
        # response). Small corpora finish in one page.
        MANIFEST_PAGE_SIZE = 1_000

        # Payload keys reserved for the {Chunk}'s fixed fields; user metadata
        # with these keys would collide, so the {Corpus} never sets them.
        RESERVED_PAYLOAD_KEYS = %w[id source text].freeze

        # @param host [String]
        # @param port [Integer]
        # @param collection [String] Qdrant collection name — an engine-specific
        #   identifier, so it lives here, not on the {Corpus} (a no-op for
        #   {InMemory}).
        # @param connection [Faraday::Connection, nil] DI point for tests.
        # @return [Qdrant]
        # @raise [ArgumentError] on empty +host+ or empty +collection+.
        def initialize(host:, port:, collection:, connection: nil)
          raise ArgumentError, 'host must be non-empty' if host.nil? || host.to_s.empty?
          raise ArgumentError, 'collection must be non-empty' if collection.nil? || collection.to_s.empty?

          @host = host
          @port = port
          @collection = collection
          @known_exists = false
          @connection = connection || Faraday.new(url: "http://#{host}:#{port}") do |f|
            f.request :json
            f.response :json
            f.adapter Faraday.default_adapter
          end
        end

        # Insert-or-replace by +chunk.id+ (via the derived point
        # UUID — see the class header). Parallel arrays of equal
        # length; raises on empty input or length mismatch (same
        # contract as {InMemory}). Creates the collection on
        # first use, fixing the vector dim to this batch's;
        # mismatched dims later surface as +RuntimeError+ from a
        # 4xx response.
        #
        # @param chunks [Array<Chunk>]
        # @param vectors [Array<Array<Float>>]
        # @return [void]
        # @raise [ArgumentError] on empty input or length mismatch.
        # @raise [RuntimeError] on HTTP failure.
        def upsert(chunks:, vectors:)
          raise ArgumentError, 'upsert called with empty chunks/vectors' if chunks.empty?
          if chunks.size != vectors.size
            raise ArgumentError, "size mismatch: #{chunks.size} chunks vs #{vectors.size} vectors"
          end

          ensure_collection!(dim: vectors.first.size)

          points = chunks.each_with_index.map do |c, i|
            payload = { 'id' => c.id, 'source' => c.source, 'text' => c.text }
            c.metadata.each { |k, v| payload[k.to_s] = v }
            { id: point_id(c.id), vector: vectors[i], payload: payload }
          end

          request_json(:put, "#{collection_path}/points?wait=true", { points: points })
          nil
        end

        # k-NN query by cosine similarity. Returns at most
        # +top_k+ {Backend::Result}s descending by score. Qdrant's
        # +score+ is already a cosine similarity (higher =
        # better), so it passes through unconverted — same scale
        # as {InMemory}.
        #
        # @param vector [Array<Float>]
        # @param top_k [Integer]
        # @return [Array<Backend::Result>]
        # @raise [ArgumentError] on non-positive +top_k+.
        # @raise [RuntimeError] on HTTP failure.
        def query(vector:, top_k:)
          raise ArgumentError, "top_k must be positive (got #{top_k})" if top_k <= 0

          # Never upserted → no collection → semantic answer is
          # "no hits".
          return [] unless collection_exists?

          body = request_json(:post, "#{collection_path}/points/search", {
                                vector: vector,
                                limit: top_k,
                                with_payload: true
                              })

          hits = body['result'] || []
          hits.map do |hit|
            payload = hit['payload'] || {}
            chunk_meta = {}
            payload.each do |k, v|
              next if RESERVED_PAYLOAD_KEYS.include?(k)

              chunk_meta[k.to_sym] = v
            end

            chunk = Chunk.new(
              id: payload['id'] || '', source: payload['source'] || '',
              text: payload['text'] || '', metadata: chunk_meta
            )
            Result.new(chunk: chunk, score: hit['score'].to_f)
          end
        end

        # Drop the collection. Next +#upsert+ re-creates from
        # scratch (with that batch's vector dim) — the v1
        # nuke-and-reload reindex path. No-op if no collection
        # was ever created; 404 on the DELETE is treated as
        # "already gone" — idempotent.
        #
        # @return [void]
        # @raise [RuntimeError] on unexpected HTTP failure.
        def delete_all
          return nil unless collection_exists?

          response = @connection.delete(collection_path)
          unless [200, 404].include?(response.status)
            raise "Backend::Qdrant: DELETE #{collection_path} returned " \
                  "HTTP #{response.status}: #{response.body.inspect}"
          end
          @known_exists = false
          nil
        end

        # @return [Integer] current chunk count (exact). Zero
        #   before the first +#upsert+.
        # @raise [RuntimeError] on HTTP failure.
        def count
          return 0 unless collection_exists?

          body = request_json(:post, "#{collection_path}/points/count", { exact: true })
          n = body.is_a?(Hash) ? body.dig('result', 'count') : nil
          raise "Backend::Qdrant: count response missing result.count (got #{body.inspect})" unless n.is_a?(Integer)

          n
        end

        # Remove every chunk whose +source+ matches, via a
        # payload-filtered +points/delete+. The scoped counterpart
        # to {#delete_all}. No-op when the collection doesn't
        # exist yet.
        #
        # @param source [String] the {Chunk#source} to purge.
        # @return [void]
        # @raise [RuntimeError] on HTTP failure.
        def delete_by_source(source)
          return nil unless collection_exists?

          request_json(:post, "#{collection_path}/points/delete?wait=true",
                       { filter: source_filter(source) })
          nil
        end

        # Replace all chunks for one +source+: delete the old set, then upsert
        # the new (the incremental-reindex unit, {Corpus#reindex_file!}).
        #
        # *Not transactional* (the InMemory divergence): two HTTP calls, so a
        # +#query+ between them can see the source with zero chunks — a window
        # {InMemory#replace_source} closes with its monitor but Qdrant can't. The
        # {Corpus} mitigates the common failure by embedding *before* calling
        # here, so an embedder outage never reaches this and the old chunks stay.
        # Delete-then-upsert, not the reverse — the reverse would delete the
        # just-written chunks.
        #
        # @param source [String] the {Chunk#source} being replaced.
        # @param chunks [Array<Chunk>] the new chunk set.
        # @param vectors [Array<Array<Float>>] parallel to +chunks+.
        # @return [void]
        # @raise [ArgumentError] on empty input or length mismatch.
        # @raise [RuntimeError] on HTTP failure.
        def replace_source(source:, chunks:, vectors:)
          delete_by_source(source)
          upsert(chunks: chunks, vectors: vectors)
          nil
        end

        # The boot-sweep reference: +source+ → stored content hash, one payload
        # row per *file* (filter +ordinal == 0+), projected to +source+/+hash+,
        # vectors excluded, paged by Qdrant's own scroll cursor
        # (+next_page_offset+ — no client-side offset arithmetic). Assumes the
        # manifest isn't mutating mid-read; the {Watcher}
        # drives it from its single worker thread.
        #
        # @return [Hash{String => String, nil}] +source+ → content hash. Empty
        #   when the collection doesn't exist yet.
        # @raise [RuntimeError] on HTTP failure.
        def sources_with_hashes
          return {} unless collection_exists?

          result = {}
          cursor = nil
          loop do
            request = {
              filter: { must: [{ key: 'ordinal', match: { value: 0 } }] },
              with_payload: %w[source hash],
              with_vector: false,
              limit: MANIFEST_PAGE_SIZE
            }
            request[:offset] = cursor unless cursor.nil?

            body = request_json(:post, "#{collection_path}/points/scroll", request)
            points = body.is_a?(Hash) ? (body.dig('result', 'points') || []) : []
            points.each do |point|
              payload = point['payload']
              next unless payload.is_a?(Hash) && payload['source']

              result[payload['source']] = payload['hash']
            end

            cursor = body.is_a?(Hash) ? body.dig('result', 'next_page_offset') : nil
            break if cursor.nil?
          end
          result
        end

        # Is +source+ in the corpus? A payload-filtered exact
        # count — O(1) transport regardless of corpus size, never
        # the full {#sources_with_hashes} manifest. See the
        # Backend protocol yardoc.
        #
        # @param source [String] the {Chunk#source} to test.
        # @return [Boolean] true if at least one chunk has this source.
        # @raise [RuntimeError] on HTTP failure.
        def source_indexed?(source)
          return false unless collection_exists?

          body = request_json(:post, "#{collection_path}/points/count",
                              { filter: source_filter(source), exact: true })
          n = body.is_a?(Hash) ? body.dig('result', 'count') : nil
          n.is_a?(Integer) && n.positive?
        end

        # A no-op: Faraday's default adapter opens a connection per request, so
        # none stays open. The container is {Server::Qdrant}'s to close.
        #
        # @return [void]
        def close = nil

        private

        def collection_path
          "/collections/#{@collection}"
        end

        # Qdrant filter clause matching one +source+ payload value.
        def source_filter(source)
          { must: [{ key: 'source', match: { value: source } }] }
        end

        # Derive the Qdrant point id from a chunk id: first 16
        # bytes of SHA1, UUID-formatted. Deterministic — see the
        # class header.
        def point_id(chunk_id)
          hex = Digest::SHA1.hexdigest(chunk_id)
          "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
        end

        # Probe whether the collection exists without creating it
        # — the short-circuit for reads before any upsert.
        # Memoizes only the positive answer (a collection never
        # disappears under us except via {#delete_all}, which
        # resets the memo); a negative is re-probed each time.
        def collection_exists?
          return true if @known_exists

          response = @connection.get("#{collection_path}/exists")
          unless response.status == 200
            raise "Backend::Qdrant: GET #{collection_path}/exists returned " \
                  "HTTP #{response.status}: #{response.body.inspect}"
          end

          exists = response.body.is_a?(Hash) && response.body.dig('result', 'exists') == true
          @known_exists = true if exists
          exists
        rescue Faraday::Error => e
          raise "Backend::Qdrant: #{e.class.name.split('::').last} " \
                "calling #{collection_path}/exists: #{e.message}"
        end

        # Create the collection if missing, fixing the vector dim
        # and cosine distance. A 409 from the PUT means another
        # writer created it between the probe and the create —
        # equally fine (and any *wrong* 409 would surface loudly
        # on the very next upsert).
        def ensure_collection!(dim:)
          return if collection_exists?

          response = @connection.put(collection_path) do |req|
            req.headers['Content-Type'] = 'application/json'
            req.body = { vectors: { size: dim, distance: 'Cosine' } }
          end

          unless [200, 409].include?(response.status)
            raise "Backend::Qdrant: PUT #{collection_path} returned " \
                  "HTTP #{response.status}: #{response.body.inspect}"
          end

          @known_exists = true
        rescue Faraday::Error => e
          raise "Backend::Qdrant: #{e.class.name.split('::').last} " \
                "calling #{collection_path}: #{e.message}"
        end

        # JSON request helper shared by every points/* call.
        # Centralises the error shape and Faraday::Error wrapping,
        # over any verb (Qdrant upserts via PUT). 202 is qdrant's "accepted, not
        # yet applied" for non-+wait+ writes.
        def request_json(method, path, body)
          response = @connection.public_send(method, path) do |req|
            req.headers['Content-Type'] = 'application/json'
            req.body = body
          end

          unless [200, 201, 202].include?(response.status)
            raise "Backend::Qdrant: #{method.to_s.upcase} #{path} returned " \
                  "HTTP #{response.status}: #{response.body.inspect}"
          end

          response.body
        rescue Faraday::Error => e
          raise "Backend::Qdrant: #{e.class.name.split('::').last} " \
                "calling #{path}: #{e.message}"
        end
      end
    end
  end
end
