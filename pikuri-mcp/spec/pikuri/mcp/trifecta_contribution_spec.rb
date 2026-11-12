# frozen_string_literal: true

RSpec.describe 'Mcp trifecta contribution' do
  def stdio(id, **flags) = Pikuri::Mcp::Registry::StdioEntry.new(id: id, command: %w[true], **flags)

  describe 'Registry#private?' do
    it 'is false when nothing declares it' do
      refute Pikuri::Mcp::Registry.new(entries: [stdio('openlibrary')]).private?
    end

    it 'is true when any single entry declares it' do
      registry = Pikuri::Mcp::Registry.new(entries: [stdio('openlibrary'), stdio('notion', private: true)])
      assert registry.private?
    end

    it 'unions over *registered* servers, not connected ones' do
      # mcp_connect can activate any registered entry at will, so registration
      # is the capability boundary — one private server makes the whole surface
      # private whether or not the agent ever connects to it.
      assert Pikuri::Mcp::Registry.new(entries: [stdio('mail', private: true)]).private?
    end

    it 'is false on the empty registry' do
      refute Pikuri::Mcp::Registry::EMPTY.private?
    end

    it 'defaults the flag off on both entry kinds' do
      refute Pikuri::Mcp::Registry::StdioEntry.new(id: 'a', command: %w[true]).private
      refute Pikuri::Mcp::Registry::HttpEntry.new(id: 'b', url: 'https://example.com').private
    end
  end

  describe 'Extension#trifecta_contribution' do
    def contribution_for(*entries)
      Pikuri::Mcp::Extension.new(registry: Pikuri::Mcp::Registry.new(entries: entries))
                            .trifecta_contribution([])
    end

    it 'contributes nothing when no servers are registered' do
      assert_nil Pikuri::Mcp::Extension.new(registry: Pikuri::Mcp::Registry::EMPTY).trifecta_contribution([])
    end

    it 'carries hard untrusted and autonomous egress unconditionally' do
      # A server's reachable set is unknown by construction: the tool list
      # arrives at runtime from a server you did not write.
      legs = contribution_for(stdio('openlibrary')).legs
      assert_equal :hard, legs.untrusted
      assert_equal :unreviewed, legs.egress_payload_review
    end

    it 'reaches exactly ASSUMED for a non-private surface' do
      assert_equal Pikuri::Tool::TrifectaLegs::ASSUMED, contribution_for(stdio('openlibrary')).legs
    end

    it 'takes the private leg from the registry declaration' do
      refute contribution_for(stdio('openlibrary')).legs.private
      assert contribution_for(stdio('notion', private: true)).legs.private
    end

    it 'introduces no child nodes' do
      assert_empty contribution_for(stdio('openlibrary')).children
    end
  end

  describe 'the wiring the book uses' do
    it 'stays silent for a calculator plus an open-data server — two legs, no private pool' do
      contribution = Pikuri::Mcp::Extension.new(
        registry: Pikuri::Mcp::Registry.new(entries: [stdio('openlibrary')])
      ).trifecta_contribution([])

      node = Pikuri::Trifecta::Node.new(label: 'pikuri-openlibrary',
                                        tool_legs: { 'mcp' => contribution.legs })
      assert_equal :silent, Pikuri::Trifecta.walk(node).verdict
    end

    it 'goes loud the moment the same surface sits next to a private server' do
      contribution = Pikuri::Mcp::Extension.new(
        registry: Pikuri::Mcp::Registry.new(entries: [stdio('openlibrary'), stdio('mail', private: true)])
      ).trifecta_contribution([])

      node = Pikuri::Trifecta::Node.new(label: 'assistant', tool_legs: { 'mcp' => contribution.legs })
      assert_equal :loud, Pikuri::Trifecta.walk(node).verdict
    end
  end
end
