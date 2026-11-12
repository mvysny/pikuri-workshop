# frozen_string_literal: true

describe Pikuri::Lsp::Position do
  utf8 = Pikuri::Lsp::PositionEncoding::UTF8
  utf16 = Pikuri::Lsp::PositionEncoding::UTF16
  # The line at pikuri-workspace/lib/pikuri/workspace/read.rb:165 (F_definition_candidates).
  text = '    workspace.resolve_for_read(path)'

  describe '.from_wire' do
    it 'moves both coordinates off zero' do
      position = described_class.from_wire({ 'line' => 164, 'character' => 14 },
                                          line_text: text, encoding: utf8)
      assert_equal 165, position.line
      assert_equal 15, position.column
      assert_equal 'resolve_for_read', text[position.column - 1, 16]
    end

    it 'raises when a wire field is missing rather than defaulting to zero' do
      assert_raises(KeyError) { described_class.from_wire({ 'line' => 3 }) }
    end
  end

  describe '#to_wire' do
    it 'is the inverse of .from_wire' do
      wire = { 'line' => 164, 'character' => 14 }
      position = described_class.from_wire(wire, line_text: text, encoding: utf8)
      assert_equal({ line: 164, character: 14 }, position.to_wire(line_text: text, encoding: utf8))
    end

    it 'defaults to the utf-16 a silent server means' do
      assert_equal({ line: 0, character: 3 },
                   described_class.new(line: 1, column: 4).to_wire(line_text: 'héllo'))
      assert_equal({ line: 0, character: 4 },
                   described_class.new(line: 1, column: 4).to_wire(line_text: 'héllo', encoding: utf8))
    end

    it 'raises when the column is past the end of the line it names' do
      assert_raises(ArgumentError) do
        described_class.new(line: 165, column: 999).to_wire(line_text: text, encoding: utf16)
      end
    end
  end

  it 'refuses a zero coordinate, the shape of an unconverted wire value' do
    assert_raises(ArgumentError) { described_class.new(line: 0, column: 1) }
    assert_raises(ArgumentError) { described_class.new(line: 1, column: 0) }
  end

  it 'renders as line:column' do
    assert_equal '165:15', described_class.new(line: 165, column: 15).to_s
  end
end
