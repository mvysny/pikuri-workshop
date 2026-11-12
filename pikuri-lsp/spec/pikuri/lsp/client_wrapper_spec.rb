# frozen_string_literal: true

require 'json'
require 'timeout'

describe Pikuri::Lsp::ClientWrapper do
  died = Pikuri::Lsp::ClientWrapper::ServerDied
  ruby = Pikuri::Lsp::Registry::StdioEntry.new(id: 'ruby', command: %w[ruby-lsp], files: %w[*.rb])
  java = Pikuri::Lsp::Registry::StdioEntry.new(
    id: 'java', command: %w[jdtls], files: %w[*.java],
    init_options: { extendedClientCapabilities: { classFileContentsSupport: true } }
  )

  # A wrapper wired to a fake server over pipes — no binary, no handshake yet.
  # +respawn+ hands the wrapper its next channel, which is how restart is
  # exercised without killing a real process.
  over_pipes = lambda do |entry: ruby, respawn: nil, readiness: nil, &block|
    channel, wire = Pikuri::Lsp::Testing::Wire.channel
    wrapper = described_class.new(entry: entry, root: '/tmp/project', respawn: respawn,
                                 readiness: readiness, **channel)
    begin
      Timeout.timeout(10) { block.call(wrapper, wire) }
    ensure
      wrapper.close
      wire.close
    end
  end

  # Runs #start against a fake server that answers with +capabilities+.
  start = lambda do |wrapper, wire, capabilities: {}, server_info: nil|
    thread = Thread.new { wrapper.start }
    request = wire.handshake(capabilities: capabilities, server_info: server_info)
    thread.join
    request
  end

  describe 'the handshake' do
    it 'declares the four things a real server was measured to need' do
      over_pipes.call do |wrapper, wire|
        declared = start.call(wrapper, wire).dig('params', 'capabilities')

        assert_equal %w[utf-8 utf-16], declared.dig('general', 'positionEncodings')
        assert_equal true, declared.dig('window', 'workDoneProgress'),
                     'without it jdtls emits no $/progress at all'
        assert_equal true, declared.dig('textDocument', 'definition', 'linkSupport')
        assert_equal %w[markdown plaintext], declared.dig('textDocument', 'hover', 'contentFormat')
      end
    end

    it 'names one root as both the cwd and the indexed project' do
      over_pipes.call do |wrapper, wire|
        params = start.call(wrapper, wire)['params']

        assert_equal 'file:///tmp/project', params['rootUri']
        assert_equal '/tmp/project', params['rootPath']
        assert_equal [{ 'uri' => 'file:///tmp/project', 'name' => 'project' }], params['workspaceFolders']
        assert_equal 'pikuri', params.dig('clientInfo', 'name')
      end
    end

    it 'passes initializationOptions verbatim, and omits the key without them' do
      over_pipes.call(entry: java) do |wrapper, wire|
        options = start.call(wrapper, wire)['params']['initializationOptions']

        assert_equal({ 'extendedClientCapabilities' => { 'classFileContentsSupport' => true } }, options)
      end
      over_pipes.call do |wrapper, wire|
        refute start.call(wrapper, wire)['params'].key?('initializationOptions')
      end
    end

    it 'records what this workspace advertised' do
      over_pipes.call do |wrapper, wire|
        start.call(wrapper, wire,
                   capabilities: { 'definitionProvider' => true, 'referencesProvider' => { 'workDoneProgress' => true },
                                   'documentFormattingProvider' => false, 'positionEncoding' => 'utf-8' },
                   server_info: { 'name' => 'ruby-lsp', 'version' => '0.26.10' })

        assert wrapper.supports?('definitionProvider'), 'true means supported'
        assert wrapper.supports?('referencesProvider'), 'an options object means supported'
        refute wrapper.supports?('documentFormattingProvider'), 'an explicit false means not here'
        refute wrapper.supports?('typeDefinitionProvider'), 'an absent key means not here'
        assert_equal 'utf-8', wrapper.position_encoding
        assert_equal 'ruby-lsp', wrapper.server_info['name']
      end
    end

    it 'falls back to utf-16 when the server ignores the encoding offer, as jdtls does' do
      over_pipes.call do |wrapper, wire|
        start.call(wrapper, wire, capabilities: { 'definitionProvider' => true })

        assert_equal Pikuri::Lsp::PositionEncoding::DEFAULT, wrapper.position_encoding
      end
    end

    it 'refuses to start twice' do
      over_pipes.call do |wrapper, wire|
        start.call(wrapper, wire)

        assert_raises(RuntimeError) { wrapper.start }
      end
    end
  end

  describe 'requests' do
    it 'carries a call through and hands back the result verbatim' do
      over_pipes.call do |wrapper, wire|
        start.call(wrapper, wire, capabilities: { 'definitionProvider' => true })
        thread = Thread.new { wrapper.request('textDocument/definition', { uri: 'file:///a.rb' }) }
        request = wire.take
        wire.reply(request, [{ 'uri' => 'file:///a.rb', 'range' => { 'start' => { 'line' => 0, 'character' => 0 },
                                                                    'end' => { 'line' => 0, 'character' => 3 } } }])

        assert_equal 'textDocument/definition', request['method']
        assert_equal 1, thread.value.size
      end
    end

    it 'raises ServerDied with the reason when nothing can be respawned' do
      over_pipes.call do |wrapper, wire|
        start.call(wrapper, wire)
        wire.close

        error = assert_raises(died) { wrapper.request('textDocument/hover') }
        assert_includes error.message, 'ruby'
        # Either half of the channel may notice first: the write hits EPIPE, or
        # the reader hits EOF. Both are the same death.
        assert_match(/EOF|Broken pipe/, error.message)
      end
    end
  end

  describe 'restart on death' do
    it 're-handshakes on a fresh channel and retries the call' do
      next_channel, next_wire = Pikuri::Lsp::Testing::Wire.channel
      begin
        over_pipes.call(respawn: -> { next_channel }) do |wrapper, wire|
          start.call(wrapper, wire)
          seen = Queue.new
          wrapper.on_notification { |method, _| seen << method }

          thread = Thread.new { wrapper.request('textDocument/definition') }
          wire.take           # the call the doomed server never answers
          wire.close          # ... because it dies here

          next_wire.handshake(capabilities: { 'definitionProvider' => true })
          next_wire.reply(next_wire.take, [])

          assert_equal [], thread.value
          assert wrapper.alive?

          next_wire.notify('$/progress', { 'token' => 'idx' })
          assert_equal '$/progress', seen.pop, 'a handler must survive the restart'
        end
      ensure
        next_wire.close
      end
    end

    it 'gives up after MAX_ATTEMPTS and reports the last death' do
      channels = Array.new(3) { Pikuri::Lsp::Testing::Wire.channel }
      begin
        wrapper = described_class.new(entry: ruby, root: '/tmp/project',
                                      respawn: -> { channels[1..].shift[0] },
                                      **channels[0][0])
        # Every server dies the moment it is spoken to, so the retry loop runs
        # out of attempts rather than out of servers.
        Timeout.timeout(10) do
          starter = Thread.new { wrapper.start }
          channels[0][1].handshake
          starter.join

          thread = Thread.new { wrapper.request('textDocument/hover') }
          channels[0][1].close
          channels[1][1].handshake
          channels[1][1].close

          assert_raises(died) { thread.value }
        end
        refute wrapper.alive?
      ensure
        wrapper&.close
        channels.each { |_, wire| wire.close }
      end
    end
  end

  describe 'the indexing gate' do
    # The production settle is 1.5s; a spec asserting the gate's own rule is
    # readiness_spec's job, so these only need it to elapse at all.
    settle = 0.05
    gate = -> { Pikuri::Lsp::Readiness.new(server_id: 'ruby', settle: settle) }
    progress = lambda do |name|
      JSON.parse(fixture("jdtls_progress_#{name}"))['params']
    end

    it 'is shut while the server has work open, and opens when it goes quiet' do
      over_pipes.call(readiness: gate.call) do |wrapper, wire|
        start.call(wrapper, wire)
        opened = Queue.new
        wrapper.on_notification { |method, _| opened << method }

        wire.notify('$/progress', progress.call('begin'))
        opened.pop
        refute wrapper.ready?, 'the server said it is importing'

        wire.notify('$/progress', progress.call('end'))
        opened.pop
        sleep settle * 2

        assert wrapper.ready?
      end
    end

    it 'blocks the caller until the index is built, relaying what the server says' do
      over_pipes.call(readiness: gate.call) do |wrapper, wire|
        start.call(wrapper, wire)
        wire.notify('$/progress', progress.call('begin'))
        seen = []
        waiter = Thread.new { wrapper.wait_until_ready { |update| seen << update } }

        # Not ready until the server says so, whatever the caller would prefer.
        sleep settle * 4
        assert waiter.alive?, 'a cold import is minutes, and there is no timeout'
        wire.notify('$/progress', progress.call('end'))

        assert_equal true, waiter.value
        assert_equal 'ruby', seen.first.server_id, 'the entry id, so a host can key its bars'
        assert_equal 'Initialize Workspace', seen.first.title
        assert seen.last.done
      end
    end

    it 'reports the death of a server that dies indexing, with its last words' do
      over_pipes.call(readiness: gate.call) do |wrapper, wire|
        start.call(wrapper, wire)
        wire.notify('$/progress', progress.call('begin'))
        waiter = Thread.new { wrapper.wait_until_ready { |_update| nil } }
        sleep settle * 2
        wire.close

        error = assert_raises(died) { waiter.value }
        assert_includes error.message, 'index'
      end
    end

    it 'never calls a dead child ready, however quiet it went' do
      over_pipes.call(readiness: gate.call) do |wrapper, wire|
        start.call(wrapper, wire)
        wire.close                # dies without ever announcing a single task
        sleep settle * 2          # ... and is therefore "quiet"

        error = assert_raises(died) { wrapper.wait_until_ready }
        assert_includes error.message, 'index', 'a silent corpse is not a built index'
      end
    end

    it 'stops restarting a child that cannot even handshake' do
      spawns = 0
      channels = Array.new(4) { Pikuri::Lsp::Testing::Wire.channel }
      # Every replacement dies the moment it is spoken to, so a client that kept
      # trying would spawn forever against a misconfigured server.
      respawn = lambda do
        spawns += 1
        channel, wire = channels[spawns]
        Thread.new { wire.close }
        channel
      end
      begin
        over_pipes.call(readiness: gate.call, respawn: respawn) do |wrapper, wire|
          start.call(wrapper, wire)
          wire.close

          assert_raises(died) { wrapper.wait_until_ready }
          assert_equal 1, spawns, 'a failed handshake ends the attempt; it does not spend the other two'
        end
      ensure
        channels.each { |_, wire| wire.close }
      end
    end

    it 'waits the fresh child out from scratch after a restart' do
      next_channel, next_wire = Pikuri::Lsp::Testing::Wire.channel
      # A wider window than the others: the closing assertion has to land
      # *inside* the settle the restart started, and only slack keeps that
      # from depending on the machine's mood.
      slow = Pikuri::Lsp::Readiness.new(server_id: 'ruby', settle: 0.3)
      begin
        over_pipes.call(readiness: slow, respawn: -> { next_channel }) do |wrapper, wire|
          start.call(wrapper, wire)
          wire.notify('$/progress', progress.call('begin'))
          wire.notify('$/progress', progress.call('end'))
          sleep 0.6
          assert wrapper.ready?, 'the first child finished its index'

          thread = Thread.new { wrapper.request('textDocument/definition') }
          wire.take
          wire.close
          next_wire.handshake
          next_wire.reply(next_wire.take, [])
          thread.value

          refute wrapper.ready?, "a fresh server's index is empty, whatever the old one had done"
        end
      ensure
        next_wire.close
      end
    end
  end

  describe 'shutdown' do
    it 'says shutdown then exit, and is idempotent' do
      over_pipes.call do |wrapper, wire|
        start.call(wrapper, wire)
        closer = Thread.new { wrapper.close }
        shutdown = wire.take
        # Deliberately unanswered: #close writes shutdown and exit back to back
        # and then closes the channel without awaiting the reply, so a reply
        # here is a write into a pipe whose read end is being closed on the
        # other thread — EPIPE whenever the closer wins the race.
        goodbye = wire.take
        closer.join

        assert_equal 'shutdown', shutdown['method']
        assert_equal 'exit', goodbye['method']
        refute wrapper.alive?
        wrapper.close
      end
    end
  end

  describe 'a real child process' do
    it 'raises at spawn time when the binary is not there' do
      entry = Pikuri::Lsp::Registry::StdioEntry.new(
        id: 'ghost', command: %w[pikuri-no-such-language-server], files: %w[*.rb]
      )

      error = assert_raises(died) { described_class.spawn(entry, root: Dir.pwd) }
      assert_includes error.message, 'pikuri-no-such-language-server'
    end

    it 'reports the exit status and the last thing the child said' do
      entry = Pikuri::Lsp::Registry::StdioEntry.new(
        id: 'doomed', command: ['sh', '-c', 'echo "bundler: command not found" >&2; exit 3'], files: %w[*.rb]
      )

      error = assert_raises(died) { described_class.spawn(entry, root: Dir.pwd) }
      assert_includes error.message, 'during startup'
      assert_includes error.message, 'exit 3'
      assert_includes error.message, 'bundler: command not found'
    end

    it 'signals the process group of a child that outlives its channel' do
      entry = Pikuri::Lsp::Registry::StdioEntry.new(
        id: 'sleeper', command: ['sh', '-c', 'sleep 30'], files: %w[*.rb]
      )
      # Straight to the private spawn — this child never speaks LSP, so a
      # .spawn handshake would block forever, but the real pgroup: true child is
      # the whole point of the assertion.
      wrapper = described_class.new(entry: entry, root: Dir.pwd,
                                    **described_class.send(:spawn_child, entry, Dir.pwd))
      pid = wrapper.pid

      assert pid
      wrapper.close

      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end
end
