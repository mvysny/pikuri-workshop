# frozen_string_literal: true

describe Pikuri::Lsp::Range do
  utf16 = Pikuri::Lsp::PositionEncoding::UTF16
  text = "# 🎉🎉 a comment\n  def resolve_for_read(path)\n"
  wire = { 'start' => { 'line' => 1, 'character' => 6 },
           'end' => { 'line' => 1, 'character' => 22 } }

  it 'converts each end against its own line of the document' do
    range = described_class.from_wire(wire, text: text, encoding: utf16)

    assert_equal 2, range.start.line
    assert_equal 7, range.start.column
    assert_equal 23, range.end.column
    assert_equal 'resolve_for_read', text.lines[1][(range.start.column - 1)...(range.end.column - 1)]
  end

  it 'counts a surrogate pair as one column on the line that holds it' do
    range = described_class.from_wire({ 'start' => { 'line' => 0, 'character' => 2 },
                                       'end' => { 'line' => 0, 'character' => 6 } },
                                     text: text, encoding: utf16)

    assert_equal 3, range.start.column
    assert_equal 5, range.end.column
    assert_equal '🎉🎉', text.lines[0][(range.start.column - 1)...(range.end.column - 1)]
  end

  it 'reads offsets as character counts when the document text is unavailable' do
    range = described_class.from_wire(wire)

    assert_equal 7, range.start.column
    assert_equal 23, range.end.column
  end

  it 'knows whether one snippet line can show all of it' do
    assert described_class.from_wire(wire).single_line?
    refute described_class.from_wire({ 'start' => { 'line' => 1, 'character' => 0 },
                                       'end' => { 'line' => 9, 'character' => 3 } }).single_line?
  end

  it 'raises on a half range rather than inventing an end' do
    assert_raises(KeyError) { described_class.from_wire({ 'start' => wire['start'] }) }
  end

  it 'renders as start-end' do
    assert_equal '2:7-2:23', described_class.from_wire(wire).to_s
  end
end
