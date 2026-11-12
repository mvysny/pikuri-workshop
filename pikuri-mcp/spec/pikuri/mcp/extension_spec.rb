# frozen_string_literal: true

RSpec.describe Pikuri::Mcp::Extension do
  # Tracker stand-in for Mcp::Servers — same shape used by the
  # agent_spec.rb #close tests. Implements only the surface the
  # extension touches.
  let(:tracker_servers_class) do
    Class.new do
      attr_reader :close_calls, :build_calls, :start_calls
      attr_accessor :empty_value, :snippet

      def initialize(empty: true, snippet: '')
        @empty_value = empty
        @snippet = snippet
        @close_calls = 0
        @start_calls = 0
        @build_calls = []
      end

      def start_all
        @start_calls += 1
      end

      def empty?
        @empty_value
      end

      def system_prompt_snippet
        @snippet
      end

      def close
        @close_calls += 1
      end

      def build_mcp_connect_tool(ctx)
        @build_calls << ctx
        # The real Connect class — we don't need to fake it here,
        # the test verifies the call shape, not the returned tool.
        Struct.new(:to_ruby_llm_tool).new(:fake_rl_tool)
      end
    end
  end

  let(:configurator) do
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base',
      id: '',
      streaming: false,
      cancellable: nil,
      interloper: nil
    )
  end

  let(:non_empty_registry) do
    Pikuri::Mcp::Registry.new(entries: [
      Pikuri::Mcp::Registry::StdioEntry.new(id: 'x', command: ['no-op'])
    ])
  end

  # Stub Mcp::Servers.new to return our tracker instead of spawning
  # a real subprocess; restore on teardown.
  def with_stubbed_servers(tracker)
    original_new = Pikuri::Mcp::Servers.method(:new)
    Pikuri::Mcp::Servers.define_singleton_method(:new) { |_registry, **_kw| tracker }
    yield
  ensure
    Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| original_new.call(r, **kw) }
  end

  it 'is an Agent::Extension by composition' do
    ext = described_class.new(registry: Pikuri::Mcp::Registry::EMPTY)
    assert_kind_of Pikuri::Agent::Extension, ext
  end

  describe '#configure' do
    it 'is a no-op when the registry is empty (no Servers built, no on_close, no snippet)' do
      ext = described_class.new(registry: Pikuri::Mcp::Registry::EMPTY)
      ext.configure(configurator)

      assert_nil ext.servers
      assert_equal [], ext.system_prompt_snippets
      assert_equal [], configurator.on_close_handlers
    end

    it 'builds Mcp::Servers, registers an on_close handler, and exposes the snippet (non-empty registry, live servers)' do
      tracker = tracker_servers_class.new(empty: false, snippet: "\n\n<available_mcps>...</available_mcps>")
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)

      with_stubbed_servers(tracker) { ext.configure(configurator) }

      assert_same tracker, ext.servers
      assert_equal 1, ext.system_prompt_snippets.size
      snippet = ext.system_prompt_snippets.first
      refute snippet.start_with?("\n"), 'snippet must be lstripped — Agent owns the separator'
      assert_equal 1, configurator.on_close_handlers.size

      # on_close handler calls servers.close
      configurator.on_close_handlers.first.call
      assert_equal 1, tracker.close_calls
    end

    it 'starts the servers via start_all' do
      tracker = tracker_servers_class.new(empty: false, snippet: 'x')
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)

      with_stubbed_servers(tracker) { ext.configure(configurator) }

      assert_equal 1, tracker.start_calls
    end

    it 'arms on_close before start_all, so a start failure still leaves cleanup wired' do
      # The leak guard: on_close is registered *before* the failure-prone
      # start_all. So even when start_all raises, the close handler is
      # already on the configurator's list — which on a real agent is its
      # live @on_close_handlers, letting the constructor rescue close the
      # half-started servers. If on_close were armed after start_all, the
      # handler would be missing here.
      tracker = tracker_servers_class.new(empty: false)
      tracker.define_singleton_method(:start_all) { raise 'boom during start' }
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)

      assert_raises(RuntimeError) do
        with_stubbed_servers(tracker) { ext.configure(configurator) }
      end

      assert_equal 1, configurator.on_close_handlers.size
      configurator.on_close_handlers.first.call
      assert_equal 1, tracker.close_calls
    end

    it 'still registers on_close when the registry produces an empty Servers (no live ids)' do
      # Servers with no live ids must still close cleanly — the
      # gem may have started the runtime even if every server
      # failed to register (e.g. all rejected by Verifier).
      tracker = tracker_servers_class.new(empty: true, snippet: '')
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)

      with_stubbed_servers(tracker) { ext.configure(configurator) }

      assert_same tracker, ext.servers
      assert_equal [], ext.system_prompt_snippets # empty → no snippet
      assert_equal 1, configurator.on_close_handlers.size
    end
  end

  describe '#bind' do
    # ExtensionContext stand-in: records tools registered via
    # +add_raw_tool+ and exposes a minimal +agent+ whose +tools+ never
    # contain Mcp::Servers::Connect for these specs.
    let(:dummy_ctx_class) do
      Class.new do
        attr_reader :added_tools, :agent

        def initialize
          @added_tools = []
          @agent = Struct.new(:tools).new([])
        end

        def add_raw_tool(rl_tool)
          @added_tools << rl_tool
        end
      end
    end

    it 'is a no-op when the registry was empty at configure time' do
      ctx = dummy_ctx_class.new
      ext = described_class.new(registry: Pikuri::Mcp::Registry::EMPTY)
      ext.configure(configurator)

      ext.bind(ctx)

      assert_equal [], ctx.added_tools
    end

    it 'skips connect tool when servers are empty (no live ids)' do
      tracker = tracker_servers_class.new(empty: true)
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)
      with_stubbed_servers(tracker) { ext.configure(configurator) }

      ctx = dummy_ctx_class.new
      ext.bind(ctx)

      assert_equal [], ctx.added_tools, 'no connect tool when servers are empty'
      assert_equal [], tracker.build_calls
    end

    it 'registers a per-agent connect tool when servers are live' do
      tracker = tracker_servers_class.new(empty: false)
      ext = described_class.new(registry: non_empty_registry,
                                synthesize_descriptions: false,
                                verify_mcp_servers: false)
      with_stubbed_servers(tracker) { ext.configure(configurator) }

      ctx = dummy_ctx_class.new
      ext.bind(ctx)

      assert_equal [ctx], tracker.build_calls, 'connect tool was built keyed to this context'
      assert_equal [:fake_rl_tool], ctx.added_tools, 'connect tool registered via ctx.add_raw_tool'
    end
  end

  # Coverage moved here from agent_spec.rb's "synthesize_descriptions:
  # kwarg plumbing" describe — these kwargs are now properties of
  # Mcp::Extension, not Agent. Verifies the synthesizer / verifier are
  # wired (or skipped) based on the extension's own flags, and that
  # the thinker closure runs a one-shot tools-free Agent on the
  # Configurator's transport, honoring its cancellable.
  describe 'synthesizer/verifier wiring' do
    let(:capturing_servers_class) do
      Class.new do
        @last_synthesizer = nil
        @last_verifier = nil
        class << self; attr_accessor :last_synthesizer, :last_verifier; end

        def initialize(_registry, synthesizer: nil, verifier: nil)
          self.class.last_synthesizer = synthesizer
          self.class.last_verifier = verifier
        end

        def start_all; end
        def empty?; true; end
        def system_prompt_snippet; ''; end
        def close; end
      end
    end

    it 'passes synthesizer: nil + verifier: nil to Mcp::Servers when both flags are false' do
      stub = capturing_servers_class
      original_new = Pikuri::Mcp::Servers.method(:new)
      Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| stub.new(r, **kw) }
      begin
        ext = described_class.new(registry: non_empty_registry,
                                  synthesize_descriptions: false,
                                  verify_mcp_servers: false)
        ext.configure(configurator)

        assert_nil stub.last_synthesizer
        assert_nil stub.last_verifier
      ensure
        Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| original_new.call(r, **kw) }
      end
    end

    # Fake one-shot agent the stubbed Pikuri::Agent.new returns: records
    # the asked prompt, returns a canned answer, tracks #close.
    let(:fake_thinker_agent_class) do
      Class.new do
        attr_reader :asked, :closed

        def initialize
          @asked = []
          @closed = false
        end

        def run_loop(user_message:)
          @asked << user_message
          nil
        end

        def last_assistant_content
          'synth result'
        end

        def close
          @closed = true
        end
      end
    end

    def build_configurator(cancellable: nil)
      Pikuri::Agent::Configurator.new(
        transport: Pikuri::Agent::ChatTransport.new(model: 'qwen-x'),
        system_prompt_base: 'base',
        id: '',
        streaming: false,
        cancellable: cancellable,
        interloper: nil
      )
    end

    # Run +block+ with Servers swapped for the capturing stub, the
    # on-disk cache nulled (so stored entries can't skip the thinker),
    # and Pikuri::Agent.new stubbed to capture ctor kwargs and return
    # +fake_agent+.
    def with_thinker_harness(fake_agent)
      stub = capturing_servers_class
      original_servers_new = Pikuri::Mcp::Servers.method(:new)
      Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| stub.new(r, **kw) }
      original_cache_new = Pikuri::Mcp::Cache.method(:new)
      Pikuri::Mcp::Cache.define_singleton_method(:new) { |**_| Pikuri::Mcp::Cache::NULL }
      agent_ctor_calls = []
      original_agent_new = Pikuri::Agent.method(:new)
      Pikuri::Agent.define_singleton_method(:new) do |**kw, &_blk|
        agent_ctor_calls << kw
        fake_agent
      end
      yield agent_ctor_calls
    ensure
      Pikuri::Mcp::Servers.define_singleton_method(:new) { |r, **kw| original_servers_new.call(r, **kw) }
      Pikuri::Mcp::Cache.define_singleton_method(:new) { |**kw| original_cache_new.call(**kw) }
      Pikuri::Agent.define_singleton_method(:new) { |**kw, &blk| original_agent_new.call(**kw, &blk) }
    end

    # Minimal stand-ins to drive Mcp::Synthesizer#call so the captured
    # thinker closure fires.
    def drive_synthesizer(synthesizer)
      entry = Pikuri::Mcp::Registry::StdioEntry.new(id: 'probe', command: ['noop'])
      tool = Struct.new(:name, :description, :input_schema).new('t', 'd', {})
      client = Struct.new(:server_info).new({ 'serverInfo' => {} })
      synthesizer.call(entry: entry, client: client, tools: [tool])
    end

    it 'builds a Mcp::Synthesizer whose thinker runs a one-shot tools-free Agent on the configurator transport' do
      fake_agent = fake_thinker_agent_class.new
      with_thinker_harness(fake_agent) do |agent_ctor_calls|
        ext = described_class.new(registry: non_empty_registry,
                                  synthesize_descriptions: true,
                                  verify_mcp_servers: false)
        ext.configure(build_configurator)

        synthesizer = capturing_servers_class.last_synthesizer
        refute_nil synthesizer
        assert_kind_of Pikuri::Mcp::Synthesizer, synthesizer

        result = drive_synthesizer(synthesizer)

        assert_equal 'synth result', result
        # One fresh agent per thinker call: tools-free, generic thinker
        # system prompt, the configurator's transport.
        assert_equal 1, agent_ctor_calls.size
        ctor = agent_ctor_calls.first
        assert_equal 'qwen-x', ctor[:transport].model
        assert_equal Pikuri::Mcp::Thinker::SYSTEM_PROMPT, ctor[:system_prompt]
        # The build prompt arrives as the single user turn, and the
        # one-shot agent is closed afterwards.
        assert_match(/Server id: probe/, fake_agent.asked.first)
        assert fake_agent.closed, 'the one-shot thinker agent must be closed after the call'
      end
    end

    it 'checks the cancellable before each thinker call, so a tripped flag aborts without constructing an agent' do
      cancellable = Pikuri::Agent::Control::Cancellable.new
      fake_agent = fake_thinker_agent_class.new
      with_thinker_harness(fake_agent) do |agent_ctor_calls|
        ext = described_class.new(registry: non_empty_registry,
                                  synthesize_descriptions: true,
                                  verify_mcp_servers: false)
        ext.configure(build_configurator(cancellable: cancellable))

        cancellable.cancel!
        assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
          drive_synthesizer(capturing_servers_class.last_synthesizer)
        end
        assert_empty agent_ctor_calls, 'pre-call check must fire before the agent is constructed'
      end
    end
  end
end
