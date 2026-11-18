# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Embedder do
  # Stub +RubyLLM::Embedding.embed+, the call +RubyLLM::Context#embed+
  # delegates to, via +define_singleton_method+ — the pattern
  # pikuri's pikuri-core/spec/pikuri/agent_spec.rb established for ruby_llm singletons
  # (rspec-mocks isn't in the closure; AGENTS.md "Tests" convention).
  let(:fake_vectors) { [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]] }
  let(:captured_calls) { [] }
  let(:embedder) do
    described_class.new(server: 'http://localhost:8080', model: 'nomic-embed-text-v1.5')
  end

  before do
    @original_embed = RubyLLM::Embedding.method(:embed)
    captured = captured_calls
    fake_vectors_ref = fake_vectors
    fake_embedding_class = Struct.new(:vectors)
    RubyLLM::Embedding.define_singleton_method(:embed) do |texts, **kw|
      captured << { texts: texts, kw: kw }
      fake_embedding_class.new(fake_vectors_ref)
    end
  end

  after do
    original = @original_embed
    RubyLLM::Embedding.define_singleton_method(:embed) do |*args, **kw|
      original.call(*args, **kw)
    end
  end

  describe '#initialize' do
    it 'normalizes the server to exactly one trailing /v1' do
      ['http://localhost:8080', 'http://localhost:8080/', 'http://localhost:8080/v1',
       'http://localhost:8080/v1/'].each do |server|
        assert_equal 'http://localhost:8080/v1',
                     described_class.new(server: server, model: 'm').api_base, server
      end
    end
  end

  describe '#embed' do
    it 'passes texts through and returns vectors' do
      assert_equal fake_vectors, embedder.embed(%w[alpha beta])
      assert_equal 1, captured_calls.length
      assert_equal %w[alpha beta], captured_calls.first[:texts]
    end

    it "dials its own server and key, not the global config's" do
      described_class.new(server: 'http://gpu-box:9000', model: 'm', api_key: 'sekrit').embed(['hi'])

      config = captured_calls.first[:kw][:context].config
      assert_equal 'http://gpu-box:9000/v1', config.openai_api_base
      assert_equal 'sekrit', config.openai_api_key
      refute_equal 'http://gpu-box:9000/v1', RubyLLM.config.openai_api_base
    end

    it 'names the model as an OpenAI-compatible one, bypassing the registry' do
      embedder.embed(['hi'])

      kw = captured_calls.first[:kw]
      assert_equal 'nomic-embed-text-v1.5', kw[:model]
      assert_equal :openai, kw[:provider]
      assert_equal true, kw[:assume_model_exists]
    end

    it 'short-circuits empty input without an HTTP call' do
      assert_equal [], embedder.embed([])
      assert_empty captured_calls
    end

    it 'rejects non-Array input' do
      err = assert_raises(ArgumentError) { embedder.embed('one string') }
      assert_match(/expected Array<String>/, err.message)
    end

    it 'rejects an Array containing non-String elements' do
      err = assert_raises(ArgumentError) { embedder.embed(['ok', 42, 'also ok']) }
      assert_match(/all elements must be String/, err.message)
    end

    it 'propagates errors raised by ruby_llm verbatim (loud failure)' do
      RubyLLM::Embedding.define_singleton_method(:embed) do |*_args, **_kw|
        raise 'provider 503: service unavailable'
      end

      err = assert_raises(RuntimeError) { embedder.embed(['hi']) }
      assert_match(/provider 503/, err.message)
    end
  end
end

# The hook sits in ruby_llm's HTTP layer, below the +Embedding.embed+ stub
# above, so these run the real request path against Faraday's test adapter
# (the technique pikuri's pikuri-core/spec/integration_spec.rb uses).
describe Pikuri::VectorDb::Embedder, 'around_request' do
  let(:events) { [] }
  let(:hook) do
    log = events
    lambda do |api_base, cancellable, &request|
      log << [:enter, api_base, cancellable]
      request.call.tap { log << :leave }
    end
  end

  before do
    # ruby_llm caches Faraday connections process-wide; drop any an earlier
    # spec built, or the Faraday.new stub below is never reached.
    RubyLLM::Transport::Connection.cache.clear
    log = events
    stubs = Faraday::Adapter::Test::Stubs.new
    stubs.post('/v1/embeddings') do |env|
      log << :http
      count = JSON.parse(env.body)['input'].size
      data = Array.new(count) { |i| { object: 'embedding', index: i, embedding: [i.to_f, 1.0] } }
      [200, { 'Content-Type' => 'application/json' }, JSON.generate(object: 'list', model: 'm', data: data)]
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

  it 'brackets each embed request, handing the hook the api_base and no cancellable' do
    embedder = described_class.new(server: 'http://emb.test', model: 'm', around_request: hook)

    assert_equal [[0.0, 1.0], [1.0, 1.0]], embedder.embed(%w[a b])
    assert_equal [[:enter, 'http://emb.test/v1', nil], :http, :leave], events
  end

  it 'embeds without a hook too' do
    embedder = described_class.new(server: 'http://emb.test', model: 'm')

    assert_equal [[0.0, 1.0]], embedder.embed(%w[a])
    assert_equal [:http], events
  end
end
