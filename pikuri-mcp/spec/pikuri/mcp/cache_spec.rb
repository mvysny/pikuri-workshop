# frozen_string_literal: true

require 'tmpdir'
require 'json'

RSpec.describe Pikuri::Mcp::Cache do
  # Tiny duck-types for the (entry, client, tools) triple the cache
  # takes. Real Mcp::Registry::Stdio/Http entries work too, but the
  # cache only reads +entry.class+ + a couple of accessors, so a stand-in
  # keeps the spec focused on key-calculation semantics.
  Entry = Struct.new(:id, :command)
  HttpEntryStub = Struct.new(:id, :url)
  ToolStub = Struct.new(:name, :description, :input_schema)
  let(:client_class) do
    Struct.new(:server_info)
  end

  def stdio_entry
    # Use the real Registry::StdioEntry so Cache#transport_descriptor
    # dispatches correctly.
    Pikuri::Mcp::Registry::StdioEntry.new(id: 'x', command: ['foo', '--bar'])
  end

  def http_entry
    Pikuri::Mcp::Registry::HttpEntry.new(id: 'h', url: 'https://example.com/mcp')
  end

  def client(name: 'srv', version: '1.0')
    client_class.new({ 'serverInfo' => { 'name' => name, 'version' => version } })
  end

  def tools(*items)
    items.map { |h| ToolStub.new(h.fetch(:name), h.fetch(:description), h.fetch(:input_schema, {})) }
  end

  let(:base_tools) do
    tools(
      { name: 'echo',   description: 'Echoes input',  input_schema: { 'type' => 'object', 'properties' => { 'msg' => { 'type' => 'string' } } } },
      { name: 'divide', description: 'Divides a / b', input_schema: { 'type' => 'object', 'properties' => { 'a' => { 'type' => 'number' }, 'b' => { 'type' => 'number' } } } }
    )
  end

  describe '#key_for' do
    around do |ex|
      Dir.mktmpdir('pikuri-mcp-cache-spec') { |d| @dir = d; ex.run }
    end

    let(:cache) { Pikuri::Mcp::Cache.new(model_id: 'm', prompt_version: 1, dir: @dir) }

    it 'returns a stable canonical JSON string' do
      k1 = cache.key_for(stdio_entry, client, base_tools)
      k2 = cache.key_for(stdio_entry, client, base_tools)
      assert_equal k1, k2
      # Parses as JSON
      parsed = JSON.parse(k1)
      assert_equal 'm', parsed['model_id']
      assert_equal 1, parsed['prompt_version']
    end

    it 'is insensitive to hash-key insertion order in the tool input_schema' do
      schema_a = { 'type' => 'object', 'properties' => { 'a' => { 'type' => 'number' }, 'b' => { 'type' => 'number' } } }
      schema_b = { 'properties' => { 'b' => { 'type' => 'number' }, 'a' => { 'type' => 'number' } }, 'type' => 'object' }
      a = tools({ name: 't', description: 'd', input_schema: schema_a })
      b = tools({ name: 't', description: 'd', input_schema: schema_b })
      assert_equal cache.key_for(stdio_entry, client, a), cache.key_for(stdio_entry, client, b)
    end

    it 'is sensitive to the model id' do
      other = Pikuri::Mcp::Cache.new(model_id: 'm2', prompt_version: 1, dir: @dir)
      refute_equal cache.key_for(stdio_entry, client, base_tools),
                   other.key_for(stdio_entry, client, base_tools)
    end

    it 'is sensitive to the prompt version' do
      other = Pikuri::Mcp::Cache.new(model_id: 'm', prompt_version: 2, dir: @dir)
      refute_equal cache.key_for(stdio_entry, client, base_tools),
                   other.key_for(stdio_entry, client, base_tools)
    end

    it 'is sensitive to the transport descriptor (stdio command)' do
      other_entry = Pikuri::Mcp::Registry::StdioEntry.new(id: 'x', command: ['foo', '--baz'])
      refute_equal cache.key_for(stdio_entry, client, base_tools),
                   cache.key_for(other_entry, client, base_tools)
    end

    it 'is sensitive to the transport descriptor (http url)' do
      other_entry = Pikuri::Mcp::Registry::HttpEntry.new(id: 'h', url: 'https://example.com/mcp-v2')
      refute_equal cache.key_for(http_entry, client, base_tools),
                   cache.key_for(other_entry, client, base_tools)
    end

    it 'is INsensitive to the entry id (a rename does not invalidate)' do
      renamed = Pikuri::Mcp::Registry::StdioEntry.new(id: 'renamed', command: ['foo', '--bar'])
      assert_equal cache.key_for(stdio_entry, client, base_tools),
                   cache.key_for(renamed, client, base_tools)
    end

    it 'is sensitive to the server name (rogue server impersonates a different name)' do
      refute_equal cache.key_for(stdio_entry, client(name: 'A'), base_tools),
                   cache.key_for(stdio_entry, client(name: 'B'), base_tools)
    end

    it 'is sensitive to the server version' do
      refute_equal cache.key_for(stdio_entry, client(version: '1.0'), base_tools),
                   cache.key_for(stdio_entry, client(version: '2.0'), base_tools)
    end

    it 'is sensitive to any tool name change' do
      mutated = tools({ name: 'echo_v2', description: 'Echoes input', input_schema: {} })
      refute_equal cache.key_for(stdio_entry, client, base_tools),
                   cache.key_for(stdio_entry, client, mutated)
    end

    it 'is sensitive to any tool description change (so a rogue server cannot silently rewrite a description without resynthesis)' do
      mutated = tools({ name: 'echo', description: 'Now does something else', input_schema: {} })
      refute_equal cache.key_for(stdio_entry, client, base_tools),
                   cache.key_for(stdio_entry, client, mutated)
    end

    it 'is sensitive to any tool input_schema change (nested property description)' do
      with_desc = tools({ name: 'echo', description: 'd', input_schema: { 'properties' => { 'msg' => { 'type' => 'string', 'description' => 'original' } } } })
      mutated   = tools({ name: 'echo', description: 'd', input_schema: { 'properties' => { 'msg' => { 'type' => 'string', 'description' => 'changed' } } } })
      refute_equal cache.key_for(stdio_entry, client, with_desc),
                   cache.key_for(stdio_entry, client, mutated)
    end

    it 'is sensitive to tool order (adding a tool changes the key)' do
      extra = base_tools + tools({ name: 'new_tool', description: 'd', input_schema: {} })
      refute_equal cache.key_for(stdio_entry, client, base_tools),
                   cache.key_for(stdio_entry, client, extra)
    end
  end

  describe '#fetch' do
    around do |ex|
      Dir.mktmpdir('pikuri-mcp-cache-spec') { |d| @dir = d; ex.run }
    end

    let(:cache) { Pikuri::Mcp::Cache.new(model_id: 'm', prompt_version: 1, dir: @dir) }

    it 'yields and persists on first call, returns cached value on second' do
      calls = 0
      first = cache.fetch(entry: stdio_entry, client: client, tools: base_tools) { calls += 1; 'description-1' }
      second = cache.fetch(entry: stdio_entry, client: client, tools: base_tools) { calls += 1; 'description-2' }
      assert_equal 'description-1', first
      assert_equal 'description-1', second # cached!
      assert_equal 1, calls
    end

    it 'misses when any keyed input changes — recomputes' do
      cache.fetch(entry: stdio_entry, client: client, tools: base_tools) { 'first' }
      # Change a tool description; should be a miss.
      changed = tools({ name: 'echo', description: 'CHANGED', input_schema: {} })
      result = cache.fetch(entry: stdio_entry, client: client, tools: changed) { 'second' }
      assert_equal 'second', result
    end

    it 'survives across Cache instance recreations (state is on disk, not in memory)' do
      cache.fetch(entry: stdio_entry, client: client, tools: base_tools) { 'persisted' }
      other = Pikuri::Mcp::Cache.new(model_id: 'm', prompt_version: 1, dir: @dir)
      result = other.fetch(entry: stdio_entry, client: client, tools: base_tools) { 'should-not-be-called' }
      assert_equal 'persisted', result
    end
  end

  describe Pikuri::Mcp::Cache::NULL do
    it 'always yields and never persists' do
      calls = 0
      r1 = described_class.fetch(entry: :e, client: :c, tools: []) { calls += 1; 'a' }
      r2 = described_class.fetch(entry: :e, client: :c, tools: []) { calls += 1; 'b' }
      assert_equal 'a', r1
      assert_equal 'b', r2
      assert_equal 2, calls
    end
  end
end
