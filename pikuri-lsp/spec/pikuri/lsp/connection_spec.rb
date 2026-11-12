# frozen_string_literal: true

require 'json'
require 'timeout'

describe Pikuri::Lsp::Connection do
  # Yields a live connection plus the server side of its channel.
  connect = lambda do |&block|
    channel, server = Pikuri::Lsp::Testing::Wire.channel
    connection = described_class.new(**channel, server_id: 'test')
    begin
      Timeout.timeout(10) { block.call(connection, server) }
    ensure
      connection.close
      server.close
    end
  end

  it 'frames a notification with a byte length, not a character count' do
    connect.call do |connection, server|
      connection.notify('textDocument/didOpen', text: '🎉')
      message = server.take

      assert_equal 'textDocument/didOpen', message['method']
      assert_equal '🎉', message.dig('params', 'text')
      refute message.key?('id')
    end
  end

  it 'parses a frame whose body is longer in bytes than in characters' do
    connect.call do |connection, server|
      thread = Thread.new { connection.request('textDocument/hover') }
      server.reply(server.take, 'contents' => '🎉 héllo')

      assert_equal '🎉 héllo', thread.value['contents']
    end
  end

  it 'demuxes concurrent requests by id, whatever order the answers arrive in' do
    connect.call do |connection, server|
      threads = %w[alpha beta].map { |name| Thread.new { connection.request("t/#{name}") } }
      requests = [server.take, server.take]
      requests.reverse_each { |request| server.reply(request, request['method']) }

      assert_equal %w[t/alpha t/beta], threads.map(&:value).sort
      assert_equal [1, 2], requests.map { |request| request['id'] }.sort
    end
  end

  it 'answers a server-initiated request from the reader thread, mid-wait' do
    connect.call do |connection, server|
      thread = Thread.new { connection.request('initialize') }
      handshake = server.take
      server.send_message('jsonrpc' => '2.0', 'id' => 'tok-1',
                          'method' => 'window/workDoneProgress/create',
                          'params' => { 'token' => 'idx' })
      auto_reply = server.take
      server.reply(handshake, 'capabilities' => {})

      assert_equal 'tok-1', auto_reply['id']
      assert_nil auto_reply['result']
      refute auto_reply.key?('method')
      assert_equal({ 'capabilities' => {} }, thread.value)
    end
  end

  it 'hands notifications to every handler, and only notifications' do
    connect.call do |connection, server|
      seen = Queue.new
      connection.on_notification { |method, params| seen << [method, params] }
      server.send_message('jsonrpc' => '2.0', 'method' => 'window/logMessage',
                          'params' => { 'type' => 1, 'message' => 'boom' })
      server.send_message('jsonrpc' => '2.0', 'id' => 'req-1', 'method' => 'workspace/configuration')

      assert_equal ['window/logMessage', { 'type' => 1, 'message' => 'boom' }], seen.pop
      server.take # the auto-reply
      assert_equal 0, seen.size
    end
  end

  it 'keeps reading after a handler raises' do
    connect.call do |connection, server|
      seen = Queue.new
      connection.on_notification { raise 'handler bug' }
      connection.on_notification { |method, _| seen << method }
      server.send_message('jsonrpc' => '2.0', 'method' => '$/progress')

      assert_equal '$/progress', seen.pop

      thread = Thread.new { connection.request('textDocument/definition') }
      server.reply(server.take, nil)
      assert_nil thread.value
    end
  end

  it 'raises ServerError with the code for a method the server refuses' do
    connect.call do |connection, server|
      thread = Thread.new { connection.request('textDocument/typeDefinition') }
      server.send_message('jsonrpc' => '2.0', 'id' => server.take['id'],
                          'error' => { 'code' => -32_601,
                                       'message' => 'Method not found: textDocument/typeDefinition' })

      error = assert_raises(Pikuri::Lsp::Connection::ServerError) { thread.value }
      assert_equal(-32_601, error.code)
      assert_includes error.message, 'Method not found'
      assert connection.alive?, 'a refused method must not kill the channel'
    end
  end

  it 'distinguishes an empty answer from a failure' do
    connect.call do |connection, server|
      empty = Thread.new { connection.request('textDocument/definition') }
      server.reply(server.take, [])

      assert_equal [], empty.value
    end
  end

  it 'ends a pending request when the server dies, and stays dead' do
    connect.call do |connection, server|
      thread = Thread.new { connection.request('textDocument/definition') }
      server.take
      server.close

      assert_raises(Pikuri::Lsp::Connection::Closed) { thread.value }
      refute connection.alive?
      assert_includes connection.dead_reason, 'EOF'
      assert_raises(Pikuri::Lsp::Connection::Closed) { connection.request('textDocument/hover') }
      assert_raises(Pikuri::Lsp::Connection::Closed) { connection.notify('exit') }
    end
  end

  it 'dies with a reason on a frame it cannot parse' do
    connect.call do |connection, server|
      server.send_raw('{"jsonrpc":')

      error = Thread.new do
        connection.request('initialize')
      rescue StandardError => e
        e
      end.value

      assert_kind_of Pikuri::Lsp::Connection::Closed, error
      assert_includes connection.dead_reason, 'JSON'
    end
  end

  it 'breaks a wait on cancellation instead of blocking forever' do
    connect.call do |connection, server|
      cancellable = Pikuri::Agent::Control::Cancellable.new
      thread = Thread.new { connection.request('workspace/symbol', {}, cancellable: cancellable) }
      server.take
      cancellable.cancel!

      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) { thread.value }
      assert connection.alive?, 'cancelling one call must not kill the channel'
    end
  end

  it 'blocks with no timeout while the server stays silent' do
    connect.call do |connection, server|
      thread = Thread.new { connection.request('textDocument/definition') }
      request = server.take
      sleep 0.3

      assert thread.alive?, 'no clock may end the wait — only an answer, a death, or a cancel'
      server.reply(request, [])
      assert_equal [], thread.value
    end
  end

  it 'sends a fire-and-forget request without waiting, and drops the late answer' do
    connect.call do |connection, server|
      id = connection.send_request('shutdown')
      connection.notify('exit')
      shutdown = server.take
      goodbye = server.take
      server.reply(shutdown, nil) # arrives with nobody waiting

      assert_equal ['shutdown', id], [shutdown['method'], shutdown['id']]
      assert_equal 'exit', goodbye['method'], 'ordering is the whole point of sending it synchronously'

      pending = Thread.new { connection.request('textDocument/hover') }
      server.reply(server.take, 'ok')
      assert_equal 'ok', pending.value, 'the dropped answer must not confuse the next one'
    end
  end

  it 'is idempotent to close' do
    connect.call do |connection, _server|
      connection.close
      connection.close

      refute connection.alive?
      assert_equal 'closed by pikuri', connection.dead_reason
    end
  end
end
