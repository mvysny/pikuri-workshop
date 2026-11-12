# frozen_string_literal: true

require 'set'

# Integration spec — exercises the real +mcp+ gem against the
# in-tree test server at +spec/support/test_mcp_server.rb+. The test
# server speaks real MCP over stdio, so this suite catches anything
# the schema-adapter or subprocess lifecycle would get wrong against
# a real server, without needing +npx+ or network egress.
#
# Each spec spawns its own +Mcp::Servers+ so a server crash / close in
# one example can't leak into the next.
RSpec.describe Pikuri::Mcp::Servers do
  TEST_SERVER_COMMAND = TestServer.command.freeze

  def fresh_registry
    Pikuri::Mcp::Registry.new(entries: [
      Pikuri::Mcp::Registry::StdioEntry.new(id: 'test', command: TEST_SERVER_COMMAND)
    ])
  end

  def fake_ctx
    # Stand-in Agent::ExtensionContext that records tools registered
    # via +add_raw_tool+ without instantiating a real +Pikuri::Agent+
    # (which would require a RubyLLM transport).
    ctx = Object.new
    added = []
    ctx.define_singleton_method(:add_raw_tool) { |t| added << t }
    ctx.define_singleton_method(:added_tools) { added }
    ctx
  end

  describe '#initialize against the test fixture' do
    it 'spawns the server, lists tools, exposes them via live_ids' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      assert_equal ['test'], servers.live_ids
      refute servers.empty?
    ensure
      servers&.close
    end

    it 'logs one INFO event per started server with the raw schema' do
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      log = captured.string
      assert_match(/MCP server "test" started/, log)
      assert_match(/Tools \(5\)/, log)
      assert_match(/- echo$/m, log)
      assert_match(/- divide$/m, log)
      assert_match(/input_schema:/, log)
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end

    it 'drops a server whose command does not exist, logs a warning, leaves live_ids empty' do
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      bogus = Pikuri::Mcp::Registry.new(entries: [
        Pikuri::Mcp::Registry::StdioEntry.new(id: 'bogus', command: ['/nonexistent/binary/path'])
      ])
      servers = Pikuri::Mcp::Servers.start(bogus)
      assert servers.empty?
      assert_equal [], servers.live_ids
      assert_match(/Failed to start MCP server "bogus"/, captured.string)
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end

    it 'drops an HttpEntry whose endpoint refuses connections, logs the url in the warning' do
      # Port 1 on loopback is reliably refused-connect — fails fast,
      # mirrors the bogus-stdio test for the HTTP transport path. Real
      # call into MCP::Client::HTTP, so this exercises build_transport
      # dispatch + the rescue + describe_entry url branch.
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      bogus = Pikuri::Mcp::Registry.new(entries: [
        Pikuri::Mcp::Registry::HttpEntry.new(id: 'bogus-http', url: 'http://127.0.0.1:1/mcp')
      ])
      servers = Pikuri::Mcp::Servers.start(bogus)
      assert servers.empty?
      assert_equal [], servers.live_ids
      assert_match(/Failed to start MCP server "bogus-http"/, captured.string)
      assert_match(%r{url: http://127\.0\.0\.1:1/mcp}, captured.string)
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end

    it 'still constructs (empty) when the registry itself is empty' do
      servers = Pikuri::Mcp::Servers.start(Pikuri::Mcp::Registry::EMPTY)
      assert servers.empty?
      assert_equal '', servers.system_prompt_snippet
    ensure
      servers&.close
    end
  end

  describe '#system_prompt_snippet' do
    it 'renders an <available_mcps> block listing live servers + descriptions' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      snippet = servers.system_prompt_snippet
      assert_match(/<available_mcps>/, snippet)
      assert_match(%r{<id>test</id>}, snippet)
      assert_match(/In-tree fixture used by pikuri specs/, snippet)
      assert_match(%r{</available_mcps>}, snippet)
    ensure
      servers&.close
    end

    it 'returns empty string when no servers are live' do
      servers = Pikuri::Mcp::Servers.start(Pikuri::Mcp::Registry::EMPTY)
      assert_equal '', servers.system_prompt_snippet
    ensure
      servers&.close
    end
  end

  describe '#register_tools_with_agent' do
    it 'adds one RubyLLM::Tool subclass per MCP-exposed tool to the agent' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      count = servers.register_tools_with_agent('test', ctx)
      assert_equal 5, count
      assert_equal 5, ctx.added_tools.size
      assert(ctx.added_tools.all? { |t| t < RubyLLM::Tool })
    ensure
      servers&.close
    end

    it 'namespaces tool names as <server_id>__<tool_name>' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      servers.register_tools_with_agent('test', ctx)
      names = ctx.added_tools.map(&:name)
      assert_includes names, 'test__echo'
      assert_includes names, 'test__divide'
      assert_includes names, 'test__crash'
    ensure
      servers&.close
    end

    it 'prefixes every tool description with the provenance marker' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      servers.register_tools_with_agent('test', ctx)
      ctx.added_tools.each do |t|
        # RubyLLM::Tool stashes the description on the class.
        desc = t.respond_to?(:description) ? t.description : t.instance_variable_get(:@description)
        assert_match(/\A\[From MCP server "test"\]/, desc.to_s)
      end
    ensure
      servers&.close
    end

    it 'preserves the MCP tool description verbatim after the provenance prefix' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      servers.register_tools_with_agent('test', ctx)
      echo = ctx.added_tools.find { |t| t.name == 'test__echo' }
      assert_equal(
        %([From MCP server "test"]\n\nEchoes the given message back to the caller.),
        echo.description
      )
    ensure
      servers&.close
    end

    it 'propagates input-parameter descriptions to the RubyLLM wire schema' do
      # RubyLLM::Tool#parameters_schema is the JSON Schema that ships to
      # the provider for tool calling. Asserting against it directly
      # verifies that per-property descriptions from the MCP server's
      # input_schema make it all the way through deep_dup +
      # stringify_keys without being dropped.
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      servers.register_tools_with_agent('test', ctx)

      echo = ctx.added_tools.find { |t| t.name == 'test__echo' }
      schema = echo.new.parameters_schema
      assert_equal 'object', schema['type']
      assert_includes schema['required'], 'message'
      assert_equal 'The message to echo back verbatim.',
                   schema.dig('properties', 'message', 'description')
      assert_equal 'string',
                   schema.dig('properties', 'message', 'type')

      divide = ctx.added_tools.find { |t| t.name == 'test__divide' }
      div_schema = divide.new.parameters_schema
      assert_equal 'The numerator.',
                   div_schema.dig('properties', 'a', 'description')
      assert_equal 'The denominator. Must be non-zero.',
                   div_schema.dig('properties', 'b', 'description')
    ensure
      servers&.close
    end

    it 'strips the $schema URI to avoid provider-side rejection of extra top-level keys' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      servers.register_tools_with_agent('test', ctx)
      echo = ctx.added_tools.find { |t| t.name == 'test__echo' }
      schema = echo.new.parameters_schema
      refute schema.key?('$schema'), "expected $schema URI to be stripped, got: #{schema.inspect}"
    ensure
      servers&.close
    end

    it 'logs output_schema in the audit log when the MCP server declares one' do
      # output_schema has no destination in RubyLLM's Tool surface
      # (no return-schema slot), so the audit log is the only place
      # it survives. The test fixture's `echo` tool declares one;
      # asserting it shows up confirms we don't quietly drop it.
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      log = captured.string
      assert_match(/output_schema:.*echoed/, log)
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end

    it 'raises ArgumentError for an unknown id (loud-on-bugs, not Error: ...)' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      assert_raises(ArgumentError) do
        servers.register_tools_with_agent('nope', fake_ctx)
      end
    ensure
      servers&.close
    end
  end

  describe 'synthesized RubyLLM::Tool execute paths' do
    it 'returns the raw text content on success' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      servers.register_tools_with_agent('test', ctx)
      echo = ctx.added_tools.find { |t| t.name == 'test__echo' }
      assert_equal 'hello pikuri', echo.new.execute(message: 'hello pikuri')
    ensure
      servers&.close
    end

    it 'converts MCP-side tool errors into Error: ... observations' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      servers.register_tools_with_agent('test', ctx)
      divide = ctx.added_tools.find { |t| t.name == 'test__divide' }
      result = divide.new.execute(a: 10, b: 0)
      assert_match(/\AError:/, result)
      assert_match(/division by zero/, result)
    ensure
      servers&.close
    end

    it 'surfaces mid-call server death as an Error: ... observation' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      servers.register_tools_with_agent('test', ctx)
      crash = ctx.added_tools.find { |t| t.name == 'test__crash' }
      result = crash.new.execute
      assert_match(/\AError: MCP server "test" call failed/, result)
    ensure
      servers&.close
    end
  end

  describe Pikuri::Mcp::Servers::Connect do
    it 'returns an Error: ... for an unknown id' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      tool = servers.build_mcp_connect_tool(ctx)
      result = tool.run('id' => 'unknown')
      assert_match(/\AError: unknown MCP server id/, result.content)
      assert_match(/Available: test/, result.content)
    ensure
      servers&.close
    end

    it 'connects an unknown-to-this-instance server and reports the tool count' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      tool = servers.build_mcp_connect_tool(ctx)
      result = tool.run('id' => 'test')
      assert_match(/Connected to MCP server 'test'/, result.to_s)
      assert_match(/Added 5 tools/, result.to_s)
      assert_equal 'Connected, 5 tools', result.summary
      assert_equal 'McpConnect', tool.display_name
      assert_equal 'test', tool.describe_call('id' => 'test')
      assert_equal 5, ctx.added_tools.size
    ensure
      servers&.close
    end

    it 'rejects re-activation with an Error: ... (and does not re-register tools)' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx = fake_ctx
      tool = servers.build_mcp_connect_tool(ctx)
      tool.run('id' => 'test')
      result = tool.run('id' => 'test')
      assert_match(/\AError: server 'test' is already connected/, result.content)
      assert_equal 5, ctx.added_tools.size # not 10
    ensure
      servers&.close
    end

    it 'tracks activation per-instance — a fresh McpConnect can reactivate' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      ctx1 = fake_ctx
      ctx2 = fake_ctx
      tool1 = servers.build_mcp_connect_tool(ctx1)
      tool2 = servers.build_mcp_connect_tool(ctx2)
      tool1.run('id' => 'test')
      result2 = tool2.run('id' => 'test').to_s # fresh activation set
      assert_match(/Connected to MCP server 'test'/, result2)
      assert_equal 5, ctx1.added_tools.size
      assert_equal 5, ctx2.added_tools.size
    ensure
      servers&.close
    end
  end

  describe '#close' do
    it 'is idempotent' do
      servers = Pikuri::Mcp::Servers.start(fresh_registry)
      servers.close
      # second call must not raise
      servers.close
    end
  end

  # Synthesis-path tests use the fixture with +PIKURI_TEST_SKIP_INSTRUCTIONS=1+
  # so the server's +initialize+ handshake omits the +instructions+ field
  # — that's the real-world common case where the fallback chain in
  # +#resolve_description+ would otherwise bottom out at +serverInfo.name+.
  describe 'description synthesis via synthesizer:' do
    def no_instructions_registry
      cmd = TestServer.command('PIKURI_TEST_SKIP_INSTRUCTIONS' => '1')
      Pikuri::Mcp::Registry.new(entries: [
        Pikuri::Mcp::Registry::StdioEntry.new(id: 'test', command: cmd)
      ])
    end

    def synth_with(thinker)
      Pikuri::Mcp::Synthesizer.new(thinker: thinker)
    end

    it 'routes through the synthesizer and uses its return value as the description' do
      synthesizer = synth_with(->(_p) { 'Provides four demo tools used by pikuri specs to exercise MCP wiring.' })
      servers = Pikuri::Mcp::Servers.start(no_instructions_registry, synthesizer: synthesizer)
      assert_match(/four demo tools/, servers.system_prompt_snippet)
    ensure
      servers&.close
    end

    it 'skips the synthesizer when the server already supplied instructions' do
      called = false
      synthesizer = synth_with(->(_p) { called = true; 'unused' })
      servers = Pikuri::Mcp::Servers.start(fresh_registry, synthesizer: synthesizer)
      refute called, 'synthesizer should not be called when instructions: is present'
      assert_match(/In-tree fixture used by pikuri specs/, servers.system_prompt_snippet)
    ensure
      servers&.close
    end

    it 'falls back to serverInfo.name when the synthesizer returns nil' do
      # Synthesizer.call returns nil on StandardError (fail-soft) — same
      # signal here, regardless of root cause.
      synthesizer = synth_with(->(_p) { raise 'simulated synth blip' })
      servers = Pikuri::Mcp::Servers.start(no_instructions_registry, synthesizer: synthesizer)
      desc = servers.system_prompt_snippet[/<description>(.+?)<\/description>/, 1]
      assert_equal 'pikuri-test-mcp', desc
    ensure
      servers&.close
    end

    it 'propagates Cancelled out of start_all without rescuing it as a synthesis failure' do
      synthesizer = synth_with(->(_p) { raise Pikuri::Agent::Control::Cancellable::Cancelled })
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        Pikuri::Mcp::Servers.start(no_instructions_registry, synthesizer: synthesizer)
      end
      refute_match(/synthesis failed/, captured.string)
      refute_match(/Failed to start MCP server/, captured.string)
    ensure
      Pikuri.log_io = original if original
    end

    it 'logs the resolved description in the audit log so a user can see when synthesis kicked in' do
      captured = StringIO.new
      original = Pikuri.log_io
      Pikuri.log_io = captured
      synthesizer = synth_with(->(_p) { 'Synthesized blurb for the test fixture.' })
      servers = Pikuri::Mcp::Servers.start(no_instructions_registry, synthesizer: synthesizer)
      assert_match(/Description:\s+Synthesized blurb for the test fixture\./, captured.string)
    ensure
      Pikuri.log_io = original if original
      servers&.close
    end

    it 'second boot with the same surface hits the cache and skips the thinker' do
      Dir.mktmpdir('pikuri-mcp-cache-spec') do |cache_dir|
        first_calls = 0
        synth1 = Pikuri::Mcp::Synthesizer.new(
          thinker: ->(_p) { first_calls += 1; 'cached description' },
          cache: Pikuri::Mcp::Cache.new(model_id: 'spec-model', prompt_version: 1, dir: cache_dir)
        )
        servers1 = Pikuri::Mcp::Servers.start(no_instructions_registry, synthesizer: synth1)
        assert_equal 1, first_calls
        assert_match(/cached description/, servers1.system_prompt_snippet)
        servers1.close

        # Boot again with the same registry surface + same cache dir.
        # The thinker on this run must NOT be called.
        second_calls = 0
        synth2 = Pikuri::Mcp::Synthesizer.new(
          thinker: ->(_p) { second_calls += 1; 'should not be invoked' },
          cache: Pikuri::Mcp::Cache.new(model_id: 'spec-model', prompt_version: 1, dir: cache_dir)
        )
        servers2 = Pikuri::Mcp::Servers.start(no_instructions_registry, synthesizer: synth2)
        assert_equal 0, second_calls
        assert_match(/cached description/, servers2.system_prompt_snippet)
        servers2.close
      end
    end
  end
end
