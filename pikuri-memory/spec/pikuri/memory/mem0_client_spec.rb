# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'

describe Pikuri::Memory::Mem0Client do
  # Faraday::Adapter::Test stubs, same shape as pikuri-vectordb's
  # client specs: exercise request body + response parsing through the
  # exact middleware production uses.
  def build_connection(&block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter :test, stubs
    end
  end

  JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze

  describe '#initialize' do
    it 'rejects a blank endpoint' do
      assert_raises(ArgumentError) { Pikuri::Memory::Mem0Client.new(endpoint: '') }
      assert_raises(ArgumentError) { Pikuri::Memory::Mem0Client.new(endpoint: nil) }
    end

    it 'applies a generous default read timeout to the built connection' do
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub')
      conn = client.instance_variable_get(:@connection)
      assert_equal Pikuri::Memory::Mem0Client::DEFAULT_TIMEOUT, conn.options.timeout
    end

    it 'honours the timeout: kwarg' do
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', timeout: 42)
      conn = client.instance_variable_get(:@connection)
      assert_equal 42, conn.options.timeout
    end

    it 'lets PIKURI_MEMORY_TIMEOUT override the timeout: kwarg' do
      ENV['PIKURI_MEMORY_TIMEOUT'] = '7'
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', timeout: 42)
      conn = client.instance_variable_get(:@connection)
      assert_equal 7, conn.options.timeout
    ensure
      ENV.delete('PIKURI_MEMORY_TIMEOUT')
    end
  end

  describe '#add' do
    it 'POSTs a single user-role message with user_id + infer and returns Records' do
      received = nil
      conn = build_connection do |stub|
        stub.post('/memories') do |env|
          received = JSON.parse(env.body)
          [200, JSON_HEADERS, { results: [{ id: 'm1', memory: 'The user is vegetarian', event: 'ADD' }] }.to_json]
        end
      end
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      records = client.add(content: 'I am vegetarian', user_id: 'martin')

      assert_equal([{ 'role' => 'user', 'content' => 'I am vegetarian' }], received['messages'])
      assert_equal 'martin', received['user_id']
      assert_equal true, received['infer']
      assert_equal 1, records.size
      assert_equal 'm1', records.first.id
      assert_equal 'The user is vegetarian', records.first.text
      assert_equal 'ADD', records.first.event
    end

    it 'includes the prompt override only when given' do
      bodies = []
      conn = build_connection do |stub|
        stub.post('/memories') do |env|
          bodies << JSON.parse(env.body)
          [200, JSON_HEADERS, { results: [] }.to_json]
        end
      end
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      client.add(content: 'x', user_id: 'u')
      client.add(content: 'x', user_id: 'u', prompt: 'CUSTOM')

      refute bodies[0].key?('prompt')
      assert_equal 'CUSTOM', bodies[1]['prompt']
    end

    it 'rejects blank content or user_id without an HTTP call' do
      conn = build_connection { |_| } # any HTTP call would raise
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      assert_raises(ArgumentError) { client.add(content: '  ', user_id: 'u') }
      assert_raises(ArgumentError) { client.add(content: 'x', user_id: '') }
    end

    it 'raises RuntimeError on a non-2xx response' do
      conn = build_connection do |stub|
        stub.post('/memories') { [500, JSON_HEADERS, { error: 'boom' }.to_json] }
      end
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      err = assert_raises(RuntimeError) { client.add(content: 'x', user_id: 'u') }
      assert_match(/HTTP 500/, err.message)
    end
  end

  describe '#search' do
    it 'POSTs query + user_id filter + top_k and returns ranked Records with score + created_at' do
      received = nil
      conn = build_connection do |stub|
        stub.post('/search') do |env|
          received = JSON.parse(env.body)
          [200, JSON_HEADERS, {
            results: [
              { id: 'a', memory: 'lives in Brno', score: 0.78, created_at: '2026-05-01T10:00:00Z' },
              { id: 'b', memory: 'writes Ruby', score: 0.61, created_at: '2026-05-02T10:00:00Z' }
            ]
          }.to_json]
        end
      end
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      records = client.search(query: 'where?', user_id: 'martin', top_k: 5)

      assert_equal 'where?', received['query']
      assert_equal({ 'user_id' => 'martin' }, received['filters'])
      assert_equal 5, received['top_k']
      refute received.key?('threshold')
      assert_equal %w[a b], records.map(&:id)
      assert_in_delta 0.78, records.first.score, 0.0001
      assert_equal '2026-05-01T10:00:00Z', records.first.created_at
    end

    it 'passes threshold through when set' do
      received = nil
      conn = build_connection do |stub|
        stub.post('/search') do |env|
          received = JSON.parse(env.body)
          [200, JSON_HEADERS, { results: [] }.to_json]
        end
      end
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      client.search(query: 'q', user_id: 'u', top_k: 3, threshold: 0.4)

      assert_in_delta 0.4, received['threshold'], 0.0001
    end

    it 'rejects non-positive top_k' do
      conn = build_connection { |_| }
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      assert_raises(ArgumentError) { client.search(query: 'q', user_id: 'u', top_k: 0) }
    end
  end

  describe '#get_all' do
    it 'GETs /memories?user_id= and returns Records (envelope shape)' do
      conn = build_connection do |stub|
        stub.get('/memories') do |env|
          assert_equal 'martin', env.params['user_id']
          [200, JSON_HEADERS, { results: [{ id: 'a', memory: 'fact one' }] }.to_json]
        end
      end
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      records = client.get_all(user_id: 'martin')

      assert_equal 1, records.size
      assert_equal 'fact one', records.first.text
      assert_nil records.first.score
    end

    it 'tolerates a bare-array response shape' do
      conn = build_connection do |stub|
        stub.get('/memories') { [200, JSON_HEADERS, [{ id: 'a', memory: 'fact' }].to_json] }
      end
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      assert_equal ['fact'], client.get_all(user_id: 'u').map(&:text)
    end
  end

  describe '#delete' do
    it 'DELETEs /memories/{id} and treats 404 as already gone' do
      conn = build_connection do |stub|
        stub.delete('/memories/gone') { [404, JSON_HEADERS, ''] }
        stub.delete('/memories/ok')   { [200, JSON_HEADERS, ''] }
      end
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      client.delete(id: 'gone') # must not raise
      client.delete(id: 'ok')   # must not raise
    end

    it 'raises on a 500' do
      conn = build_connection do |stub|
        stub.delete('/memories/x') { [500, JSON_HEADERS, ''] }
      end
      client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://stub', connection: conn)

      assert_raises(RuntimeError) { client.delete(id: 'x') }
    end
  end
end
