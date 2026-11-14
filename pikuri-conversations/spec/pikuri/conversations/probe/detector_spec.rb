# frozen_string_literal: true

require 'faraday'
require 'faraday/adapter/test'
require 'stringio'

# Drive +Probe::Detector.detect+ against an in-memory Faraday test
# adapter for the /props probe. Same +Faraday.new+ stub pattern as
# +spec/tool/scraper/simple_spec.rb+. The log sink is swapped to a
# +StringIO+ so probe-failure warnings can be asserted on without leaking
# to +$stderr+. +openai_base:+ is passed explicitly so the spec never
# touches global +RubyLLM.config+.
RSpec.describe Pikuri::Conversations::Probe::Detector do
  let(:buf) { StringIO.new }

  before do
    @original_io = Pikuri.log_io
    Pikuri.log_io = buf
  end

  after { Pikuri.log_io = @original_io }

  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:base)  { 'http://example.com/v1' }
  let(:url)   { 'http://example.com/props' }

  # "the probe learned nothing" — every failure path answers this exact value.
  let(:none) { Pikuri::Conversations::Probe::Detector::Props::NONE }

  def transport(model: 'm', provider: :openai, api_key: nil)
    Pikuri::Agent::ChatTransport.new(
      model: model, provider: provider, assume_model_exists: provider == :openai,
      api_key: api_key
    )
  end

  around do |example|
    original_new = Faraday.method(:new)
    test_stubs = stubs
    Faraday.define_singleton_method(:new) do |*_, **_|
      Faraday::Connection.new { |b| b.adapter :test, test_stubs }
    end
    begin
      example.run
    ensure
      Faraday.define_singleton_method(:new, original_new)
    end
  end

  describe 'gate + URL derivation' do
    it 'returns Props::NONE for a non-openai transport without probing' do
      # No stub registered: if a probe were attempted, the test adapter
      # would raise on the un-stubbed request.
      assert_equal none, described_class.detect(transport(provider: :anthropic), openai_base: base)
      assert_equal '', buf.string
    end

    it 'returns Props::NONE when the openai base is blank, without probing' do
      assert_equal none, described_class.detect(transport, openai_base: '')
      assert_equal '', buf.string
    end

    it 'never dials a .invalid host, the fake transport\'s server among them' do
      base = Pikuri::Testing.fake_transport(modalities: nil).api_base
      assert_equal none, described_class.detect(transport, openai_base: base)
      assert_nil described_class.detect_modalities(transport, openai_base: base)
      assert_nil described_class.props_url('http://INVALID./v1')
      assert_equal 'http://invalid.example.com/props', described_class.props_url('http://invalid.example.com')
      assert_equal '', buf.string
    end

    it 'strips a trailing /v1 to reach /props at the host root' do
      stubs.get(url) do
        [200, { 'content-type' => 'application/json' },
         JSON.generate('default_generation_settings' => { 'n_ctx' => 32_768 })]
      end
      assert_equal 32_768, described_class.detect(transport, openai_base: 'http://example.com/v1').n_ctx
    end

    it 'appends /props directly when the base has no /v1 suffix' do
      stubs.get(url) do
        [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => 4096 })]
      end
      assert_equal 4096, described_class.detect(transport, openai_base: 'http://example.com').n_ctx
    end

    it 'tolerates a trailing slash on the base' do
      assert_equal url, described_class.props_url('http://example.com/v1/')
    end
  end

  # The slot count rides the same document as the cap, and is what a host's
  # request throttle sizes itself from.
  describe 'total_slots' do
    it 'reads the top-level total_slots beside the nested n_ctx' do
      stubs.get(url) do
        [200, {}, JSON.generate('total_slots' => 4,
                                'default_generation_settings' => { 'n_ctx' => 16_384 })]
      end
      props = described_class.detect(transport, openai_base: base)

      assert_equal 16_384, props.n_ctx
      assert_equal 4, props.total_slots
    end

    it 'leaves total_slots nil on a server that reports none' do
      stubs.get(url) do
        [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => 8192 })]
      end
      props = described_class.detect(transport, openai_base: base)

      assert_equal 8192, props.n_ctx
      assert_nil props.total_slots
    end

    # The two fields are independent both ways: a document with slots but no
    # usable cap still carries the slot count.
    it 'keeps total_slots when the cap is missing, warning about the cap alone' do
      stubs.get(url) { [200, {}, JSON.generate('total_slots' => 4)] }
      props = described_class.detect(transport, openai_base: base)

      assert_nil props.n_ctx
      assert_equal 4, props.total_slots
      assert_includes buf.string, 'default_generation_settings.n_ctx'
    end

    it 'ignores a non-positive or non-integer total_slots' do
      stubs.get(url) do
        [200, {}, JSON.generate('total_slots' => '4',
                                'default_generation_settings' => { 'n_ctx' => 8192 })]
      end
      assert_nil described_class.detect(transport, openai_base: base).total_slots
    end
  end

  # The object a text-only model reports, measured on llama.cpp b10438 with
  # --no-mmproj-auto (pikuri:D_refuse_unsupported_attachments).
  describe 'modalities' do
    it 'reads the top-level modalities object, symbol-keyed' do
      stubs.get(url) do
        [200, {}, JSON.generate('modalities' => { 'vision' => false, 'video' => false, 'audio' => false },
                                'default_generation_settings' => { 'n_ctx' => 8192 })]
      end
      props = described_class.detect(transport, openai_base: base)

      assert_equal({ vision: false, video: false, audio: false }, props.modalities)
    end

    it 'leaves modalities nil on a server that reports none' do
      stubs.get(url) do
        [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => 8192 })]
      end
      assert_nil described_class.detect(transport, openai_base: base).modalities
    end

    it 'drops a non-Boolean entry rather than guessing what it means' do
      stubs.get(url) do
        [200, {}, JSON.generate('modalities' => { 'vision' => 'no', 'audio' => false },
                                'default_generation_settings' => { 'n_ctx' => 8192 })]
      end
      assert_equal({ audio: false }, described_class.detect(transport, openai_base: base).modalities)
    end
  end

  # The /v1/models shape measured on a llama.cpp b10438 router (2026-11-04):
  # every entry carries architecture.input_modalities, loaded or not.
  describe '.detect_modalities' do
    let(:models_url) { 'http://example.com/v1/models' }

    def listing(*entries)
      stubs.get(models_url) { [200, {}, JSON.generate('object' => 'list', 'data' => entries)] }
    end

    def entry(id, kinds, aliases: [])
      { 'id' => id, 'aliases' => aliases, 'architecture' => { 'input_modalities' => kinds } }
    end

    def detect_modalities(model: 'm')
      described_class.detect_modalities(transport(model: model), openai_base: base)
    end

    it "maps a router's input_modalities onto the /props vocabulary" do
      listing(entry('seer', %w[text image]), entry('blind', %w[text]))

      assert_equal({ vision: true, audio: false }, detect_modalities(model: 'seer'))
      assert_equal({ vision: false, audio: false }, detect_modalities(model: 'blind'))
    end

    it 'finds the model by an alias too' do
      listing(entry('org/Seer-GGUF:Q4_K_M', %w[text image], aliases: ['seer']))

      assert_equal({ vision: true, audio: false }, detect_modalities(model: 'seer'))
    end

    it 'falls back to a bare /props, never the ?model= hop that loads a router model' do
      listing({ 'id' => 'bge-m3.gguf' })
      seen = []
      stubs.get(url) do |env|
        seen << env.params['model']
        [200, {}, JSON.generate('modalities' => { 'vision' => false, 'audio' => false })]
      end

      assert_equal({ vision: false, audio: false }, detect_modalities)
      assert_equal [nil], seen
    end

    it 'answers nil when neither document knows, leaving the first-turn probe to ask' do
      listing(entry('other', %w[text]))
      stubs.get(url) { [200, {}, JSON.generate('role' => 'router')] }

      assert_nil detect_modalities
    end

    it 'answers nil when the server is unreachable' do
      stubs.get(models_url) { raise Faraday::ConnectionFailed, 'refused' }
      stubs.get(url) { raise Faraday::ConnectionFailed, 'refused' }

      assert_nil detect_modalities
      assert_includes buf.string, 'ConnectionFailed'
    end

    it "targets the transport's own server by default" do
      stubs.get('http://llama:9081/v1/models') do
        [200, {}, JSON.generate('data' => [entry('m', %w[text image])])]
      end
      t = Pikuri::Agent::ChatTransport.from_openai_server(server: 'http://llama:9081', model: 'm')

      assert_equal({ vision: true, audio: false }, described_class.detect_modalities(t))
    end

    it 'asks nothing of a non-openai transport' do
      assert_nil described_class.detect_modalities(transport(provider: :anthropic), openai_base: base)
    end
  end

  describe 'probe failure modes' do
    def detect
      described_class.detect(transport, openai_base: base)
    end

    it 'returns Props::NONE and warns on a non-200 response' do
      stubs.get(url) { [404, {}, ''] }
      assert_equal none, detect
      assert_includes buf.string, 'HTTP 404 from'
    end

    it 'returns Props::NONE and warns on Faraday::ConnectionFailed' do
      stubs.get(url) { raise Faraday::ConnectionFailed, 'getaddrinfo: Name does not resolve' }
      assert_equal none, detect
      assert_includes buf.string, 'ConnectionFailed'
    end

    it 'returns Props::NONE and warns on Faraday::TimeoutError' do
      stubs.get(url) { raise Faraday::TimeoutError, 'execution expired' }
      assert_equal none, detect
      assert_includes buf.string, 'TimeoutError'
    end

    it 'returns Props::NONE and warns on a malformed JSON body' do
      stubs.get(url) { [200, { 'content-type' => 'application/json' }, 'not-json'] }
      assert_equal none, detect
      assert_includes buf.string, 'ParserError'
    end

    it 'returns Props::NONE and warns when default_generation_settings.n_ctx is missing' do
      stubs.get(url) { [200, {}, JSON.generate('other' => 1)] }
      assert_equal none, detect
      assert_includes buf.string, 'default_generation_settings.n_ctx'
    end

    it 'returns Props::NONE and warns when n_ctx is not a positive integer' do
      stubs.get(url) do
        [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => 0 })]
      end
      assert_equal none, detect
      assert_includes buf.string, 'default_generation_settings.n_ctx'
    end

    it 'returns Props::NONE and warns when n_ctx is a string rather than an integer' do
      stubs.get(url) do
        [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => '4096' })]
      end
      assert_equal none, detect
      assert_includes buf.string, 'default_generation_settings.n_ctx'
    end
  end

  describe 'llama.cpp router mode' do
    # The router answers a bare /props with role=router and n_ctx 0; the
    # real per-model cap lives at /props?model=<id>. One stub block serves
    # both, branching on the presence of the +model+ query param.
    def router_stub(model_n_ctx:, model_slots: nil, model_modalities: nil)
      stubs.get(url) do |env|
        if env.params['model']
          [200, {}, JSON.generate({ 'total_slots' => model_slots, 'modalities' => model_modalities }.compact.merge(
                                    'default_generation_settings' => { 'n_ctx' => model_n_ctx }
                                  ))]
        else
          [200, {}, JSON.generate('role' => 'router',
                                  'default_generation_settings' => { 'n_ctx' => 0 })]
        end
      end
    end

    it 'follows the router to /props?model= using the transport model id' do
      router_stub(model_n_ctx: 262_144)
      props = described_class.detect(
        transport(model: 'unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M'), openai_base: base
      )
      assert_equal 262_144, props.n_ctx
      assert_equal '', buf.string
    end

    it 'takes the slot count from the router hop, which the bare /props lacks' do
      router_stub(model_n_ctx: 262_144, model_slots: 4)
      props = described_class.detect(transport(model: 'org/Model:Q4_K_M'), openai_base: base)

      assert_equal 4, props.total_slots
    end

    it 'takes the modalities from the router hop, which the bare /props lacks' do
      router_stub(model_n_ctx: 262_144, model_modalities: { 'vision' => true, 'audio' => false })
      props = described_class.detect(transport(model: 'org/Model:Q4_K_M'), openai_base: base)

      assert_equal({ vision: true, audio: false }, props.modalities)
    end

    it 'url-encodes the model id when following the router' do
      seen = []
      stubs.get(url) do |env|
        seen << env.params['model']
        if env.params['model']
          [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => 4096 })]
        else
          [200, {}, JSON.generate('role' => 'router',
                                  'default_generation_settings' => { 'n_ctx' => 0 })]
        end
      end
      props = described_class.detect(transport(model: 'org/Model:Q4_K_M'), openai_base: base)
      assert_equal 4096, props.n_ctx
      # Faraday decodes the param back, proving the id round-tripped intact
      # through CGI.escape rather than being sent raw.
      assert_equal ['org/Model:Q4_K_M'], seen.compact
    end

    it 'does not follow the router when the transport has no model id' do
      router_stub(model_n_ctx: 262_144)
      assert_equal none, described_class.detect(transport(model: nil), openai_base: base)
      assert_includes buf.string, "in #{url} response"
    end

    it 'warns against the router probe url when the second hop also lacks n_ctx' do
      stubs.get(url) do |env|
        if env.params['model']
          [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => 0 })]
        else
          [200, {}, JSON.generate('role' => 'router',
                                  'default_generation_settings' => { 'n_ctx' => 0 })]
        end
      end
      assert_equal none, described_class.detect(transport, openai_base: base)
      assert_includes buf.string, 'router probe'
    end
  end

  # +llama-server --api-key SECRET+ protects /props, so the probe must send the
  # same credential the chat does — else a 401 costs both the cap and the slot
  # count. +openai_key:+ is passed explicitly throughout (nil where the case is
  # "no key at all") so the specs never read global RubyLLM.config.
  describe 'credential' do
    # Records the Authorization header of every hop, answering a usable cap.
    def capturing_stub(seen)
      stubs.get(url) do |env|
        seen << env.request_headers['Authorization']
        [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => 8192 })]
      end
    end

    it "sends the transport's api_key as a bearer token" do
      seen = []
      capturing_stub(seen)
      props = described_class.detect(transport(api_key: 'SECRET'), openai_base: base,
                                     openai_key: nil)

      assert_equal 8192, props.n_ctx
      assert_equal ['Bearer SECRET'], seen
    end

    it 'falls back to the openai_key for a transport riding the global config' do
      seen = []
      capturing_stub(seen)
      described_class.detect(transport, openai_base: base, openai_key: 'GLOBAL')

      assert_equal ['Bearer GLOBAL'], seen
    end

    it "prefers the transport's own key over the global one" do
      seen = []
      capturing_stub(seen)
      described_class.detect(transport(api_key: 'SECRET'), openai_base: base,
                             openai_key: 'GLOBAL')

      assert_equal ['Bearer SECRET'], seen
    end

    it 'sends no Authorization header when there is no key anywhere' do
      seen = []
      capturing_stub(seen)
      described_class.detect(transport, openai_base: base, openai_key: nil)

      assert_equal [nil], seen
    end

    it 'sends no Authorization header for an empty key' do
      seen = []
      capturing_stub(seen)
      described_class.detect(transport(api_key: ''), openai_base: base, openai_key: '')

      assert_equal [nil], seen
    end

    it 'carries the key on the router hop as well as the bare probe' do
      seen = []
      stubs.get(url) do |env|
        seen << env.request_headers['Authorization']
        if env.params['model']
          [200, {}, JSON.generate('default_generation_settings' => { 'n_ctx' => 262_144 })]
        else
          [200, {}, JSON.generate('role' => 'router',
                                  'default_generation_settings' => { 'n_ctx' => 0 })]
        end
      end
      props = described_class.detect(transport(api_key: 'SECRET'), openai_base: base,
                                     openai_key: nil)

      assert_equal 262_144, props.n_ctx
      assert_equal ['Bearer SECRET', 'Bearer SECRET'], seen
    end

    it 'warns that the key was rejected on a 401, without printing it' do
      stubs.get(url) { [401, {}, ''] }
      assert_equal none, described_class.detect(transport(api_key: 'SECRET'), openai_base: base,
                                                openai_key: nil)

      assert_includes buf.string, 'HTTP 401'
      assert_includes buf.string, 'the key sent was rejected'
      refute_includes buf.string, 'SECRET'
    end

    it 'warns that no key was sent on a 401 against a keyless transport' do
      stubs.get(url) { [401, {}, ''] }
      assert_equal none, described_class.detect(transport, openai_base: base, openai_key: nil)

      assert_includes buf.string, 'none was sent'
    end

    it 'leaves an unrelated non-200 warning free of key advice' do
      stubs.get(url) { [404, {}, ''] }
      assert_equal none, described_class.detect(transport, openai_base: base, openai_key: nil)

      assert_includes buf.string, 'HTTP 404 from'
      refute_includes buf.string, 'API key'
    end
  end
end
