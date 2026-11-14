# frozen_string_literal: true

RSpec.describe Pikuri::Mcp::Extension do
  let(:entry) { Pikuri::Mcp::Registry::StdioEntry.new(id: 'test', command: ['no-op']) }
  let(:registry) { Pikuri::Mcp::Registry.new(entries: [entry]) }
  let(:mcp_tool) { MCP::Client::Tool.new(name: 'echo', description: 'Echoes.', input_schema: { type: 'object' }) }

  # A catalog built by hand, so nothing spawns: these specs never call a tool.
  let(:catalog) do
    Pikuri::Mcp::Catalog.new(registry: registry, servers: [
      Pikuri::Mcp::Catalog::Server.new(entry: entry, tools: [mcp_tool], description: 'A fixture.')
    ])
  end

  let(:configurator) do
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base', id: '', streaming: false, cancellable: nil, interloper: nil
    )
  end

  # Stand-in ExtensionContext: records +add_raw_tool+, and its agent exports
  # +history+.
  def fake_ctx(history = Pikuri::Agent::History.new)
    ctx = Object.new
    added = []
    agent = Object.new
    agent.define_singleton_method(:export_history) { history }
    ctx.define_singleton_method(:agent) { agent }
    ctx.define_singleton_method(:add_raw_tool) { |t| added << t }
    ctx.define_singleton_method(:added_names) { added.map(&:name) }
    ctx
  end

  def connect_call(id, call_id: 'call_1')
    Pikuri::Agent::History::Message.new(
      id: Pikuri::Agent::History.mint_id, role: 'assistant', content: '',
      tool_calls: [Pikuri::Agent::History::ToolCall.new(id: call_id, name: 'mcp_connect', arguments: { 'id' => id })]
    )
  end

  def bound(ext, ctx)
    ext.configure(configurator)
    ext.bind(ctx)
    ctx
  end

  it 'is an Agent::Extension by composition' do
    assert_kind_of Pikuri::Agent::Extension, described_class.new(catalog: catalog)
  end

  describe 'on an empty catalog' do
    let(:empty) { Pikuri::Mcp::Catalog.new(registry: Pikuri::Mcp::Registry::EMPTY) }

    it 'adds no tool, no prompt, no close handler and no trifecta legs' do
      ext = described_class.new(catalog: empty)
      ctx = bound(ext, fake_ctx)
      assert_equal [], ctx.added_names
      assert_equal [], ext.system_prompt_snippets
      assert_equal [], configurator.on_close_handlers
      assert_nil ext.trifecta_contribution([])
    end
  end

  describe '#configure' do
    it 'creates this agent its own Connections and closes them on close' do
      ext = described_class.new(catalog: catalog)
      ext.configure(configurator)
      refute_nil ext.connections
      closed = false
      ext.connections.define_singleton_method(:close) { closed = true }
      configurator.on_close_handlers.each(&:call)
      assert closed
    end
  end

  it "puts the catalog's <available_mcps> block in the system prompt" do
    snippets = described_class.new(catalog: catalog).system_prompt_snippets
    assert_equal [catalog.system_prompt_snippet], snippets
    assert_match(%r{<id>test</id>}, snippets.first)
  end

  describe '#bind' do
    it 'registers only mcp_connect on a fresh conversation' do
      assert_equal ['mcp_connect'], bound(described_class.new(catalog: catalog), fake_ctx).added_names
    end

    it "re-registers the tools of every server a restored conversation connected" do
      ext = described_class.new(catalog: catalog)
      ctx = bound(ext, fake_ctx(Pikuri::Agent::History.new(messages: [connect_call('test')])))
      assert_equal %w[mcp_connect test__echo], ctx.added_names
      assert ext.connections.registered?('test')
    end

    it 'registers a server once however often the history connected it' do
      history = Pikuri::Agent::History.new(messages: [connect_call('test', call_id: 'a'), connect_call('test', call_id: 'b')])
      ctx = bound(described_class.new(catalog: catalog), fake_ctx(history))
      assert_equal %w[mcp_connect test__echo], ctx.added_names
    end

    it 'skips a connected id that is no longer in the catalog' do
      ctx = bound(described_class.new(catalog: catalog), fake_ctx(Pikuri::Agent::History.new(messages: [connect_call('gone')])))
      assert_equal ['mcp_connect'], ctx.added_names
    end
  end
end
