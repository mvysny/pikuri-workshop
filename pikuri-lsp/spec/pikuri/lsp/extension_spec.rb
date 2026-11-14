# frozen_string_literal: true

require 'tmpdir'

describe Pikuri::Lsp::Extension do
  entry = Pikuri::Lsp::Registry::StdioEntry.new(id: 'ruby', command: %w[ruby-lsp], files: %w[*.rb])
  registry = Pikuri::Lsp::Registry.new(entries: [entry])

  configurator = lambda do
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base', id: '', streaming: false,
      cancellable: nil, interloper: nil
    )
  end

  # Minimal ExtensionContext stand-in recording what was emitted.
  fake_ctx = Class.new do
    attr_reader :emitted

    def initialize
      @emitted = []
    end

    def emit_event(event)
      @emitted << event
    end
  end

  wired = lambda do |the_registry = registry, &block|
    Dir.mktmpdir('pikuri-lsp-ext-') do |root|
      fs = Pikuri::Workspace::Filesystem.new(project_root: File.realpath(root))
      c = configurator.call
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

  it 'arms a teardown that a crash-free exit runs even before a child exists' do
    wired.call do |ext, c|
      assert_equal 1, c.on_close_handlers.size
      c.on_close_handlers.each(&:call)

      assert_empty ext.servers.started_ids
    end
  end

  it 'is a no-op on an empty registry, so a host that configures nothing wires no tool' do
    wired.call(Pikuri::Lsp::Registry::EMPTY) do |ext, c|
      assert_empty c.tools
      assert_empty c.on_close_handlers
      assert_nil ext.servers
    end
  end

  describe '#bind' do
    it 'points the tool progress callback at the agent event stream' do
      wired.call do |ext, c|
        ctx = fake_ctx.new
        ext.bind(ctx)
        progress = Pikuri::Lsp::ServerProgress.new(server_id: 'ruby', title: 'Indexing')

        c.tools.first.on_progress.call(progress)

        assert_equal [progress], ctx.emitted
      end
    end

    it 'binds harmlessly when there was no tool to hand an emitter to' do
      wired.call(Pikuri::Lsp::Registry::EMPTY) do |ext|
        ctx = fake_ctx.new
        ext.bind(ctx)

        assert_empty ctx.emitted
      end
    end
  end
end
