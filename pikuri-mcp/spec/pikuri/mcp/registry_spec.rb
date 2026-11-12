# frozen_string_literal: true

RSpec.describe Pikuri::Mcp::Registry do
  StdioEntry = Pikuri::Mcp::Registry::StdioEntry
  HttpEntry  = Pikuri::Mcp::Registry::HttpEntry

  describe Pikuri::Mcp::Registry::EMPTY do
    it 'is the canonical empty singleton' do
      assert_kind_of Pikuri::Mcp::Registry, described_class
      assert described_class.empty?
      assert_equal [], described_class.entries
      assert_equal [], described_class.ids
      assert_nil described_class.get('anything')
    end

    it 'is frozen' do
      assert described_class.frozen?
    end
  end

  describe Pikuri::Mcp::Registry::StdioEntry do
    it 'is a Data value class with id and command' do
      e = StdioEntry.new(id: 'maven', command: ['npx', 'mcp-maven'])
      assert_equal 'maven', e.id
      assert_equal ['npx', 'mcp-maven'], e.command
    end

    it 'carries an env hash for auth and other variables' do
      e = StdioEntry.new(id: 'gh', command: ['gh-mcp'], env: { 'GITHUB_TOKEN' => 'abc' })
      assert_equal({ 'GITHUB_TOKEN' => 'abc' }, e.env)
    end

    it 'defaults env to an empty hash' do
      e = StdioEntry.new(id: 'maven', command: ['npx', 'mcp-maven'])
      assert_equal({}, e.env)
    end

    it 'freezes the env hash' do
      e = StdioEntry.new(id: 'gh', command: ['gh-mcp'], env: { 'X' => 'y' })
      assert e.env.frozen?
    end

    it 'compares by value' do
      e1 = StdioEntry.new(id: 'a', command: ['x'])
      e2 = StdioEntry.new(id: 'a', command: ['x'])
      e3 = StdioEntry.new(id: 'b', command: ['x'])
      assert_equal e1, e2
      refute_equal e1, e3
    end

    it 'distinguishes by env' do
      e1 = StdioEntry.new(id: 'a', command: ['x'], env: { 'K' => 'v' })
      e2 = StdioEntry.new(id: 'a', command: ['x'], env: { 'K' => 'other' })
      refute_equal e1, e2
    end
  end

  describe Pikuri::Mcp::Registry::HttpEntry do
    it 'is a Data value class with id, url, and headers' do
      e = HttpEntry.new(id: 'hub', url: 'https://mcp.example.com', headers: { 'Authorization' => 'Bearer x' })
      assert_equal 'hub', e.id
      assert_equal 'https://mcp.example.com', e.url
      assert_equal({ 'Authorization' => 'Bearer x' }, e.headers)
    end

    it 'defaults headers to an empty hash' do
      e = HttpEntry.new(id: 'hub', url: 'https://mcp.example.com')
      assert_equal({}, e.headers)
    end

    it 'freezes the headers hash' do
      e = HttpEntry.new(id: 'hub', url: 'https://mcp.example.com', headers: { 'X' => 'y' })
      assert e.headers.frozen?
    end

    it 'compares by value' do
      e1 = HttpEntry.new(id: 'a', url: 'https://x', headers: { 'k' => 'v' })
      e2 = HttpEntry.new(id: 'a', url: 'https://x', headers: { 'k' => 'v' })
      e3 = HttpEntry.new(id: 'a', url: 'https://x', headers: { 'k' => 'other' })
      assert_equal e1, e2
      refute_equal e1, e3
    end
  end

  describe '#initialize' do
    it 'defaults to no entries' do
      r = Pikuri::Mcp::Registry.new
      assert r.empty?
      assert_equal [], r.ids
    end

    it 'preserves declaration order across mixed entry types' do
      r = Pikuri::Mcp::Registry.new(entries: [
        StdioEntry.new(id: 'b', command: ['x']),
        HttpEntry.new(id: 'a',  url: 'https://x'),
        StdioEntry.new(id: 'c', command: ['z'])
      ])
      assert_equal %w[b a c], r.ids
    end

    it 'rejects duplicate ids loudly, regardless of entry type' do
      err = assert_raises(ArgumentError) do
        Pikuri::Mcp::Registry.new(entries: [
          StdioEntry.new(id: 'x', command: ['a']),
          HttpEntry.new(id: 'x',  url: 'https://x')
        ])
      end
      assert_match(/Duplicate MCP id "x"/, err.message)
    end

    it 'freezes itself and its entries array after construction' do
      r = Pikuri::Mcp::Registry.new(entries: [StdioEntry.new(id: 'a', command: ['x'])])
      assert r.frozen?
      assert r.entries.frozen?
    end

    it 'does not mutate the caller-supplied entries array' do
      caller_entries = [StdioEntry.new(id: 'a', command: ['x'])]
      Pikuri::Mcp::Registry.new(entries: caller_entries)
      caller_entries << StdioEntry.new(id: 'b', command: ['y'])
      # caller_entries is still mutable; the registry's own copy is frozen
      assert_equal 2, caller_entries.size
    end
  end

  describe '#get' do
    let(:registry) do
      Pikuri::Mcp::Registry.new(entries: [
        StdioEntry.new(id: 'gmail',   command: ['gmail-mcp']),
        HttpEntry.new(id: 'hubspot',  url: 'https://mcp.example.com')
      ])
    end

    it 'returns the entry with a matching id (stdio)' do
      assert_equal 'gmail', registry.get('gmail').id
      assert_equal ['gmail-mcp'], registry.get('gmail').command
    end

    it 'returns the entry with a matching id (http)' do
      assert_equal 'hubspot', registry.get('hubspot').id
      assert_equal 'https://mcp.example.com', registry.get('hubspot').url
    end

    it 'returns nil for an unknown id' do
      assert_nil registry.get('unknown')
    end
  end
end
