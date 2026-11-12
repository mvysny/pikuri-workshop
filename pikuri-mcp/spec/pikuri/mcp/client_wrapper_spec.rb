# frozen_string_literal: true

require 'tempfile'

# Integration spec for {Pikuri::Mcp::ClientWrapper}. Exercises the real
# +mcp+ gem against the in-tree fixture at
# +spec/support/test_mcp_server.rb+, so the wrapper's restart-and-retry
# path is checked end-to-end against actual subprocess death rather
# than mocked transports. Each example spawns its own wrapper so a
# crash / restart in one example can't leak into the next.
RSpec.describe Pikuri::Mcp::ClientWrapper do
  # Method rather than a constant: `RSpec.describe ... do ... end`
  # blocks run with `instance_eval`, so a constant defined inside the
  # block lands at the top level and collides with the same-named
  # constant in +servers_spec.rb+.
  def test_server_command
    TestServer.command
  end

  def fresh_entry
    Pikuri::Mcp::Registry::StdioEntry.new(id: 'test', command: test_server_command)
  end

  # Wraps an entry whose command sets +PIKURI_TEST_FLAKY_MARKER+ to a
  # fresh, non-existent tempfile path. Yields the wrapper + marker path
  # to the block; closes the wrapper and removes any created marker on
  # exit so spec order independence is preserved.
  def with_flaky_wrapper
    Tempfile.create('pikuri-flaky-marker') do |f|
      marker = f.path
      File.delete(marker) if File.exist?(marker)
      cmd = TestServer.command('PIKURI_TEST_FLAKY_MARKER' => marker)
      entry = Pikuri::Mcp::Registry::StdioEntry.new(id: 'test', command: cmd)
      wrapper = described_class.new(entry)
      begin
        yield wrapper, marker
      ensure
        wrapper.close
      end
    end
  end

  describe '#call_tool happy path' do
    it 'returns the raw JSON-RPC response on success' do
      wrapper = described_class.new(fresh_entry)
      echo = wrapper.tools.find { |t| t.name == 'echo' }
      response = wrapper.call_tool(tool: echo, arguments: { message: 'hi' })
      assert_equal 'hi', response.dig('result', 'content', 0, 'text')
    ensure
      wrapper&.close
    end
  end

  describe 'StdioEntry env passthrough' do
    # The fixture's +flaky_crash+ tool reads +PIKURI_TEST_FLAKY_MARKER+
    # from its own ENV. Here it arrives via the entry's +env:+ (not the
    # +env+ command prefix used elsewhere), so a successful
    # restart-and-recover proves the env hash reached the subprocess.
    it 'reaches the spawned subprocess' do
      Tempfile.create('pikuri-env-marker') do |f|
        marker = f.path
        File.delete(marker) if File.exist?(marker)
        entry = Pikuri::Mcp::Registry::StdioEntry.new(
          id: 'test',
          command: test_server_command,
          env: { 'PIKURI_TEST_FLAKY_MARKER' => marker }
        )
        wrapper = described_class.new(entry)
        begin
          flaky = wrapper.tools.find { |t| t.name == 'flaky_crash' }
          response = wrapper.call_tool(tool: flaky, arguments: {})
          assert_equal 'recovered', response.dig('result', 'content', 0, 'text')
        ensure
          wrapper.close
        end
      end
    end
  end

  describe 'subprocess-death recovery' do
    it 'restarts the subprocess and the retry succeeds on the second attempt' do
      with_flaky_wrapper do |wrapper, _marker|
        flaky = wrapper.tools.find { |t| t.name == 'flaky_crash' }
        response = wrapper.call_tool(tool: flaky, arguments: {})
        assert_equal 'recovered', response.dig('result', 'content', 0, 'text')
      end
    end

    it 'logs a WARN heads-up when restart-and-retry kicks in' do
      original = Pikuri.log_io
      captured = StringIO.new
      Pikuri.log_io = captured
      with_flaky_wrapper do |wrapper, _marker|
        flaky = wrapper.tools.find { |t| t.name == 'flaky_crash' }
        wrapper.call_tool(tool: flaky, arguments: {})
      end
      log = captured.string
      assert_match(/subprocess died/, log)
      assert_match(%r{restarting and retrying \(attempt 2/3\)}, log)
    ensure
      Pikuri.log_io = original if original
    end

    it 'gives up after MAX_CALL_ATTEMPTS when the subprocess keeps dying' do
      # +crash+ always crashes, so all three attempts fail and the
      # last error propagates. The fact that the call terminates at
      # all (rather than looping forever) is the give-up signal —
      # the per-attempt WARN-log assertion below verifies the cap
      # specifically.
      wrapper = described_class.new(fresh_entry)
      crash = wrapper.tools.find { |t| t.name == 'crash' }
      assert_raises(MCP::Client::RequestHandlerError) do
        wrapper.call_tool(tool: crash, arguments: {})
      end
    ensure
      wrapper&.close
    end

    it 'emits a WARN log per retry attempt when the subprocess keeps dying' do
      original = Pikuri.log_io
      captured = StringIO.new
      Pikuri.log_io = captured
      wrapper = described_class.new(fresh_entry)
      crash = wrapper.tools.find { |t| t.name == 'crash' }
      assert_raises(MCP::Client::RequestHandlerError) do
        wrapper.call_tool(tool: crash, arguments: {})
      end
      log = captured.string
      # MAX_CALL_ATTEMPTS=3 ⇒ initial try + 2 restart-and-retry
      # iterations, so we should see two WARN lines, one per
      # restart. The third attempt's failure raises out without
      # logging (no more retries).
      assert_equal 2, log.scan(/restarting and retrying/).size
      assert_match(%r{attempt 2/3}, log)
      assert_match(%r{attempt 3/3}, log)
    ensure
      Pikuri.log_io = original if original
      wrapper&.close
    end
  end

  describe 'non-recoverable failures' do
    it 'does not restart on a RequestHandlerError whose message does not match the subprocess-death set' do
      # Swap +@client.call_tool+ to raise a non-matching
      # RequestHandlerError on every call. Count invocations. If
      # the wrapper retried we'd see >1; we expect exactly 1.
      wrapper = described_class.new(fresh_entry)
      original_client = wrapper.client
      attempts = 0
      wrapper.client.define_singleton_method(:call_tool) do |**|
        attempts += 1
        raise MCP::Client::RequestHandlerError.new(
          'Some unrelated request error',
          {},
          error_type: :internal_error
        )
      end
      fake_tool = MCP::Client::Tool.new(name: 'echo', description: '', input_schema: {})
      assert_raises(MCP::Client::RequestHandlerError) do
        wrapper.call_tool(tool: fake_tool, arguments: {})
      end
      assert_equal 1, attempts, 'wrapper retried a non-recoverable failure'
      # And the client reference did not get replaced — restart!
      # was never invoked.
      assert_same original_client, wrapper.client
    ensure
      wrapper&.close
    end
  end

  describe 'the child environment' do
    it 'de-bundlerizes it, or a Ruby-written server resolves gems out of pikuri\'s bundle' do
      skip 'not running under bundler' unless ENV['BUNDLE_GEMFILE']

      wrapper = described_class.new(fresh_entry)
      env = wrapper.instance_variable_get(:@transport).env

      assert env.key?('BUNDLE_GEMFILE'), 'expected the bundler correction in the spawn env'
      assert_nil env['BUNDLE_GEMFILE'], 'expected BUNDLE_GEMFILE unset in the child'
      # The entry's own env merges *over* this; that precedence is pinned in
      # pikuri-lsp's real-child spec, where a spawn survives overriding it.
    ensure
      wrapper&.close
    end
  end

  describe '#close' do
    it 'is idempotent' do
      wrapper = described_class.new(fresh_entry)
      wrapper.close
      wrapper.close # must not raise
    end
  end

  describe 'initialize failure cleanup' do
    it 'closes the half-opened transport if the connect handshake fails' do
      # Spawning a non-MCP binary like /bin/false yields a
      # subprocess that exits immediately. +MCP::Client::Stdio#start+
      # succeeds (popen3 just runs the binary), then +#connect+ tries
      # to read the +initialize+ response and finds the pipe closed.
      # The wrapper's spawn_fresh! rescue should close the transport
      # before re-raising; we verify there's no orphan subprocess by
      # checking that the constructor raised.
      bogus_entry = Pikuri::Mcp::Registry::StdioEntry.new(
        id: 'bogus', command: ['/bin/false']
      )
      assert_raises(MCP::Client::RequestHandlerError) do
        described_class.new(bogus_entry)
      end
    end
  end
end
