# frozen_string_literal: true

require 'tmpdir'
require 'pikuri/testing'

describe Pikuri::Lsp::Extension do
  entry = Pikuri::Lsp::Registry::StdioEntry.new(id: 'ruby', command: %w[ruby-lsp], files: %w[*.rb])
  registry = Pikuri::Lsp::Registry.new(entries: [entry])

  wired = lambda do |the_registry = registry, &block|
    Dir.mktmpdir('pikuri-lsp-ext-') do |root|
      fs = Pikuri::Workspace::Filesystem.new(project_root: File.realpath(root))
      c = Pikuri::Testing.configurator
      ext = described_class.new(registry: the_registry, filesystem: fs)
      ext.configure(c)
      block.call(ext, c, root)
    end
  end

  it 'is an Agent::Extension by composition' do
    fs = Pikuri::Workspace::Filesystem.new(project_root: Dir.pwd)

    assert_kind_of Pikuri::Agent::Extension, described_class.new(filesystem: fs)
  end

  it 'registers the lsp tool through add_tool, so its trifecta legs stay visible' do
    wired.call do |_ext, c|
      assert_equal %w[lsp], c.tools.map(&:name)
      refute_nil c.tools.first.trifecta_legs
    end
  end

  it 'spawns nothing while wiring, because a server starts on first use' do
    wired.call do |ext|
      assert_empty ext.servers.started_ids
    end
  end

  it 'arms a teardown that closing the agent runs even before a child exists' do
    wired.call do |ext, c|
      closed = false
      ext.servers.define_singleton_method(:close) { closed = true }

      c.agent.close

      assert closed
      assert_empty ext.servers.started_ids
    end
  end

  it 'is a no-op on an empty registry, so a host that configures nothing wires no tool' do
    wired.call(Pikuri::Lsp::Registry::EMPTY) do |ext, c|
      assert_empty c.tools
      assert_nil ext.servers
    end
  end

  it 'points the tool progress callback at the agent event stream' do
    wired.call do |_ext, c|
      recorder = Pikuri::Agent::Listener::InMemoryEventList.new
      c.add_listener(recorder)
      progress = Pikuri::Lsp::ServerProgress.new(server_id: 'ruby', title: 'Indexing')

      c.tools.first.on_progress.call(progress)

      assert_equal [progress], recorder.events
    end
  end
end
