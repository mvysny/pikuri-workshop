# frozen_string_literal: true

RSpec.describe Pikuri::Mcp::Synthesizer do
  ToolStub = Struct.new(:name, :description, :input_schema) unless defined?(ToolStub)
  ClientStub = Struct.new(:server_info)

  def entry
    Pikuri::Mcp::Registry::StdioEntry.new(id: 'probe', command: ['noop'])
  end

  def client
    ClientStub.new({ 'serverInfo' => { 'name' => 'srv', 'version' => '1.0' } })
  end

  def tools
    [
      ToolStub.new('echo', 'Echoes back', { 'type' => 'object' }),
      ToolStub.new('divide', 'Divides a / b', { 'type' => 'object' })
    ]
  end

  describe '#initialize' do
    it 'requires exactly one of transport: or thinker:' do
      assert_raises(ArgumentError) { described_class.new }
      assert_raises(ArgumentError) do
        described_class.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                            thinker: ->(_p) { 'x' })
      end
    end

    it 'rejects cancellable: on the thinker: path (it only feeds the built-in Thinker)' do
      assert_raises(ArgumentError) do
        described_class.new(thinker: ->(_p) { 'x' },
                            cancellable: Pikuri::Agent::Control::Cancellable.new)
      end
    end

    it 'builds the production on-disk cache from the transport when no cache: is given' do
      synth = described_class.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'))
      cache = synth.instance_variable_get(:@cache)
      assert_kind_of Pikuri::Mcp::Cache, cache
    end

    it 'defaults to Cache::NULL on the thinker: path (tests stay off the disk)' do
      synth = described_class.new(thinker: ->(_p) { 'x' })
      assert_same Pikuri::Mcp::Cache::NULL, synth.instance_variable_get(:@cache)
    end
  end

  describe '#call' do
    it 'invokes the thinker with a prompt that contains the server id and every tool name + description' do
      received = nil
      synthesizer = described_class.new(thinker: ->(p) { received = p; 'ok' })
      synthesizer.call(entry: entry, client: client, tools: tools)
      assert_match(/Server id: probe/, received)
      assert_match(/- echo: Echoes back/, received)
      assert_match(/- divide: Divides a \/ b/, received)
    end

    it 'returns the thinker output cleaned (strip + collapse internal whitespace)' do
      synthesizer = described_class.new(thinker: ->(_p) { "  multi\nline\n  output  " })
      assert_equal 'multi line output', synthesizer.call(entry: entry, client: client, tools: tools)
    end

    it 'returns nil when the thinker output is blank' do
      synthesizer = described_class.new(thinker: ->(_p) { "  \n  " })
      assert_nil synthesizer.call(entry: entry, client: client, tools: tools)
    end

    it 'returns nil and logs a WARN when the thinker raises StandardError (fail-soft)' do
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      synthesizer = described_class.new(thinker: ->(_p) { raise 'boom' })
      assert_nil synthesizer.call(entry: entry, client: client, tools: tools)
      assert_match(/MCP description synthesis failed for "probe"/, captured.string)
      assert_match(/boom/, captured.string)
    ensure
      Pikuri.log_io = original if original
    end

    it 'propagates Cancellable::Cancelled without logging it as a synthesis failure' do
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      synthesizer = described_class.new(
        thinker: ->(_p) { raise Pikuri::Agent::Control::Cancellable::Cancelled }
      )
      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        synthesizer.call(entry: entry, client: client, tools: tools)
      end
      refute_match(/synthesis failed/, captured.string)
    ensure
      Pikuri.log_io = original if original
    end

    it 'logs an INFO heads-up before invoking the thinker (so the user knows to wait)' do
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      synthesizer = described_class.new(thinker: ->(_p) { 'done' })
      synthesizer.call(entry: entry, client: client, tools: tools)
      assert_match(/Synthesizing description for MCP server "probe", please wait/, captured.string)
    ensure
      Pikuri.log_io = original if original
    end

    it 'does NOT log the heads-up on a cache hit (synthesis is skipped, so is the message)' do
      Dir.mktmpdir('pikuri-synth-hint') do |dir|
        # Prime the cache with one synthesis pass.
        primer = described_class.new(
          thinker: ->(_p) { 'primed' },
          cache: Pikuri::Mcp::Cache.new(model_id: 'm', prompt_version: described_class::PROMPT_VERSION, dir: dir)
        )
        primer.call(entry: entry, client: client, tools: tools)

        # Now exercise a hit, capturing only the second call's logs.
        captured = StringIO.new
        original = Pikuri.log_io
        Pikuri.log_io = captured
        hit_synth = described_class.new(
          thinker: ->(_p) { raise 'should not be called' },
          cache: Pikuri::Mcp::Cache.new(model_id: 'm', prompt_version: described_class::PROMPT_VERSION, dir: dir)
        )
        result = hit_synth.call(entry: entry, client: client, tools: tools)
        assert_equal 'primed', result
        refute_match(/Synthesizing description/, captured.string)
      ensure
        Pikuri.log_io = original if original
      end
    end

    it 'routes through the cache: hit short-circuits the thinker' do
      Dir.mktmpdir('pikuri-synth-cache') do |dir|
        cache = Pikuri::Mcp::Cache.new(model_id: 'm', prompt_version: described_class::PROMPT_VERSION, dir: dir)
        calls = 0
        first = described_class.new(thinker: ->(_p) { calls += 1; 'cached one' }, cache: cache)
        assert_equal 'cached one', first.call(entry: entry, client: client, tools: tools)
        assert_equal 1, calls

        second_cache = Pikuri::Mcp::Cache.new(model_id: 'm', prompt_version: described_class::PROMPT_VERSION, dir: dir)
        second = described_class.new(thinker: ->(_p) { calls += 1; 'should not run' }, cache: second_cache)
        assert_equal 'cached one', second.call(entry: entry, client: client, tools: tools)
        assert_equal 1, calls
      end
    end
  end

  describe Pikuri::Mcp::Synthesizer::PROMPT_VERSION do
    it 'is an Integer (Cache#key_for hashes it as part of the fingerprint)' do
      assert_kind_of Integer, described_class
    end
  end
end
