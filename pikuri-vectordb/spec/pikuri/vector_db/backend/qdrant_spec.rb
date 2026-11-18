# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'

describe Pikuri::VectorDb::Backend::Qdrant do
  JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze

  # Golden derived point ids: first 16 bytes of SHA1(chunk.id),
  # UUID-formatted. Hardcoded (not re-derived via Digest here) so
  # an accidental algorithm change fails the spec instead of
  # silently orphaning every stored point.
  UUID_A = '86f7e437-faa5-a7fc-e15d-1ddcb9eaeaea' # SHA1('a')
  UUID_B = 'e9d71f5e-e7c9-2d6d-c9e9-2ffdad17b8bd' # SHA1('b')

  def build_connection(&block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter :test, stubs
    end
  end

  let(:collection_path) { '/collections/test-coll' }

  def build_backend(conn:)
    Pikuri::VectorDb::Backend::Qdrant.new(
      host: 'localhost', port: 6333,
      collection: 'test-coll', connection: conn
    )
  end

  # Stub responses for the existence probe.
  def exists_response(exists)
    [200, JSON_HEADERS, { result: { exists: exists }, status: 'ok' }.to_json]
  end

  # A connection where the collection already exists, plus
  # whatever extra stubs the block registers.
  def with_existing_collection(&block)
    build_connection do |stub|
      stub.get("#{collection_path}/exists") { |_| exists_response(true) }
      block.call(stub)
    end
  end

  describe '#initialize' do
    it 'rejects empty host' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Backend::Qdrant.new(host: '', port: 6333, collection: 'c')
      end
    end

    it 'rejects empty collection' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Backend::Qdrant.new(host: 'localhost', port: 6333, collection: '')
      end
    end

    it 'does not call the server on construction (lazy)' do
      # No stubs registered → any HTTP call would raise. Reaching
      # the end of the block proves no call happened.
      conn = build_connection { |_| }
      backend = build_backend(conn: conn)
      refute_nil backend
    end
  end

  describe '#upsert' do
    let(:c_a) { Pikuri::VectorDb::Chunk.new(id: 'a', source: 'docs/a.md', text: 'apple', metadata: { ordinal: 0 }) }
    let(:c_b) { Pikuri::VectorDb::Chunk.new(id: 'b', source: 'docs/b.md', text: 'banana', metadata: { ordinal: 64 }) }
    let(:v_a) { [1.0, 0.0, 0.0] }
    let(:v_b) { [0.0, 1.0, 0.0] }

    it 'creates the collection on first upsert and sends the expected points' do
      received_upsert_body = nil
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") { |_| exists_response(false) }
        stub.put(collection_path) { |_| [200, JSON_HEADERS, '{"result":true,"status":"ok"}'] }
        stub.put("#{collection_path}/points?wait=true") do |env|
          received_upsert_body = JSON.parse(env.body)
          [200, JSON_HEADERS, '{"result":{"status":"completed"},"status":"ok"}']
        end
      end

      build_backend(conn: conn).upsert(chunks: [c_a, c_b], vectors: [v_a, v_b])

      points = received_upsert_body['points']
      # Point ids are the derived UUIDs; the readable chunk id,
      # source, text, and stringified metadata ride in the payload.
      assert_equal [UUID_A, UUID_B], points.map { |p| p['id'] }
      assert_equal [v_a, v_b], points.map { |p| p['vector'] }
      assert_equal({ 'id' => 'a', 'source' => 'docs/a.md', 'text' => 'apple', 'ordinal' => 0 },
                   points[0]['payload'])
      assert_equal({ 'id' => 'b', 'source' => 'docs/b.md', 'text' => 'banana', 'ordinal' => 64 },
                   points[1]['payload'])
    end

    it 'creates the collection with the first batch dim and cosine distance' do
      received_create_body = nil
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") { |_| exists_response(false) }
        stub.put(collection_path) do |env|
          received_create_body = JSON.parse(env.body)
          [200, JSON_HEADERS, '{"result":true,"status":"ok"}']
        end
        stub.put("#{collection_path}/points?wait=true") { |_| [200, JSON_HEADERS, '{}'] }
      end

      build_backend(conn: conn).upsert(chunks: [c_a], vectors: [v_a])

      assert_equal 3, received_create_body.dig('vectors', 'size')
      assert_equal 'Cosine', received_create_body.dig('vectors', 'distance')
    end

    it 'treats 409 on create as already-exists (race with another writer)' do
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") { |_| exists_response(false) }
        stub.put(collection_path) { |_| [409, JSON_HEADERS, '{"status":{"error":"already exists"}}'] }
        stub.put("#{collection_path}/points?wait=true") { |_| [200, JSON_HEADERS, '{}'] }
      end

      build_backend(conn: conn).upsert(chunks: [c_a], vectors: [v_a]) # no raise
    end

    it 'memoizes existence; subsequent upserts skip the probe and create' do
      probe_calls = 0
      upsert_calls = 0
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") do |_|
          probe_calls += 1
          exists_response(false)
        end
        stub.put(collection_path) { |_| [200, JSON_HEADERS, '{"result":true}'] }
        stub.put("#{collection_path}/points?wait=true") do |_|
          upsert_calls += 1
          [200, JSON_HEADERS, '{}']
        end
      end

      backend = build_backend(conn: conn)
      backend.upsert(chunks: [c_a], vectors: [v_a])
      backend.upsert(chunks: [c_b], vectors: [v_b])

      assert_equal 1, probe_calls # probe only on first
      assert_equal 2, upsert_calls
    end

    it 'raises on empty input (matches InMemory contract)' do
      conn = build_connection { |_| }
      backend = build_backend(conn: conn)
      assert_raises(ArgumentError) { backend.upsert(chunks: [], vectors: []) }
    end

    it 'raises on length mismatch (matches InMemory contract)' do
      conn = build_connection { |_| }
      backend = build_backend(conn: conn)
      assert_raises(ArgumentError) { backend.upsert(chunks: [c_a], vectors: [v_a, v_b]) }
    end

    it 'raises on HTTP non-2xx from upsert' do
      conn = with_existing_collection do |stub|
        stub.put("#{collection_path}/points?wait=true") do |_|
          [500, JSON_HEADERS, '{"status":{"error":"oops"}}']
        end
      end

      err = assert_raises(RuntimeError) { build_backend(conn: conn).upsert(chunks: [c_a], vectors: [v_a]) }
      assert_match(/HTTP 500/, err.message)
    end

    it 'wraps Faraday::Error from the probe as a loud RuntimeError' do
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") { |_| raise Faraday::ConnectionFailed, 'no route' }
      end

      err = assert_raises(RuntimeError) { build_backend(conn: conn).upsert(chunks: [c_a], vectors: [v_a]) }
      assert_match(/ConnectionFailed/, err.message)
    end
  end

  describe '#query' do
    let(:vector) { [1.0, 0.0, 0.0] }

    it 'returns [] when the collection does not exist yet' do
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") { |_| exists_response(false) }
      end

      assert_equal [], build_backend(conn: conn).query(vector: vector, top_k: 5)
    end

    it 'parses the Qdrant response into Result objects with sources/metadata restored' do
      payload = {
        result: [
          { id: UUID_A, score: 0.97,
            payload: { 'id' => 'a', 'source' => 'docs/a.md', 'text' => 'apple', 'ordinal' => 0 } },
          { id: UUID_B, score: 0.42,
            payload: { 'id' => 'b', 'source' => 'docs/b.md', 'text' => 'banana', 'ordinal' => 64 } }
        ],
        status: 'ok'
      }
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/search") { |_| [200, JSON_HEADERS, payload.to_json] }
      end

      results = build_backend(conn: conn).query(vector: vector, top_k: 5)

      assert_equal 2, results.size
      # The readable chunk id from the payload, never the point UUID.
      assert_equal 'a', results[0].chunk.id
      assert_equal 'docs/a.md', results[0].chunk.source
      assert_equal 'apple', results[0].chunk.text
      # Symbol keys restored on round-trip; reserved keys stripped.
      assert_equal({ ordinal: 0 }, results[0].chunk.metadata)
      # Qdrant's score is already a cosine similarity — passthrough,
      # no 1-distance conversion.
      assert_in_delta 0.97, results[0].score, 0.0001
      assert_in_delta 0.42, results[1].score, 0.0001
    end

    it 'sends the expected search body shape' do
      captured = []
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/search") do |env|
          captured << JSON.parse(env.body)
          [200, JSON_HEADERS, '{"result":[],"status":"ok"}']
        end
      end

      build_backend(conn: conn).query(vector: vector, top_k: 7)

      assert_equal vector, captured.first['vector']
      assert_equal 7, captured.first['limit']
      assert_equal true, captured.first['with_payload']
    end

    it 'raises on non-positive top_k (matches InMemory)' do
      conn = build_connection { |_| }
      backend = build_backend(conn: conn)
      assert_raises(ArgumentError) { backend.query(vector: vector, top_k: 0) }
      assert_raises(ArgumentError) { backend.query(vector: vector, top_k: -1) }
    end

    it 'raises on HTTP non-2xx' do
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/search") { |_| [500, JSON_HEADERS, '{}'] }
      end

      err = assert_raises(RuntimeError) { build_backend(conn: conn).query(vector: vector, top_k: 5) }
      assert_match(/HTTP 500/, err.message)
    end
  end

  describe '#count' do
    it 'returns 0 when the collection does not exist yet' do
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") { |_| exists_response(false) }
      end

      assert_equal 0, build_backend(conn: conn).count
    end

    it 'returns the exact count from the server' do
      captured = nil
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/count") do |env|
          captured = JSON.parse(env.body)
          [200, JSON_HEADERS, { result: { count: 42 }, status: 'ok' }.to_json]
        end
      end

      assert_equal 42, build_backend(conn: conn).count
      assert_equal true, captured['exact']
    end
  end

  describe '#delete_all' do
    it 'is a no-op when the collection was never created' do
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") { |_| exists_response(false) }
      end
      # Reaching the assertion without an HTTP DELETE-call stub
      # would have errored if DELETE was issued.
      build_backend(conn: conn).delete_all
    end

    it 'DELETEs the collection' do
      delete_calls = 0
      conn = with_existing_collection do |stub|
        stub.delete(collection_path) do |_|
          delete_calls += 1
          [200, JSON_HEADERS, '{"result":true,"status":"ok"}']
        end
      end

      build_backend(conn: conn).delete_all

      assert_equal 1, delete_calls
    end

    it 'clears the existence memo — the next upsert re-creates' do
      chunk = Pikuri::VectorDb::Chunk.new(id: 'a', source: 'docs/a.md', text: 'apple', metadata: {})
      probes = []
      creates = 0
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") do |_|
          probes << :probe
          # exists before delete_all; gone after.
          exists_response(probes.size == 1)
        end
        stub.delete(collection_path) { |_| [200, JSON_HEADERS, '{"result":true}'] }
        stub.put(collection_path) do |_|
          creates += 1
          [200, JSON_HEADERS, '{"result":true}']
        end
        stub.put("#{collection_path}/points?wait=true") { |_| [200, JSON_HEADERS, '{}'] }
      end

      backend = build_backend(conn: conn)
      backend.delete_all
      backend.upsert(chunks: [chunk], vectors: [[1.0, 0.0, 0.0]])

      assert_equal 2, probes.size # re-probed after the memo reset
      assert_equal 1, creates
    end

    it 'treats 404 as idempotent (already gone)' do
      conn = with_existing_collection do |stub|
        stub.delete(collection_path) { |_| [404, {}, ''] }
      end

      build_backend(conn: conn).delete_all # no raise
    end

    it 'raises on unexpected HTTP error (5xx)' do
      conn = with_existing_collection do |stub|
        stub.delete(collection_path) { |_| [500, {}, '{}'] }
      end

      err = assert_raises(RuntimeError) { build_backend(conn: conn).delete_all }
      assert_match(/HTTP 500/, err.message)
    end
  end

  describe '#delete_by_source' do
    it 'is a no-op when the collection was never created' do
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") { |_| exists_response(false) }
      end
      # No /points/delete stub: issuing one would error.
      build_backend(conn: conn).delete_by_source('docs/a.md')
    end

    it 'POSTs a source-filtered delete with wait=true' do
      captured = nil
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/delete?wait=true") do |env|
          captured = JSON.parse(env.body)
          [200, JSON_HEADERS, '{"result":{"status":"completed"}}']
        end
      end

      build_backend(conn: conn).delete_by_source('docs/a.md')

      assert_equal(
        { 'filter' => { 'must' => [{ 'key' => 'source', 'match' => { 'value' => 'docs/a.md' } }] } },
        captured
      )
    end
  end

  describe '#sources_with_hashes' do
    it 'returns {} when the collection does not exist yet' do
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") { |_| exists_response(false) }
      end

      assert_equal({}, build_backend(conn: conn).sources_with_hashes)
    end

    it 'requests one row per file (ordinal 0), payload-projected, vectors excluded' do
      captured = nil
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/scroll") do |env|
          captured = JSON.parse(env.body)
          [200, JSON_HEADERS, { result: { points: [], next_page_offset: nil } }.to_json]
        end
      end

      build_backend(conn: conn).sources_with_hashes

      assert_equal({ 'must' => [{ 'key' => 'ordinal', 'match' => { 'value' => 0 } }] },
                   captured['filter'])
      assert_equal %w[source hash], captured['with_payload']
      assert_equal false, captured['with_vector']
      assert_equal Pikuri::VectorDb::Backend::Qdrant::MANIFEST_PAGE_SIZE, captured['limit']
      refute captured.key?('offset') # first page: no cursor
    end

    it 'maps each source to its stored content hash' do
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/scroll") do |_|
          payload = { result: { points: [
            { id: UUID_A, payload: { 'source' => 'docs/a.md', 'hash' => 'aaa' } },
            { id: UUID_B, payload: { 'source' => 'docs/b.md', 'hash' => 'bbb' } }
          ], next_page_offset: nil } }
          [200, JSON_HEADERS, payload.to_json]
        end
      end

      result = build_backend(conn: conn).sources_with_hashes

      assert_equal({ 'docs/a.md' => 'aaa', 'docs/b.md' => 'bbb' }, result)
    end

    it 'pages via the server-side next_page_offset cursor until nil' do
      cursors = []
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/scroll") do |env|
          cursor = JSON.parse(env.body)['offset']
          cursors << cursor
          if cursor.nil?
            payload = { result: { points: [{ id: UUID_A, payload: { 'source' => 'a.md', 'hash' => 'h1' } }],
                                  next_page_offset: 'cursor-uuid-1' } }
          else
            payload = { result: { points: [{ id: UUID_B, payload: { 'source' => 'b.md', 'hash' => 'h2' } }],
                                  next_page_offset: nil } }
          end
          [200, JSON_HEADERS, payload.to_json]
        end
      end

      result = build_backend(conn: conn).sources_with_hashes

      assert_equal [nil, 'cursor-uuid-1'], cursors
      assert_equal({ 'a.md' => 'h1', 'b.md' => 'h2' }, result)
    end
  end

  describe '#source_indexed?' do
    it 'is false when the collection does not exist yet' do
      conn = build_connection do |stub|
        stub.get("#{collection_path}/exists") { |_| exists_response(false) }
      end

      refute build_backend(conn: conn).source_indexed?('docs/a.md')
    end

    it 'counts with a source filter and is true on a positive count' do
      captured = nil
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/count") do |env|
          captured = JSON.parse(env.body)
          [200, JSON_HEADERS, { result: { count: 3 } }.to_json]
        end
      end

      assert build_backend(conn: conn).source_indexed?('docs/a.md')

      assert_equal({ 'must' => [{ 'key' => 'source', 'match' => { 'value' => 'docs/a.md' } }] },
                   captured['filter'])
      assert_equal true, captured['exact']
    end

    it 'is false when the count is zero' do
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/count") do |_|
          [200, JSON_HEADERS, { result: { count: 0 } }.to_json]
        end
      end

      refute build_backend(conn: conn).source_indexed?('missing.md')
    end
  end

  describe '#replace_source' do
    let(:chunk) do
      Pikuri::VectorDb::Chunk.new(id: 'docs/a.md:0', source: 'docs/a.md', text: 'apple',
                                  metadata: { ordinal: 0, hash: 'aaa' })
    end

    it 'deletes the source then upserts the new chunks' do
      calls = []
      conn = with_existing_collection do |stub|
        stub.post("#{collection_path}/points/delete?wait=true") do |env|
          calls << [:delete, JSON.parse(env.body)]
          [200, JSON_HEADERS, '{}']
        end
        stub.put("#{collection_path}/points?wait=true") do |env|
          calls << [:upsert, JSON.parse(env.body)]
          [200, JSON_HEADERS, '{}']
        end
      end

      build_backend(conn: conn).replace_source(
        source: 'docs/a.md', chunks: [chunk], vectors: [[1.0, 0.0, 0.0]]
      )

      assert_equal %i[delete upsert], calls.map(&:first) # delete precedes upsert
      assert_equal 'docs/a.md', calls[0][1].dig('filter', 'must', 0, 'match', 'value')
      # SHA1('docs/a.md:0'), UUID-formatted — the golden derived id.
      assert_equal ['eee02408-59db-f96a-9263-fec4c3cf4d40'],
                   calls[1][1]['points'].map { |p| p['id'] }
      assert_equal ['docs/a.md:0'], calls[1][1]['points'].map { |p| p.dig('payload', 'id') }
    end
  end
end
