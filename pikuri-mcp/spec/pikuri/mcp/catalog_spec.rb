# frozen_string_literal: true

# Integration spec against the in-tree fixture at
# +spec/support/test_mcp_server.rb+, which speaks real MCP over stdio.
RSpec.describe Pikuri::Mcp::Catalog do
  def registry(command = TestServer.command)
    Pikuri::Mcp::Registry.new(entries: [
      Pikuri::Mcp::Registry::StdioEntry.new(id: 'test', command: command)
    ])
  end

  def no_instructions_registry
    registry(TestServer.command('PIKURI_TEST_SKIP_INSTRUCTIONS' => '1'))
  end

  def capture_log
    captured = StringIO.new
    original = Pikuri.log_io
    Pikuri.log_io = captured
    yield
    captured.string
  ensure
    Pikuri.log_io = original
  end

  describe '.probe' do
    it 'records the servers that started, with their tools' do
      catalog = described_class.probe(registry)
      assert_equal ['test'], catalog.ids
      assert catalog.include?('test')
      refute catalog.empty?
      assert_equal %w[counter crash divide echo flaky_crash slow], catalog.fetch('test').tools.map(&:name).sort
    end

    it 'leaves no process behind' do
      # The probe's wrapper is closed in an ensure; a still-open one would be
      # reachable from nowhere, so assert on the wrapper directly.
      closed = []
      original_close = Pikuri::Mcp::ClientWrapper.instance_method(:close)
      Pikuri::Mcp::ClientWrapper.define_method(:close) do
        closed << entry.id
        original_close.bind_call(self)
      end
      described_class.probe(registry)
      assert_equal ['test'], closed
    ensure
      Pikuri::Mcp::ClientWrapper.define_method(:close, original_close)
    end

    it 'logs one INFO audit per server, with the raw schema and the output schema' do
      log = capture_log { described_class.probe(registry) }
      assert_match(/MCP server "test" started/, log)
      assert_match(/Tools \(6\)/, log)
      assert_match(/- echo$/m, log)
      assert_match(/input_schema:/, log)
      assert_match(/output_schema:.*echoed/, log)
    end

    it 'drops a server whose command does not exist, with a warning' do
      bogus = registry(['/nonexistent/binary/path'])
      catalog = nil
      log = capture_log { catalog = described_class.probe(bogus) }
      assert catalog.empty?
      assert_match(/Failed to start MCP server "test"/, log)
    end

    it 'drops an HttpEntry whose endpoint refuses connections, naming the url' do
      bogus = Pikuri::Mcp::Registry.new(entries: [
        Pikuri::Mcp::Registry::HttpEntry.new(id: 'bogus-http', url: 'http://127.0.0.1:1/mcp')
      ])
      catalog = nil
      log = capture_log { catalog = described_class.probe(bogus) }
      assert catalog.empty?
      assert_match(%r{Failed to start MCP server "bogus-http" \(url: http://127\.0\.0\.1:1/mcp\)}, log)
    end

    it 'propagates InjectionDetected rather than dropping the server' do
      verifier = Object.new
      verifier.define_singleton_method(:call) { |**| raise Pikuri::Mcp::Verifier::InjectionDetected, 'flagged' }
      assert_raises(Pikuri::Mcp::Verifier::InjectionDetected) do
        described_class.probe(registry, verifier: verifier)
      end
    end
  end

  describe '.build' do
    it 'returns an empty catalog for an empty registry without building any pass' do
      catalog = described_class.build(Pikuri::Mcp::Registry::EMPTY, transport: nil)
      assert catalog.empty?
      assert_equal '', catalog.system_prompt_snippet
    end

    # Run +block+ with +probe+ stubbed to record its passes instead of spawning.
    def with_recorded_probe
      calls = []
      original = described_class.method(:probe)
      described_class.define_singleton_method(:probe) do |reg, **kw|
        calls << kw
        new(registry: reg)
      end
      yield calls
    ensure
      described_class.define_singleton_method(:probe, original)
    end

    let(:transport) { Pikuri::Agent::ChatTransport.new(model: 'qwen-x') }

    it 'builds a Synthesizer and a Verifier by default' do
      with_recorded_probe do |calls|
        described_class.build(registry, transport: transport)
        assert_kind_of Pikuri::Mcp::Synthesizer, calls.first[:synthesizer]
        assert_kind_of Pikuri::Mcp::Verifier, calls.first[:verifier]
      end
    end

    it 'builds neither pass when both are switched off' do
      with_recorded_probe do |calls|
        described_class.build(registry, transport: transport,
                                        synthesize_descriptions: false, verify_mcp_servers: false)
        assert_nil calls.first[:synthesizer]
        assert_nil calls.first[:verifier]
      end
    end

    it "runs the passes' one-shot agents on the transport, with the host's around_request" do
      agent_kwargs = []
      fake_agent = Object.new
      fake_agent.define_singleton_method(:run_loop) { |**| nil }
      fake_agent.define_singleton_method(:last_assistant_content) { 'A fixture.' }
      fake_agent.define_singleton_method(:close) { nil }
      original_agent_new = Pikuri::Agent.method(:new)
      Pikuri::Agent.define_singleton_method(:new) { |**kw| agent_kwargs << kw; fake_agent }
      original_cache_new = Pikuri::Mcp::Cache.method(:new)
      Pikuri::Mcp::Cache.define_singleton_method(:new) { |**| Pikuri::Mcp::Cache::NULL }
      throttle = ->(_api_base, _cancellable, &blk) { blk.call }

      catalog = described_class.build(no_instructions_registry, transport: transport,
                                                                around_request: throttle,
                                                                verify_mcp_servers: false)

      assert_match(%r{<description>A fixture\.</description>}, catalog.system_prompt_snippet)
      assert_equal 1, agent_kwargs.size
      assert_equal 'qwen-x', agent_kwargs.first[:transport].model
      assert_same throttle, agent_kwargs.first[:around_request]
    ensure
      Pikuri::Agent.define_singleton_method(:new, original_agent_new)
      Pikuri::Mcp::Cache.define_singleton_method(:new, original_cache_new)
    end
  end

  describe '#system_prompt_snippet' do
    it 'lists every server with its description' do
      snippet = described_class.probe(registry).system_prompt_snippet
      assert_match(/<available_mcps>/, snippet)
      assert_match(%r{<id>test</id>}, snippet)
      assert_match(/In-tree fixture used by pikuri specs/, snippet)
    end

    it 'escapes XML in the description' do
      entry = Pikuri::Mcp::Registry::StdioEntry.new(id: 'x', command: ['no-op'])
      catalog = described_class.new(registry: Pikuri::Mcp::Registry.new(entries: [entry]), servers: [
        described_class::Server.new(entry: entry, tools: [], description: 'a <b> & "c"')
      ])
      assert_match(%r{<description>a &lt;b&gt; &amp; &quot;c&quot;</description>}, catalog.system_prompt_snippet)
    end
  end

  describe 'description synthesis' do
    def synth(&thinker) = Pikuri::Mcp::Synthesizer.new(thinker: thinker)

    it 'uses the synthesizer when the server supplies no instructions' do
      catalog = described_class.probe(no_instructions_registry, synthesizer: synth { 'Six demo tools.' })
      assert_match(/Six demo tools\./, catalog.system_prompt_snippet)
    end

    it 'skips the synthesizer when the server supplies instructions' do
      called = false
      described_class.probe(registry, synthesizer: synth { called = true })
      refute called
    end

    it 'falls back to serverInfo.name when the synthesizer fails' do
      catalog = described_class.probe(no_instructions_registry, synthesizer: synth { raise 'blip' })
      assert_equal 'pikuri-test-mcp', catalog.fetch('test').description
    end

    it 'propagates Cancelled, aborting the build' do
      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        described_class.probe(no_instructions_registry,
                              synthesizer: synth { raise Pikuri::Agent::Control::Cancellable::Cancelled })
      end
    end
  end
end
