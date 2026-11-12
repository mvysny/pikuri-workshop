# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'timeout'
require 'tmpdir'

describe Pikuri::Lsp::LspTool do
  testing = Pikuri::Lsp::Testing
  legs = Pikuri::Tool::TrifectaLegs

  # Everything ruby-lsp advertises in this repo, near enough: the examples that
  # care about a *missing* capability say which one they drop.
  all_capabilities = {
    'definitionProvider' => true, 'referencesProvider' => true, 'hoverProvider' => true,
    'documentSymbolProvider' => true, 'workspaceSymbolProvider' => true,
    'implementationProvider' => true, 'typeDefinitionProvider' => true,
    'callHierarchyProvider' => true, 'typeHierarchyProvider' => {},
    'positionEncoding' => 'utf-8'
  }.freeze

  ruby_server = ->(capabilities = all_capabilities) { { files: %w[*.rb], capabilities: capabilities } }

  # A workspace on disk, one fake server per registry entry, and the tool wired to
  # them. Routes are added *inside* the block: +FakeServer#on+ is thread-safe, so
  # an example scripts a server that is already serving, and the handshake is
  # answered for free.
  wired = lambda do |files: {}, servers: nil, filesystem: nil, settle: 0.05, &block|
    servers ||= { 'ruby' => ruby_server.call }
    Dir.mktmpdir do |tmp|
      files.each do |name, body|
        path = File.join(tmp, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      root = File.realpath(tmp)
      fs = filesystem ? filesystem.call(root) : Pikuri::Workspace::Filesystem.new(project_root: root)
      entries = servers.map do |id, spec|
        Pikuri::Lsp::Registry::StdioEntry.new(id: id, command: [id], files: spec[:files])
      end
      # The fakes are serving before the block runs — an example scripts one, or
      # pushes a notification at a client that has not connected yet, without
      # having to make a call first. The *clients* stay lazy, which is the
      # behaviour under test.
      fakes = servers.to_h do |id, spec|
        [id, testing::FakeServer.new(capabilities: spec[:capabilities] || {}).serve]
      end
      runtime = Pikuri::Lsp::Servers.new(
        registry: Pikuri::Lsp::Registry.new(entries: entries), root: root,
        spawn: lambda do |entry|
          Pikuri::Lsp::ClientWrapper.new(
            entry: entry, root: root, **fakes[entry.id].channel,
            readiness: Pikuri::Lsp::Readiness.new(server_id: entry.id, settle: settle)
          ).start
        end
      )
      begin
        tool = described_class.new(servers: runtime, filesystem: fs)
        Timeout.timeout(20) { block.call(tool, fakes, root, runtime) }
      ensure
        runtime.close
        fakes.each_value(&:stop)
      end
    end
  end

  wire_range = lambda do |line, from, to|
    { 'start' => { 'line' => line, 'character' => from }, 'end' => { 'line' => line, 'character' => to } }
  end

  # A plain +Location+, the shape a server without +linkSupport+ answers with.
  at = ->(uri, line, from = 0, to = 1) { { 'uri' => uri, 'range' => wire_range.call(line, from, to) } }

  read_rb = <<~RUBY_SOURCE
    # frozen_string_literal: true

    class Read
      def call(path)
        workspace.resolve_for_read(path)
      end
    end
  RUBY_SOURCE

  describe 'routing, and the three answers that must stay distinct' do
    it 'routes on the file and names the file type nothing claims' do
      wired.call(files: { 'README.md' => "# hi\n" }) do |tool|
        answer = tool.run('operation' => 'hover', 'symbol' => 'hi', 'file' => 'README.md', 'line' => 1).to_s

        assert_equal 'Error: no language server is configured for .md files', answer
      end
    end

    it 'refuses an operation this workspace\'s server does not advertise, naming the capability' do
      capabilities = all_capabilities.reject { |key, _| key == 'implementationProvider' }
      wired.call(files: { 'read.rb' => read_rb }, servers: { 'ruby' => ruby_server.call(capabilities) }) do |tool|
        answer = tool.run('operation' => 'goToImplementation', 'symbol' => 'call',
                          'file' => 'read.rb', 'line' => 4).to_s

        assert_match(/does not support goToImplementation/, answer)
        assert_match(/advertises no implementationProvider/, answer)
      end
    end

    it 'says the server answered nothing without claiming the symbol has nothing' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].on('textDocument/definition') { |_params| [] }

        answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'call',
                          'file' => 'read.rb', 'line' => 4).to_s

        assert_match(/answered no results/, answer)
        assert_match(/not proof that none exist/, answer)
        refute_match(/no definition/i, answer)
      end
    end

    it 'reports a server that died indexing as a death, not as an empty answer' do
      wired.call(files: { 'read.rb' => read_rb }, settle: 5) do |tool, fakes|
        fake = fakes['ruby']
        # Keyed off the handshake rather than a sleep: the client is spawned by
        # the call below, so the index must look busy *after* it connects and
        # die while the gate is still waiting. Awaited on +initialized+, not on
        # +initialize+: {FakeServer} records a message *before* it answers it, so
        # awaiting the request itself can crash the wire while the reply is still
        # unwritten — and the client then reports a death during *startup*, which
        # is the other answer this example exists to keep distinct. The client
        # sends +initialized+ only once that reply is in hand.
        Thread.new do
          fake.await('initialized')
          fake.notify('$/progress', 'token' => 'boot',
                                    'value' => { 'kind' => 'begin', 'title' => 'Indexing' })
          fake.crash!
        end

        answer = tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4).to_s

        assert_match(/died while its index was building/, answer)
      end
    end
  end

  describe 'the display line a chrome renders' do
    it 'is the acronym plus the operation and symbol, never the enum alone' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool|
        assert_equal 'LSP', tool.display_name
        assert_equal 'findReferences resolve_for_read',
                     tool.describe_call('operation' => 'findReferences', 'symbol' => 'resolve_for_read')
      end
    end

    it 'counts the rows the renderer kept' do
      wired.call(files: { 'a.rb' => "names = names.trim\n" }) do |tool, fakes, root|
        fakes['ruby'].on('textDocument/definition') { |_params| [at.call("file://#{root}/a.rb", 0)] }

        result = tool.run('operation' => 'goToDefinition', 'symbol' => 'names', 'file' => 'a.rb', 'line' => 1)

        assert_equal '1 result', result.summary
      end
    end

    it 'reports nothing found as a count, not as silence' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].on('textDocument/definition') { |_params| [] }

        result = tool.run('operation' => 'goToDefinition', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4)

        assert_equal '0 results', result.summary
      end
    end
  end

  describe 'the column the model is never asked for' do
    it 'derives it from the line\'s own text' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes, root|
        fakes['ruby'].on('textDocument/definition') { |_params| [] }

        tool.run('operation' => 'goToDefinition', 'symbol' => 'resolve_for_read',
                 'file' => 'read.rb', 'line' => 5)
        sent = fakes['ruby'].await('textDocument/definition')

        # "    workspace.resolve_for_read(path)" — 0-based line 4, and the offset of
        # the symbol itself rather than of the receiver or the indentation.
        assert_equal 4, sent.dig('params', 'position', 'line')
        assert_equal 14, sent.dig('params', 'position', 'character')
        assert_equal "file://#{root}/read.rb", sent.dig('params', 'textDocument', 'uri')
      end
    end

    it 'queries both occurrences on a line and collapses identical answers' do
      wired.call(files: { 'a.rb' => "names = names.trim\n" }) do |tool, fakes, root|
        fakes['ruby'].on('textDocument/definition') { |_params| [at.call("file://#{root}/a.rb", 0)] }

        answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'names',
                          'file' => 'a.rb', 'line' => 1).to_s
        sent = fakes['ruby'].received.select { |message| message['method'] == 'textDocument/definition' }

        assert_equal [0, 8], sent.map { |message| message.dig('params', 'position', 'character') }
        assert_equal 1, answer.scan('goToDefinition').length, 'identical answers collapse into one block'
      end
    end

    it 'labels the blocks by position when the two occurrences answer differently' do
      wired.call(files: { 'a.rb' => "names = names.trim\n" }) do |tool, fakes, root|
        fakes['ruby'].on('textDocument/definition') do |params|
          [at.call("file://#{root}/a.rb", params.dig('position', 'character'))]
        end

        answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'names',
                          'file' => 'a.rb', 'line' => 1).to_s

        assert_match(/At a\.rb:1:1/, answer)
        assert_match(/At a\.rb:1:9/, answer)
      end
    end

    it 'refuses a line the symbol is not on, and shows the line' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool|
        answer = tool.run('operation' => 'hover', 'symbol' => 'nope', 'file' => 'read.rb', 'line' => 4).to_s

        assert_equal 'Error: "nope" is not on line 4 of read.rb, which reads: "def call(path)"', answer
      end
    end

    it 'refuses a line past the end of the file' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool|
        answer = tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 99).to_s

        assert_match(/has 7 lines; line 99 was asked for/, answer)
      end
    end
  end

  describe 'a reply, an argument or a wiring pikuri did not expect' do
    it 'refuses a line below 1 instead of silently consulting the last line' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        answer = tool.run('operation' => 'hover', 'symbol' => 'end', 'file' => 'read.rb', 'line' => 0).to_s

        assert_equal 'Error: line must be 1-based, got 0', answer
        assert_empty fakes['ruby'].received.select { |message| message['method'] == 'textDocument/hover' }
      end
    end

    it 'relays a reply it cannot parse instead of dying on it' do
      [[{ 'foo' => 'bar' }], 'not a location at all',
       [{ 'uri' => 'file:///a.rb', 'range' => {} }]].each do |malformed|
        wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
          fakes['ruby'].on('textDocument/definition') { |_params| malformed }

          answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'call',
                            'file' => 'read.rb', 'line' => 4).to_s

          assert_match(/goToDefinition reply could not be read/, answer)
        end
      end
    end

    it 'anchors an index hit whose range is unusable by scanning the file' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes, root|
        fakes['ruby'].on('workspace/symbol') do |_params|
          # A newer server may answer with a bare {uri}; a malformed range is the
          # same case as far as anchoring goes.
          [{ 'name' => 'Read', 'kind' => 5, 'location' => { 'uri' => "file://#{root}/read.rb", 'range' => {} } }]
        end
        fakes['ruby'].on('textDocument/hover') { |_params| { 'contents' => 'scanned instead' } }

        answer = tool.run('operation' => 'hover', 'symbol' => 'Read').to_s
        sent = fakes['ruby'].await('textDocument/hover')

        assert_match(/scanned instead/, answer)
        assert_equal({ 'line' => 2, 'character' => 6 }, sent.dig('params', 'position'))
      end
    end

    it 'refuses a file outside the root even where the workspace would read it' do
      # AllowAll — the container wiring — resolves any path happily, so the
      # out-of-root refusal cannot lean on resolve_for_read raising. The boundary
      # that matters is the server's own rootUri.
      allow_all = ->(root) { Pikuri::Workspace::Filesystem::AllowAll.new(project_root: root) }
      wired.call(files: { 'read.rb' => read_rb }, filesystem: allow_all) do |tool, fakes|
        Dir.mktmpdir do |other|
          File.write(File.join(other, 'elsewhere.rb'), "def call(path)\n")

          answer = tool.run('operation' => 'hover', 'symbol' => 'call',
                            'file' => File.join(File.realpath(other), 'elsewhere.rb'), 'line' => 1)

          assert_match(/is outside the workspace root the language servers index/, answer.content)
          assert_empty fakes['ruby'].received.select { |message| message['method'] == 'textDocument/didOpen' }
        end
      end
    end

    it 'takes a bare String hover reply, which is not the shape the spec suggests' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].on('textDocument/hover') { |_params| 'a bare string' }

        answer = tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4).to_s

        assert_match(/a bare string/, answer)
      end
    end
  end

  describe 'document synchronization' do
    it 're-sends didOpen with the text on disk before every call' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes, root|
        fakes['ruby'].on('textDocument/hover') { |_params| { 'contents' => 'x' } }

        tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4)
        File.write(File.join(root, 'read.rb'), "class Read\n  def call(path); end\nend\n")
        tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 2)

        opens = fakes['ruby'].received.select { |message| message['method'] == 'textDocument/didOpen' }
        assert_equal 2, opens.length, 'no open-URI set: the document is re-announced every call'
        assert_equal 'ruby', opens.first.dig('params', 'textDocument', 'languageId')
        assert_match(/resolve_for_read/, opens.first.dig('params', 'textDocument', 'text'))
        refute_match(/resolve_for_read/, opens.last.dig('params', 'textDocument', 'text'))
        assert_empty fakes['ruby'].received.select { |message| message['method'] == 'textDocument/didChange' }
      end
    end

    # The spec caps a document's open count at one and wants the pair, so the
    # close is owed rather than measured. What the order proves is the *timing*:
    # a server free to answer requests concurrently must not see the close before
    # the request it brackets.
    it 'closes the document it opened, after the reply and not before' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].on('textDocument/hover') { |_params| { 'contents' => 'x' } }

        tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4)
        fakes['ruby'].await('textDocument/didClose')

        lifecycle = fakes['ruby'].received.map { |message| message['method'] }
                                .grep(%r{^textDocument/})
        assert_equal %w[textDocument/didOpen textDocument/hover textDocument/didClose], lifecycle
      end
    end

    # Closing per *request* would hand the per-level walk a document the server
    # had already dropped, so the pair brackets the whole call.
    it 'opens and closes once for a call that asks several questions' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes, root|
        uri = "file://#{root}/read.rb"
        item = ->(name) { { 'name' => name, 'kind' => 5, 'uri' => uri, 'range' => wire_range.call(2, 0, 5) } }
        fakes['ruby'].on('textDocument/prepareTypeHierarchy') { |_params| [item.call('Read')] }
        fakes['ruby'].on('typeHierarchy/supertypes') { |_params| [item.call('Object')] }

        tool.run('operation' => 'supertypes', 'symbol' => 'Read', 'file' => 'read.rb', 'line' => 3)
        fakes['ruby'].await('textDocument/didClose')

        methods = fakes['ruby'].received.map { |message| message['method'] }
        assert_equal 1, methods.count('textDocument/didOpen')
        assert_equal 1, methods.count('textDocument/didClose')
        assert_operator methods.index('textDocument/didClose'), :>,
                        methods.rindex('typeHierarchy/supertypes'),
                        'the close must follow the last request against the document'
      end
    end

    it 'still gives the document back when the server refuses the request' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].refuse('textDocument/hover')

        answer = tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4).to_s

        assert_match(/^Error: /, answer)
        refute_nil fakes['ruby'].await('textDocument/didClose'), 'the ensure owes the close either way'
      end
    end

    it 'sends the real file under a workspace that aliases /tmp to its playground' do
      # bin/pikuri-code wires alias_tmp_to_temp whenever the sandbox is on, and
      # a spec root lives under /tmp — so resolving the *resolved* path a second
      # time rewrote it into the agent's empty playground. The document the
      # server indexes has to be the one on disk.
      aliasing = lambda do |root|
        Pikuri::Workspace::Filesystem.new(project_root: root, temp: true, alias_tmp_to_temp: true)
      end
      wired.call(files: { 'read.rb' => read_rb }, filesystem: aliasing) do |tool, fakes|
        fakes['ruby'].on('textDocument/hover') { |_params| { 'contents' => 'x' } }

        tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4)

        opened = fakes['ruby'].received.find { |message| message['method'] == 'textDocument/didOpen' }
        assert_equal read_rb, opened.dig('params', 'textDocument', 'text')
      end
    end
  end

  describe 'a bare name, resolved through the index' do
    it 'compares the last segment, because a server reports the qualified name' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes, root|
        uri = "file://#{root}/read.rb"
        fakes['ruby'].on('workspace/symbol') do |_params|
          [{ 'name' => 'Pikuri::Workspace::Read', 'kind' => 5,
             'location' => at.call(uri, 2, 0, 10) },
           { 'name' => '@confirmer', 'kind' => 8, 'location' => at.call(uri, 3) }]
        end
        fakes['ruby'].on('textDocument/hover') { |_params| { 'contents' => 'the Read tool' } }

        answer = tool.run('operation' => 'hover', 'symbol' => 'Read').to_s
        sent = fakes['ruby'].await('textDocument/hover')

        assert_match(/the Read tool/, answer)
        # The index reported the keyword column (0, i.e. `class`); the anchor is
        # the symbol's own column, located in the line's text.
        assert_equal({ 'line' => 2, 'character' => 6 }, sent.dig('params', 'position'))
      end
    end

    it 'drops a match outside the workspace and refuses when none is left' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].on('workspace/symbol') do |_params|
          [{ 'name' => 'Read', 'kind' => 5,
             'location' => at.call('file:///elsewhere/gems/pikuri-0.0.6/read.rb', 2) }]
        end

        answer = tool.run('operation' => 'hover', 'symbol' => 'Read').to_s

        assert_match(/no index match can anchor a query/, answer)
        assert_match(/is outside the workspace \(read\.rb\)/, answer)
      end
    end

    it 'says honestly when the index has no entry for the name' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].on('workspace/symbol') { |_params| [] }

        answer = tool.run('operation' => 'hover', 'symbol' => 'Confirmer').to_s

        assert_match(/is not in any server's index/, answer)
        assert_match(/Pass file: \(and line:\)/, answer)
      end
    end

    it 'does not ask a server that cannot search by name, and scans instead' do
      capabilities = all_capabilities.reject { |key, _| key == 'workspaceSymbolProvider' }
      servers = { 'ruby' => ruby_server.call(capabilities) }
      wired.call(files: { 'read.rb' => read_rb }, servers: servers) do |tool, fakes|
        fakes['ruby'].on('textDocument/hover') { |_params| { 'contents' => 'scanned' } }

        answer = tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb').to_s

        assert_match(/scanned/, answer)
        assert_empty fakes['ruby'].received.select { |message| message['method'] == 'workspace/symbol' }
      end
    end

    it 'falls back to scanning a named file the index has no entry for' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].on('workspace/symbol') { |_params| [] }
        fakes['ruby'].on('textDocument/hover') { |_params| { 'contents' => 'found anyway' } }

        answer = tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb').to_s

        assert_match(/found anyway/, answer)
        assert_match(/anchored on line 4, the first occurrence/, answer)
      end
    end
  end

  describe 'fan-out' do
    it 'asks every server that can search by name and labels the blocks' do
      servers = { 'ruby' => ruby_server.call,
                  'java' => { files: %w[*.java], capabilities: all_capabilities } }
      files = { 'a.rb' => "class A\n", 'B.java' => "class B {}\n" }
      wired.call(files: files, servers: servers) do |tool, fakes, root|
        fakes['ruby'].on('workspace/symbol') do |_params|
          [{ 'name' => 'Same', 'kind' => 5, 'location' => at.call("file://#{root}/a.rb", 0) }]
        end
        fakes['java'].on('workspace/symbol') do |_params|
          [{ 'name' => 'Same', 'kind' => 5, 'location' => at.call("file://#{root}/B.java", 0) }]
        end

        answer = tool.run('operation' => 'workspaceSymbol', 'symbol' => 'Same').to_s

        assert_match(/From the ruby server:/, answer)
        assert_match(/From the java server:/, answer)
        assert_match(%r{a\.rb:1}, answer)
        assert_match(/B\.java:1/, answer)
      end
    end

    it 'notes the server that cannot answer instead of failing the whole call' do
      capabilities = all_capabilities.reject { |key, _| key == 'workspaceSymbolProvider' }
      servers = { 'ruby' => ruby_server.call,
                  'java' => { files: %w[*.java], capabilities: capabilities } }
      files = { 'a.rb' => "class A\n", 'B.java' => "class B {}\n" }
      wired.call(files: files, servers: servers) do |tool, fakes, root|
        fakes['ruby'].on('workspace/symbol') do |_params|
          [{ 'name' => 'A', 'kind' => 5, 'location' => at.call("file://#{root}/a.rb", 0) }]
        end

        answer = tool.run('operation' => 'workspaceSymbol', 'symbol' => 'A').to_s

        assert_match(/the java server does not support workspaceSymbol/, answer)
        assert_match(%r{a\.rb:1}, answer)
      end
    end
  end

  describe 'lazy start' do
    it 'starts no server until a call needs one, and then only the claiming one' do
      servers = { 'ruby' => ruby_server.call,
                  'java' => { files: %w[*.java], capabilities: all_capabilities } }
      files = { 'read.rb' => read_rb, 'B.java' => "class B {}\n" }
      wired.call(files: files, servers: servers) do |tool, fakes, root, runtime|
        assert_empty runtime.started_ids, 'wiring the tool must not spawn anything'

        fakes['ruby'].on('textDocument/definition') { |_params| at.call("file://#{root}/read.rb", 2) }
        tool.run('operation' => 'goToDefinition', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4)

        assert_equal %w[ruby], runtime.started_ids
      end
    end

    it 'never starts a server for a language this project has no files in' do
      servers = { 'ruby' => ruby_server.call,
                  'java' => { files: %w[*.java], capabilities: all_capabilities } }
      wired.call(files: { 'a.rb' => "class A\n" }, servers: servers) do |tool, fakes, root, runtime|
        fakes['ruby'].on('workspace/symbol') do |_params|
          [{ 'name' => 'A', 'kind' => 5, 'location' => at.call("file://#{root}/a.rb", 0) }]
        end

        answer = tool.run('operation' => 'workspaceSymbol', 'symbol' => 'A').to_s

        assert_equal %w[ruby], runtime.started_ids
        refute_match(/java/, answer, 'a server with nothing to say here is not mentioned')
        assert_match(%r{a\.rb:1}, answer)
      end
    end

    it 'says which servers are configured when none of them has files here' do
      wired.call(files: { 'README.md' => "# hi\n" }) do |tool, _fakes, _root, runtime|
        answer = tool.run('operation' => 'workspaceSymbol', 'symbol' => 'A').to_s

        assert_match(/no configured language server has files in this project/, answer)
        assert_match(/configured: ruby/, answer)
        assert_empty runtime.started_ids
      end
    end
  end

  describe 'the readiness gate' do
    it 'blocks the first call until the index is built, emitting progress meanwhile' do
      wired.call(files: { 'read.rb' => read_rb }, settle: 0.4) do |tool, fakes|
        fake = fakes['ruby']
        fake.on('textDocument/hover') { |_params| { 'contents' => 'answered late' } }
        fake.notify('$/progress', 'token' => 'boot',
                                  'value' => { 'kind' => 'begin', 'title' => 'Indexing', 'percentage' => 10 })
        sleep 0.15
        seen = []
        tool.on_progress = ->(progress) { seen << progress }

        call = Thread.new do
          tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4).to_s
        end
        sleep 0.2
        assert_nil fake.received.find { |message| message['method'] == 'textDocument/hover' },
                   'nothing may be asked of a server that is still indexing'
        fake.notify('$/progress', 'token' => 'boot', 'value' => { 'kind' => 'end' })

        assert_match(/answered late/, call.value)
        assert_equal ['Indexing'], seen.map(&:title).uniq
        assert_equal ['ruby'], seen.map(&:server_id).uniq
        assert seen.last.done, 'a host that drew a bar must be told to take it down'
      end
    end
  end

  describe 'volume' do
    it 'splits references into source and tests, and caps the tests group' do
      files = { 'read.rb' => read_rb }
      12.times { |index| files["spec/read_#{index}_spec.rb"] = "# spec #{index}\n" }
      wired.call(files: files) do |tool, fakes, root|
        fakes['ruby'].on('textDocument/references') do |_params|
          [at.call("file://#{root}/read.rb", 4, 14, 30),
           *12.times.map { |index| at.call("file://#{root}/spec/read_#{index}_spec.rb", 0) }]
        end

        answer = tool.run('operation' => 'findReferences', 'symbol' => 'resolve_for_read',
                          'file' => 'read.rb', 'line' => 5).to_s

        assert_match(/findReferences "resolve_for_read" — 13 results/, answer)
        assert_match(/In source \(1\):/, answer)
        assert_match(/In tests \(12, showing 5\):/, answer)
        assert_equal 5, answer.scan(/_spec\.rb:1/).length
      end
    end

    # Two references on one line, differing only in the column pikuri never
    # prints (E_same_line_references) — so deduping on Location identity would
    # leave both rows standing.
    it 'collapses two results on one line, which render as the same row' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes, root|
        fakes['ruby'].on('textDocument/references') do |_params|
          [at.call("file://#{root}/read.rb", 4, 8, 24), at.call("file://#{root}/read.rb", 4, 30, 46)]
        end

        answer = tool.run('operation' => 'findReferences', 'symbol' => 'resolve_for_read',
                          'file' => 'read.rb', 'line' => 5).to_s

        assert_match(/findReferences "resolve_for_read" — 1 result$/, answer.lines.first.chomp)
        assert_equal 1, answer.scan(/read\.rb:5/).length, 'one row, not two identical ones'
      end
    end

    it 'includes the declaration in a references answer' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes, root|
        fakes['ruby'].on('textDocument/references') { |_params| [at.call("file://#{root}/read.rb", 3)] }

        tool.run('operation' => 'findReferences', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4)

        sent = fakes['ruby'].await('textDocument/references')
        assert_equal true, sent.dig('params', 'context', 'includeDeclaration')
      end
    end

    it 'caps a hover reply rather than pasting a whole class comment' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].on('textDocument/hover') do |_params|
          { 'contents' => { 'kind' => 'markdown', 'value' => "line\n" * 4000 } }
        end

        answer = tool.run('operation' => 'hover', 'symbol' => 'call', 'file' => 'read.rb', 'line' => 4).to_s

        assert answer.bytesize < Pikuri::Lsp::Renderer::MAX_HOVER_BYTES + 500
        assert_match(/bytes omitted/, answer)
      end
    end
  end

  describe 'the two collapsed hops' do
    it 'runs prepareCallHierarchy inside the tool and never shows the item' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes, root|
        uri = "file://#{root}/read.rb"
        item = { 'name' => 'call', 'kind' => 6, 'uri' => uri,
                 'range' => wire_range.call(3, 2, 20), 'selectionRange' => wire_range.call(3, 6, 10) }
        fakes['ruby'].on('textDocument/prepareCallHierarchy') { |_params| [item, item.merge('name' => 'other')] }
        fakes['ruby'].on('callHierarchy/incomingCalls') do |params|
          [{ 'from' => params.dig('item').merge('name' => 'caller_of_call', 'kind' => 6),
             'fromRanges' => [wire_range.call(4, 4, 8)] }]
        end

        answer = tool.run('operation' => 'incomingCalls', 'symbol' => 'call',
                          'file' => 'read.rb', 'line' => 4).to_s
        asked = fakes['ruby'].received.map { |message| message['method'] }

        assert_includes asked, 'textDocument/prepareCallHierarchy'
        assert_match(/incomingCalls "call" — 1 caller/, answer)
        assert_match(/method caller_of_call/, answer)
        # Exactly one prepared item matched the name, so the other was not queried.
        assert_equal 1, asked.count('callHierarchy/incomingCalls')
      end
    end

    it 'walks the ancestor chain and collapses a reopened namespace to its declaration' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes, root|
        uri = "file://#{root}/read.rb"
        fakes['ruby'].on('textDocument/prepareTypeHierarchy') do |_params|
          [{ 'name' => 'Read', 'kind' => 5, 'uri' => uri,
             'range' => wire_range.call(2, 0, 10), 'selectionRange' => wire_range.call(2, 6, 10) }]
        end
        levels = 0
        fakes['ruby'].on_json('typeHierarchy/supertypes') do |_params|
          levels += 1
          levels == 1 ? fixture('ruby_lsp_supertypes') : 'null'
        end

        answer = tool.run('operation' => 'supertypes', 'symbol' => 'Read',
                          'file' => 'read.rb', 'line' => 3).to_s

        assert_match(/supertypes "Read" — 1 level/, answer)
        assert_match(/1\. Pikuri::Tool/, answer)
        assert_match(/outside the workspace: tool\.rb/, answer, 'the declaration, not a namespace reopening')
        assert_match(/\+13 more files declare this name/, answer)
      end
    end

    it 'accepts nil from a hierarchy reply' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes, root|
        fakes['ruby'].on('textDocument/prepareTypeHierarchy') do |_params|
          [{ 'name' => 'Read', 'kind' => 5, 'uri' => "file://#{root}/read.rb",
             'range' => wire_range.call(2, 0, 10), 'selectionRange' => wire_range.call(2, 6, 10) }]
        end
        fakes['ruby'].on('typeHierarchy/supertypes') { |_params| nil }

        answer = tool.run('operation' => 'supertypes', 'symbol' => 'Read',
                          'file' => 'read.rb', 'line' => 3).to_s

        assert_match(/answered no results for supertypes/, answer)
      end
    end
  end

  describe 'results the model cannot open' do
    java_capabilities = all_capabilities.merge('positionEncoding' => nil)
    jdt_uri = 'jdt://contents/slf4j-api-2.0.18.jar/org.slf4j/LoggerFactory.java?=app/%5C/home%5C/lib'

    it 'reads a server-private URI through the one hardcoded row and names it readably' do
      servers = { 'java' => { files: %w[*.java], capabilities: java_capabilities } }
      wired.call(files: { 'Main.java' => "class Main { LoggerFactory f; }\n" }, servers: servers) do |tool, fakes|
        fakes['java'].on('textDocument/definition') { |_params| [at.call(jdt_uri, 1, 0, 5)] }
        # J_class_file_contents: this request answers a bare String, where the 3.18 request answers {text:}.
        fakes['java'].on('java/classFileContents') { |_params| "package org.slf4j;\npublic class LoggerFactory {\n" }

        answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'LoggerFactory',
                          'file' => 'Main.java', 'line' => 1).to_s

        assert_match(/org\.slf4j\.LoggerFactory \(slf4j-api-2\.0\.18\.jar\):2/, answer)
        assert_match(/public class LoggerFactory/, answer)
        refute_match(/jdt:/, answer, 'a 300-character classpath handle is never shown')
      end
    end

    it 'prefers the standard content request when a server advertises it' do
      capabilities = java_capabilities.merge(
        'workspace' => { 'textDocumentContent' => { 'schemes' => %w[jdt] } }
      )
      servers = { 'java' => { files: %w[*.java], capabilities: capabilities } }
      wired.call(files: { 'Main.java' => "class Main {}\n" }, servers: servers) do |tool, fakes|
        fakes['java'].on('textDocument/definition') { |_params| [at.call(jdt_uri, 0, 0, 5)] }
        fakes['java'].on('workspace/textDocumentContent') { |_params| { 'text' => "the standard reply\n" } }

        answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'Main',
                          'file' => 'Main.java', 'line' => 1).to_s

        assert_match(/the standard reply/, answer)
        assert_empty fakes['java'].received.select { |m| m['method'] == 'java/classFileContents' }
      end
    end

    it 'degrades to an inline reason when the content request is refused' do
      servers = { 'java' => { files: %w[*.java], capabilities: java_capabilities } }
      wired.call(files: { 'Main.java' => "class Main {}\n" }, servers: servers) do |tool, fakes|
        fakes['java'].on('textDocument/definition') { |_params| [at.call(jdt_uri, 0, 0, 5)] }
        fakes['java'].refuse('java/classFileContents')

        answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'Main',
                          'file' => 'Main.java', 'line' => 1).to_s

        assert_match(/\[the server would not read this jdt: URI/, answer)
        assert_match(/org\.slf4j\.LoggerFactory/, answer, 'the row survives its missing snippet')
      end
    end

    it 'reports an unknown scheme rather than a bare count' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].on('textDocument/definition') { |_params| [at.call('zipfile:///g.zip::a.rb', 0)] }

        answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'call',
                          'file' => 'read.rb', 'line' => 4).to_s

        assert_match(/need LSP 3\.18 content support, which it does not advertise/, answer)
      end
    end

    it 'never dereferences an http URI' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        fakes['ruby'].on('textDocument/definition') do |_params|
          [at.call('https://attacker.example/leak?ctx=secret', 0)]
        end

        answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'call',
                          'file' => 'read.rb', 'line' => 4).to_s

        assert_match(%r{https://attacker\.example/leak\?ctx=secret}, answer)
        assert_match(/never fetches a remote URI/, answer)
      end
    end

    it 'renders the real path when this workspace would read the file' do
      # AllowAll — the --yolo and OS-agent wirings — opens a gem checkout happily,
      # so suppressing the path would delete a capability the wiring granted.
      allow_all = ->(root) { Pikuri::Workspace::Filesystem::AllowAll.new(project_root: root) }
      wired.call(files: { 'read.rb' => read_rb }, filesystem: allow_all) do |tool, fakes|
        Dir.mktmpdir do |other|
          elsewhere = File.join(File.realpath(other), 'filesystem.rb')
          File.write(elsewhere, "def resolve_for_read(path)\n")
          fakes['ruby'].on('textDocument/definition') { |_params| [at.call("file://#{elsewhere}", 0)] }

          answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'call',
                            'file' => 'read.rb', 'line' => 4).to_s

          assert_match(/#{Regexp.escape(elsewhere)}:1  def resolve_for_read/, answer)
          refute_match(/outside the workspace/, answer)
        end
      end
    end

    it 'renders an out-of-root file result without a path this workspace would refuse' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        Dir.mktmpdir do |other|
          File.write(File.join(other, 'filesystem.rb'), "def resolve_for_read(path)\n")
          fakes['ruby'].on('textDocument/definition') do |_params|
            [at.call("file://#{File.realpath(other)}/filesystem.rb", 0)]
          end

          answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'call',
                            'file' => 'read.rb', 'line' => 4).to_s

          assert_match(/outside the workspace: filesystem\.rb:1  def resolve_for_read/, answer)
          refute_match(/#{Regexp.escape(other)}/, answer)
        end
      end
    end
  end

  describe 'the walked-path denylist' do
    it 'drops a result the filesystem denies' do
      # The seam, stubbed at exactly one method: a scoped Filesystem answers
      # +denied?+ +false+ for everything, so the pass it guards is the container
      # wiring's — and this is the shape of what it drops there.
      denying = Class.new do
        def initialize(filesystem) = @filesystem = filesystem
        def denied?(path) = path.to_s.include?('secrets')
        def project_root = @filesystem.project_root
        def resolve_for_read(path) = @filesystem.resolve_for_read(path)
        def private? = @filesystem.private?
      end
      builder = ->(root) { denying.new(Pikuri::Workspace::Filesystem.new(project_root: root)) }

      wired.call(files: { 'read.rb' => read_rb, 'secrets.rb' => "KEY = 'x'\n" },
                 filesystem: builder) do |tool, fakes, root|
        fakes['ruby'].on('textDocument/definition') do |_params|
          [at.call("file://#{root}/secrets.rb", 0), at.call("file://#{root}/read.rb", 3)]
        end

        answer = tool.run('operation' => 'goToDefinition', 'symbol' => 'call',
                          'file' => 'read.rb', 'line' => 4).to_s

        refute_match(/secrets/, answer)
        assert_match(/read\.rb:4/, answer)
      end
    end
  end

  describe 'the tool surface' do
    it 'validates the operation enum before anything is spawned at' do
      wired.call(files: { 'read.rb' => read_rb }) do |tool, fakes|
        answer = tool.run('operation' => 'rename', 'symbol' => 'call').to_s

        assert_match(/Error:/, answer)
        assert_empty fakes['ruby'].received.reject { |m| %w[initialize initialized].include?(m['method']) }
      end
    end

    it 'lists every operation in its description, from the enum itself' do
      wired.call(files: {}) do |tool|
        Pikuri::Lsp::Operation.names.each { |name| assert_match(/- #{name} —/, tool.description) }
        assert_equal Pikuri::Lsp::Operation.names, tool.parameters.to_openai.dig(:properties, :operation, :enum)
      end
    end

    it 'declares hard untrusted even on a trusted checkout, and no egress' do
      trusted = ->(root) { Pikuri::Workspace::Filesystem.new(project_root: root, trusted: true, private: true) }
      wired.call(files: {}, filesystem: trusted) do |tool|
        assert_equal :hard, tool.trifecta_legs.untrusted,
                     'a trusted checkout says nothing about the jars its build resolved'
        assert_equal :no_egress, tool.trifecta_legs.egress_payload_review
        assert_equal :no_egress, tool.trifecta_legs.egress_destination
        assert_equal true, tool.trifecta_legs.private, 'private rides the workspace, never a claim of its own'
        refute_equal legs::ASSUMED, tool.trifecta_legs
      end
    end
  end
end
