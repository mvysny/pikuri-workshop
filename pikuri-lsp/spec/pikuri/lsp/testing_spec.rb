# frozen_string_literal: true

require 'timeout'

describe Pikuri::Lsp::Testing::FakeServer do
  died = Pikuri::Lsp::ClientWrapper::ServerDied
  entry = Pikuri::Lsp::Registry::StdioEntry.new(id: 'ruby', command: %w[ruby-lsp], files: %w[*.rb])

  # A real ClientWrapper against a serving fake. The block registers routes and
  # then drives the client from the example's own thread — the point of the fake
  # being that nothing has to be hand-answered.
  serving = lambda do |**kwargs, &block|
    server = described_class.new(**kwargs)
    client = Pikuri::Lsp::ClientWrapper.new(entry: entry, root: '/tmp/project', **server.channel)
    server.serve
    begin
      Timeout.timeout(10) { block.call(client, server) }
    ensure
      client.close
      server.stop
    end
  end

  it 'answers the handshake with no scripting at all' do
    serving.call(capabilities: { 'definitionProvider' => true },
                 server_info: { 'name' => 'fake-lsp', 'version' => '1.0' }) do |client, server|
      client.start

      assert client.supports?('definitionProvider')
      assert_equal 'fake-lsp', client.server_info['name']
      server.await('initialized')
      assert_equal %w[initialize initialized], server.received.map { |message| message['method'] }
    end
  end

  it 'replays a recorded initialize result byte-for-byte' do
    serving.call(initialize_result: fixture('ruby_lsp_initialize_result')) do |client, _server|
      client.start

      assert_equal 'utf-8', client.position_encoding, 'ruby-lsp accepts the utf-8 offer'
      assert client.supports?('typeHierarchyProvider'), 'advertised as {} — which is not false'
      refute client.supports?('typeDefinitionProvider'), 'absent in this workspace, per F_unadvertised_providers'
      refute client.supports?('callHierarchyProvider')
      assert_equal 'Ruby LSP', client.server_info['name']
    end
  end

  it 'replays the other server, which negotiates no encoding at all' do
    serving.call(initialize_result: fixture('jdtls_initialize_result')) do |client, _server|
      client.start

      assert_equal Pikuri::Lsp::PositionEncoding::DEFAULT, client.position_encoding
      assert client.supports?('typeDefinitionProvider'), 'the operation ruby-lsp lacks'
      assert client.supports?('implementationProvider')
    end
  end

  it 'routes a method to a block, and refuses what nothing routed' do
    serving.call(capabilities: { 'definitionProvider' => true }) do |client, server|
      server.on('textDocument/definition') { |params| [{ 'uri' => params['uri'], 'range' => nil }] }
      client.start

      assert_equal [{ 'uri' => 'file:///a.rb', 'range' => nil }],
                   client.request('textDocument/definition', { uri: 'file:///a.rb' })

      # What ruby-lsp really answers for an operation it never advertised.
      error = assert_raises(Pikuri::Lsp::Connection::ServerError) do
        client.request('textDocument/typeDefinition')
      end
      assert_equal(-32_601, error.code)
      assert_includes error.message, 'Method not found'
      assert client.alive?
    end
  end

  it 'puts recorded bytes on the wire untouched, including a bare-String result' do
    serving.call(capabilities: { 'definitionProvider' => true }) do |client, server|
      server.on_json('textDocument/definition') { fixture('jdtls_definition_jdt_uri') }
      server.on_json('java/classFileContents') { fixture('jdtls_class_file_contents') }
      client.start

      uri = client.request('textDocument/definition').first['uri']
      assert_equal JSON.parse(fixture('jdtls_definition_jdt_uri')).first['uri'], uri

      contents = client.request('java/classFileContents')
      assert_kind_of String, contents, 'J_class_file_contents: a bare String where the spec suggests an object'
      assert_includes contents, 'public final class LoggerFactory'
    end
  end

  it 'refuses on demand, with the code a real refusal carries' do
    serving.call do |client, server|
      server.refuse('textDocument/hover', code: -32_602, message: 'InvalidLocationError')
      client.start

      error = assert_raises(Pikuri::Lsp::Connection::ServerError) { client.request('textDocument/hover') }
      assert_equal(-32_602, error.code)
    end
  end

  it 'replays recorded notification frames, in the order the run recorded them' do
    serving.call do |client, server|
      seen = Queue.new
      client.on_notification { |method, params| seen << [method, params] }
      client.start

      %w[jdtls_progress_begin jdtls_progress_report jdtls_progress_end jdtls_language_status].each do |name|
        server.send_frame(fixture(name))
      end

      kinds = 3.times.map do
        method, params = seen.pop
        assert_equal '$/progress', method
        params.dig('value', 'kind')
      end
      assert_equal %w[begin report end], kinds

      method, params = seen.pop
      assert_equal 'language/status', method, 'J_progress_opt_in: the readiness signal outside the spec'
      assert_equal 'OK', params['message']
    end
  end

  it 'asks the client questions, which the client answers null' do
    serving.call do |client, server|
      client.start
      server.request('window/workDoneProgress/create', { 'token' => 'idx' }, id: 'srv-1')
      reply = server.await { |message| message['id'] == 'srv-1' && message.key?('result') }

      assert_nil reply['result']
    end
  end

  it 'crashes on demand, the way a child dies' do
    serving.call(capabilities: { 'definitionProvider' => true }) do |client, server|
      client.start
      server.crash!

      assert_raises(died) { client.request('textDocument/definition') }
      refute client.alive?
    end
  end

  it 'keeps every message the client sent, parsed, for after-the-fact assertions' do
    serving.call do |client, server|
      server.on('textDocument/definition') { [] }
      client.start
      client.notify('textDocument/didOpen', { textDocument: { uri: 'file:///a.rb', languageId: 'ruby' } })
      client.request('textDocument/definition')

      server.await('textDocument/definition')
      assert_equal %w[initialize initialized textDocument/didOpen textDocument/definition],
                   server.received.map { |message| message['method'] }
      assert_equal 'ruby', server.received[2].dig('params', 'textDocument', 'languageId')
    end
  end

  describe 'the asymmetry check the fake exists for' do
    it 'reads a position pikuri wrote back through pikuri, and agrees' do
      serving.call do |client, server|
        server.on('textDocument/definition') { [] }
        client.start
        line_text = '    workspace.resolve_for_read(path)'
        sent = Pikuri::Lsp::Position.new(line: 165, column: line_text.index('resolve_for_read') + 1)
        client.request('textDocument/definition',
                       { position: sent.to_wire(line_text: line_text, encoding: 'utf-8') })

        wire = server.await('textDocument/definition').dig('params', 'position')
        assert_equal 164, wire['line'], 'the wire is 0-based, whatever pikuri holds'
        assert_equal sent, Pikuri::Lsp::Position.from_wire(wire, line_text: line_text, encoding: 'utf-8')
      end
    end
  end
end
