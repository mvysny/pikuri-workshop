# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'faraday'
require 'faraday/adapter/test'

# Runs ruby_llm's real rerank path against Faraday's test adapter (the
# technique pikuri's pikuri-core/spec/integration_spec.rb uses), so the wire shape
# ruby_llm's +:gpustack+ provider speaks is pinned to llama-server's.
describe Pikuri::VectorDb::Reranker::LlamaServer do
  def json_headers = { 'Content-Type' => 'application/json' }

  let(:requests) { [] }

  # The stubbed server's answer: +@respond+ when a test sets one, else
  # llama-server's shape scoring document i as i.
  def answer(body)
    return @respond.call(body) if @respond

    results = body['documents'].each_index.map { |i| { index: i, relevance_score: i.to_f } }
    [200, json_headers, JSON.generate(model: 'm', object: 'list', results: results,
                                      usage: { prompt_tokens: 3, total_tokens: 3 })]
  end

  before do
    # ruby_llm caches Faraday connections process-wide; drop any an earlier
    # spec built, or the Faraday.new stub below is never reached.
    RubyLLM::Transport::Connection.cache.clear
    log = requests
    spec = self
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.post('/v1/rerank') do |env|
      body = JSON.parse(env.body)
      log << { body: body, headers: env.request_headers }
      spec.answer(body)
    end
    @original_faraday_new = Faraday.method(:new)
    original = @original_faraday_new
    Faraday.define_singleton_method(:new) do |*args, **kwargs, &user_block|
      original.call(*args, **kwargs) do |faraday|
        user_block&.call(faraday)
        faraday.adapter :test, stubs
      end
    end
  end

  after do
    original = @original_faraday_new
    Faraday.define_singleton_method(:new) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) }
    RubyLLM::Transport::Connection.cache.clear
  end

  def reranker(**kw)
    described_class.new(server: 'http://rr.test', model: 'bge', **kw)
  end

  describe '#initialize' do
    it 'normalizes the server to exactly one trailing /v1' do
      ['http://rr.test', 'http://rr.test/', 'http://rr.test/v1', 'http://rr.test/v1/'].each do |server|
        assert_equal 'http://rr.test/v1', described_class.new(server: server, model: 'm').api_base, server
      end
    end
  end

  describe '#rerank' do
    it 'returns [] for an empty documents array without an HTTP call' do
      assert_equal [], reranker.rerank(query: 'anything', documents: [])
      assert_empty requests
    end

    it 'POSTs model, query and documents, and returns Hits sorted descending by score' do
      @respond = lambda do |_body|
        results = [{ index: 1, relevance_score: 0.18 }, { index: 2, relevance_score: 0.92 },
                   { index: 0, relevance_score: 0.41 }]
        [200, json_headers, JSON.generate(results: results)]
      end

      hits = reranker.rerank(query: 'capital of France?', documents: %w[Berlin Madrid Paris])

      assert_equal [2, 0, 1], hits.map(&:index)
      assert_equal [0.92, 0.41, 0.18], hits.map(&:score)
      assert_equal({ 'model' => 'bge', 'query' => 'capital of France?', 'documents' => %w[Berlin Madrid Paris] },
                   requests.first[:body])
    end

    it 'sends a configured api_key as a Bearer Authorization header' do
      reranker(api_key: 'sekret').rerank(query: 'q', documents: ['d'])

      assert_equal 'Bearer sekret', requests.first[:headers]['Authorization']
    end

    it 'sends no Authorization header when api_key is nil' do
      reranker.rerank(query: 'q', documents: ['d'])

      refute requests.first[:headers].key?('Authorization')
    end

    it 'raises a RuntimeError naming the endpoint on an HTTP error' do
      @respond = ->(_body) { [401, json_headers, '{"error":"Invalid API Key"}'] }

      err = assert_raises(RuntimeError) { reranker.rerank(query: 'q', documents: ['d']) }
      assert_match(%r{rr\.test/v1/rerank}, err.message)
    end

    it 'raises rather than answering no hits when the body has no results' do
      @respond = ->(_body) { [200, json_headers, '{"oops":[]}'] }

      err = assert_raises(RuntimeError) { reranker.rerank(query: 'q', documents: ['d']) }
      assert_match(/scored 0 of 1 documents/, err.message)
    end

    it 'raises when an entry has no relevance_score' do
      @respond = ->(_body) { [200, json_headers, '{"results":[{"index":0}]}'] }

      assert_raises(RuntimeError) { reranker.rerank(query: 'q', documents: ['d']) }
    end
  end

  describe 'around_request' do
    it 'brackets each rerank request, handing the hook the api_base and no cancellable' do
      events = []
      hook = lambda do |api_base, cancellable, &request|
        events << [:enter, api_base, cancellable]
        request.call.tap { events << :leave }
      end

      reranker(around_request: hook).rerank(query: 'q', documents: ['d'])

      assert_equal [[:enter, 'http://rr.test/v1', nil], :leave], events
      assert_equal 1, requests.length
    end
  end
end
