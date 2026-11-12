# frozen_string_literal: true

require 'json'

describe Pikuri::Lsp::Location do
  # Shaped after the recorded replies in design/architecture.md §Measurements: ruby-lsp
  # answers LocationLink (F_two_location_shapes), jdtls answers a jdt: URI (J_library_is_not_a_file).
  link = JSON.parse(<<~JSON)
    { "targetUri": "file:///home/m/pikuri/pikuri-workspace/lib/pikuri/workspace/filesystem.rb",
      "targetRange":          { "start": { "line": 217, "character": 4 },
                                "end":   { "line": 231, "character": 7 } },
      "targetSelectionRange": { "start": { "line": 217, "character": 8 },
                                "end":   { "line": 217, "character": 24 } } }
  JSON
  plain = JSON.parse(<<~JSON)
    { "uri": "jdt://contents/slf4j-api-2.0.18.jar/org.slf4j/LoggerFactory.java?=demo/%5C/home%5C/m%5C/.m2",
      "range": { "start": { "line": 40, "character": 13 },
                 "end":   { "line": 40, "character": 26 } } }
  JSON

  describe '.from_wire' do
    it 'parses the LocationLink shape and keeps the identifier range' do
      location = described_class.from_wire(link)

      assert_equal 218, location.range.start.line
      assert_equal 5, location.range.start.column
      assert_equal 9, location.selection_range.start.column
      assert_equal location.selection_range, location.anchor
    end

    it 'parses the plain Location shape, where there is no identifier range' do
      location = described_class.from_wire(plain)

      assert_nil location.selection_range
      assert_equal location.range, location.anchor
      assert_equal 41, location.range.start.line
    end

    it 'raises on a hash that is neither shape' do
      assert_raises(KeyError) { described_class.from_wire({ 'uri' => 'file:///a.rb' }) }
    end
  end

  describe '.list_from_wire' do
    it 'normalizes the three shapes one method can answer with' do
      assert_equal [], described_class.list_from_wire(nil)
      assert_equal [], described_class.list_from_wire([])
      assert_equal 1, described_class.list_from_wire(link).size
      assert_equal 2, described_class.list_from_wire([link, plain]).size
    end

    it 'raises on a result that is not a location at all' do
      assert_raises(ArgumentError) { described_class.list_from_wire('nope') }
    end
  end

  describe 'the walked-path questions every consumer must ask' do
    it 'hands out a local path for a file: URI' do
      location = described_class.from_wire(link)

      assert location.file?
      assert_equal 'file', location.scheme
      assert_equal '/home/m/pikuri/pikuri-workspace/lib/pikuri/workspace/filesystem.rb', location.path
    end

    it 'refuses to invent a path for a jar-internal URI' do
      location = described_class.from_wire(plain)

      refute location.file?
      assert_nil location.path
      assert_equal 'jdt', location.scheme
    end
  end
end
