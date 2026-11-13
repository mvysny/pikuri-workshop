# frozen_string_literal: true

# Integration spec against the in-tree fixture at
# +spec/support/test_mcp_server.rb+, through the shared +TestServer.catalog+.
RSpec.describe Pikuri::Mcp::Connections do
  # Stand-in ExtensionContext recording what +add_raw_tool+ received.
  def fake_ctx
    ctx = Object.new
    added = []
    ctx.define_singleton_method(:add_raw_tool) { |t| added << t }
    ctx.define_singleton_method(:added_tools) { added }
    ctx
  end

  # Count ClientWrapper spawns for the duration of the block.
  def count_spawns
    spawns = 0
    original = Pikuri::Mcp::ClientWrapper.method(:new)
    Pikuri::Mcp::ClientWrapper.define_singleton_method(:new) do |*args, **kw|
      spawns += 1
      original.call(*args, **kw)
    end
    yield
    spawns
  ensure
    Pikuri::Mcp::ClientWrapper.define_singleton_method(:new, original)
  end

  def tool(ctx, name) = ctx.added_tools.find { |t| t.name == name }.new

  before { @connections = Pikuri::Mcp::Connections.new(TestServer.catalog) }
  after { @connections.close }

  describe '#register_tools' do
    it 'adds one namespaced RubyLLM::Tool per MCP tool, spawning nothing' do
      ctx = fake_ctx
      spawns = count_spawns { assert_equal 6, @connections.register_tools('test', ctx) }
      assert_equal 0, spawns
      assert(ctx.added_tools.all? { |t| t < RubyLLM::Tool })
      assert_includes ctx.added_tools.map(&:name), 'test__echo'
      assert @connections.registered?('test')
    end

    it 'prefixes the description with the provenance marker, verbatim after it' do
      ctx = fake_ctx
      @connections.register_tools('test', ctx)
      assert_equal %([From MCP server "test"]\n\nEchoes the given message back to the caller.),
                   ctx.added_tools.find { |t| t.name == 'test__echo' }.description
    end

    it 'carries parameter descriptions to the wire schema and strips $schema' do
      ctx = fake_ctx
      @connections.register_tools('test', ctx)
      schema = tool(ctx, 'test__divide').parameters_schema
      assert_equal 'The denominator. Must be non-zero.', schema.dig('properties', 'b', 'description')
      refute schema.key?('$schema')
    end

    it 'refuses a second registration of the same server' do
      @connections.register_tools('test', fake_ctx)
      assert_raises(ArgumentError) { @connections.register_tools('test', fake_ctx) }
    end

    it 'raises KeyError for an id outside the catalog' do
      assert_raises(KeyError) { @connections.register_tools('nope', fake_ctx) }
    end
  end

  describe 'a synthesized tool' do
    before do
      @ctx = fake_ctx
      @connections.register_tools('test', @ctx)
    end

    it 'spawns the server on its first call and reuses it after' do
      spawns = count_spawns do
        assert_equal 'hello pikuri', tool(@ctx, 'test__echo').execute(message: 'hello pikuri')
        assert_equal '1', tool(@ctx, 'test__counter').execute
        assert_equal '2', tool(@ctx, 'test__counter').execute
      end
      assert_equal 1, spawns
    end

    it 'turns an MCP-side tool error into an Error: observation' do
      result = tool(@ctx, 'test__divide').execute(a: 10, b: 0)
      assert_match(/\AError: division by zero/, result)
    end

    it 'turns server death into an Error: observation' do
      assert_match(/\AError: MCP server "test" call failed/, tool(@ctx, 'test__crash').execute)
    end

    it 'answers an Error: observation after close, spawning nothing' do
      @connections.close
      spawns = count_spawns do
        assert_match(/\AError: .*already closed/, tool(@ctx, 'test__echo').execute(message: 'x'))
      end
      assert_equal 0, spawns
    end
  end

  it 'gives two Connections on one catalog two processes' do
    other = described_class.new(TestServer.catalog)
    ctx_a = fake_ctx
    ctx_b = fake_ctx
    @connections.register_tools('test', ctx_a)
    other.register_tools('test', ctx_b)

    tool(ctx_a, 'test__counter').execute
    assert_equal '2', tool(ctx_a, 'test__counter').execute
    assert_equal '1', tool(ctx_b, 'test__counter').execute, 'B must not see the state A built up'
  ensure
    other&.close
  end

  describe 'the rug-pull check' do
    # A catalog that verified one tool fewer than the fixture lists, as if the
    # server had grown a tool since it was verified.
    let(:stale_catalog) do
      server = TestServer.catalog.fetch('test')
      Pikuri::Mcp::Catalog.new(registry: TestServer.catalog.registry, servers: [
        server.with(tools: server.tools.reject { |t| t.name == 'counter' })
      ])
    end

    it 'refuses a spawned server whose tools differ, and does not respawn it' do
      connections = described_class.new(stale_catalog)
      ctx = fake_ctx
      connections.register_tools('test', ctx)
      results = nil
      spawns = count_spawns do
        results = 2.times.map { tool(ctx, 'test__echo').execute(message: 'x') }
      end
      results.each { |r| assert_match(/\AError: .*SurfaceChanged.*added \["counter"\]/, r) }
      assert_equal 1, spawns
    ensure
      connections&.close
    end
  end

  describe Pikuri::Mcp::Connect do
    def connect_tool(ctx) = Pikuri::Mcp::Connect.new(catalog: TestServer.catalog, connections: @connections, ctx: ctx)

    it 'registers the tools and reports the count' do
      ctx = fake_ctx
      tool = connect_tool(ctx)
      result = tool.run('id' => 'test')
      assert_match(/Connected to MCP server 'test'\. Added 6 tools/, result.to_s)
      assert_equal 'Connected, 6 tools', result.summary
      assert_equal 'test', tool.describe_call('id' => 'test')
      assert_equal 6, ctx.added_tools.size
    end

    it 'answers an Error: for an unknown id, listing the known ones' do
      result = connect_tool(fake_ctx).run('id' => 'unknown')
      assert_match(/\AError: unknown MCP server id "unknown"\. Available: test\./, result.content)
    end

    it 'answers an Error: on a repeat, registering nothing more' do
      ctx = fake_ctx
      tool = connect_tool(ctx)
      tool.run('id' => 'test')
      assert_match(/\AError: server 'test' is already connected/, tool.run('id' => 'test').content)
      assert_equal 6, ctx.added_tools.size
    end
  end
end
