# frozen_string_literal: true

require 'json'

# What the parse layer makes of bytes real servers sent. The fixtures and their
# provenance are spec/fixtures/README.md; each example names the finding it pins.
describe 'recorded server payloads' do
  parse = ->(name) { JSON.parse(fixture(name)) }

  describe 'ruby-lsp answering textDocument/definition (F_definition_candidates, F_two_location_shapes)' do
    locations = Pikuri::Lsp::Location.list_from_wire(parse.call('ruby_lsp_definition_location_link'))

    it 'parses the LocationLink shape it chose over plain Location' do
      assert_equal 2, locations.size, 'a definition answers candidates, not an answer'
      assert(locations.all? { |location| location.path.end_with?('workspace/filesystem.rb') })
    end

    it 'keeps the identifier range the link shape is worth having' do
      first = locations.first

      refute_nil first.selection_range
      assert_equal first.selection_range, first.anchor
      assert_equal 218, first.anchor.start.line, 'wire line 217, 1-based here'
      assert_equal 9, first.anchor.start.column
      assert_equal 232, first.range.end.line, 'the whole method body, not just its name'
    end
  end

  describe 'jdtls answering with a jar-internal URI (J_library_is_not_a_file, J_type_definition_recovers_var)' do
    location = Pikuri::Lsp::Location.list_from_wire(parse.call('jdtls_definition_jdt_uri')).first

    it 'refuses to pretend it is a file' do
      refute location.file?
      assert_nil location.path, 'nothing to denylist-check, nothing to read'
      assert_equal 'jdt', location.scheme
    end

    it 'is the length that makes rendering it raw indefensible' do
      assert_operator location.uri.length, :>, 250
      assert_includes location.uri, 'jrt-fs.jar'
    end
  end

  describe 'jdtls answering java/classFileContents (J_class_file_contents)' do
    it 'is a bare String, so nothing may assume the object the spec suggests' do
      contents = parse.call('jdtls_class_file_contents')

      assert_kind_of String, contents
      # A content reply must never pass for locations.
      assert_raises(ArgumentError) { Pikuri::Lsp::Location.list_from_wire(contents) }
      assert_includes contents, 'public final class LoggerFactory'
    end
  end

  describe 'ruby-lsp answering typeHierarchy/subtypes (H_subtypes_stub)' do
    it 'answers null, not [], from an advertised provider wired to a TODO' do
      result = parse.call('ruby_lsp_subtypes_null')

      assert_nil result, 'the capability gate cannot catch this: the provider is truthful for supertypes'
      assert_equal [], Pikuri::Lsp::Location.list_from_wire(result)
    end
  end

  describe 'ruby-lsp answering typeHierarchy/supertypes (H_namespace_reopenings)' do
    items = parse.call('ruby_lsp_supertypes')

    it 'is 14 rows carrying one fact, with the row a human wants ordered last' do
      assert_equal 14, items.size
      assert_equal ['Pikuri::Tool'], items.map { |item| item['name'] }.uniq
      assert items.last['uri'].end_with?('/pikuri-core/lib/pikuri/tool.rb'),
             'the real declaration, after 13 namespace reopenings'
    end

    it 'parses row by row, and every row is in-repo here' do
      locations = items.map { |item| Pikuri::Lsp::Location.from_wire(item) }

      assert(locations.all?(&:file?))
      assert_equal 35, locations.last.range.start.line, 'tool.rb:35, 1-based'
    end
  end

  describe 'ruby-lsp reporting a crashed didChange (S_rangeless_didchange_crash)' do
    it 'carries a raw Ruby backtrace as the error message, intact' do
      body = parse.call('ruby_lsp_invalid_location_error')
      error = Pikuri::Lsp::Connection::ServerError.new('textDocument/definition', body.fetch('error'))

      assert_equal(-32_602, error.code)
      assert_includes error.message, 'document.rb:98'
      assert_includes error.message, 'NonExistingDocumentError'
    end

    it 'reports the crash itself only through a log notification' do
      body = parse.call('ruby_lsp_log_message_didchange')

      assert_equal 'window/logMessage', body['method']
      assert_equal 1, body.dig('params', 'type'), 'type 1 is Error — the level the wrapper logs at'
      assert_includes body.dig('params', 'message'), 'Error processing textDocument/didChange'
    end
  end

  describe 'jdtls narrating a cold start (J_progress_opt_in, J_readiness_edge)' do
    frames = %w[jdtls_progress_begin jdtls_progress_report jdtls_progress_end].map { |name| parse.call(name) }

    it 'holds one long-lived token across begin, report and end' do
      tokens = frames.map { |frame| frame.dig('params', 'token') }

      assert_equal 1, tokens.uniq.size, 'the readiness edge is this token closing'
      assert_equal %w[begin report end], frames.map { |frame| frame.dig('params', 'value', 'kind') }
    end

    it 'names the task once and sends no percentage until it has one' do
      begun, reported, ended = frames.map { |frame| frame.dig('params', 'value') }

      assert_equal 'Initialize Workspace', begun['title']
      assert_nil begun['percentage'], 'a bar is not drawable yet — a spinner is'
      assert_equal 42, reported['percentage']
      assert_nil reported['title'], 'only begin carries it, so a consumer remembers per token'
      assert_nil ended['percentage']
    end
  end

  describe 'the two initialize results (F_capabilities_per_workspace, F_unadvertised_providers, J_progress_opt_in)' do
    ruby = parse.call('ruby_lsp_initialize_result').fetch('capabilities')
    java = parse.call('jdtls_initialize_result').fetch('capabilities')

    it 'disagree about the encoding, which is why the conversion is not optional' do
      assert_equal 'utf-8', ruby['positionEncoding']
      refute java.key?('positionEncoding'), 'jdtls ignored the offer and stayed on the 3.17 default'
    end

    it 'disagree about which operations exist at all' do
      %w[typeDefinitionProvider implementationProvider callHierarchyProvider declarationProvider].each do |absent|
        refute ruby.key?(absent), "#{absent} is absent from ruby-lsp in this workspace (F_unadvertised_providers)"
      end
      %w[typeDefinitionProvider implementationProvider callHierarchyProvider].each do |present|
        assert java[present], "#{present} is jdtls's to answer"
      end
      refute java.key?('declarationProvider'), 'neither server has it, which is why it is out of the enum'
    end

    it 'both advertise incremental sync, so a rangeless didChange was never ours to send' do
      assert_equal 2, ruby.dig('textDocumentSync', 'change')
      assert_equal 2, java.dig('textDocumentSync', 'change')
    end
  end
end
