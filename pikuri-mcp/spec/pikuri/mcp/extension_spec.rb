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

  # Stand-in Configurator: the three calls the extension makes, recorded.
  def fake_configurator(history = nil)
    c = Object.new
    added = []
    closers = []
    c.define_singleton_method(:history) { history }
    c.define_singleton_method(:add_raw_tool) { |t| added << t }
    c.define_singleton_method(:on_close) { |&blk| closers << blk }
    c.define_singleton_method(:added_names) { added.map(&:name) }
    c.define_singleton_method(:closers) { closers }
    c
  end

  def connect_call(id, call_id: 'call_1')
    Pikuri::Agent::History::Message.new(
      id: Pikuri::Agent::History.mint_id, role: 'assistant', content: '',
      tool_calls: [Pikuri::Agent::History::ToolCall.new(id: call_id, name: 'mcp_connect', arguments: { 'id' => id })]
    )
  end

  def configured(ext, c)
    ext.configure(c)
    c
  end

  it 'is an Agent::Extension by composition' do
    assert_kind_of Pikuri::Agent::Extension, described_class.new(catalog: catalog)
  end

  describe 'on an empty catalog' do
    let(:empty) { Pikuri::Mcp::Catalog.new(registry: Pikuri::Mcp::Registry::EMPTY) }

    it 'adds no tool, no prompt, no close handler and no trifecta legs' do
      ext = described_class.new(catalog: empty)
      c = configured(ext, fake_configurator)
      assert_equal [], c.added_names
      assert_equal [], ext.system_prompt_snippets
      assert_equal [], c.closers
      assert_nil ext.trifecta_contribution([])
    end
  end

  describe '#configure' do
    it 'creates this agent its own Connections and closes them on close' do
      ext = described_class.new(catalog: catalog)
      c = configured(ext, fake_configurator)
      refute_nil ext.connections
      closed = false
      ext.connections.define_singleton_method(:close) { closed = true }
      c.closers.each(&:call)
      assert closed
    end
  end

  it "puts the catalog's <available_mcps> block in the system prompt" do
    snippets = described_class.new(catalog: catalog).system_prompt_snippets
    assert_equal [catalog.system_prompt_snippet], snippets
    assert_match(%r{<id>test</id>}, snippets.first)
  end

  describe 'the tools it registers' do
    it 'registers only mcp_connect on a fresh conversation' do
      assert_equal ['mcp_connect'], configured(described_class.new(catalog: catalog), fake_configurator).added_names
    end

    it "re-registers the tools of every server a restored conversation connected" do
      ext = described_class.new(catalog: catalog)
      c = configured(ext, fake_configurator(Pikuri::Agent::History.new(messages: [connect_call('test')])))
      assert_equal %w[mcp_connect test__echo], c.added_names
      assert ext.connections.registered?('test')
    end

    it 'registers a server once however often the history connected it' do
      history = Pikuri::Agent::History.new(messages: [connect_call('test', call_id: 'a'), connect_call('test', call_id: 'b')])
      c = configured(described_class.new(catalog: catalog), fake_configurator(history))
      assert_equal %w[mcp_connect test__echo], c.added_names
    end

    it 'skips a connected id that is no longer in the catalog' do
      c = configured(described_class.new(catalog: catalog),
                     fake_configurator(Pikuri::Agent::History.new(messages: [connect_call('gone')])))
      assert_equal ['mcp_connect'], c.added_names
    end
  end
end
