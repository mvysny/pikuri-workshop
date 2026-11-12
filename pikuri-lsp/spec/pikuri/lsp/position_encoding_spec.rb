# frozen_string_literal: true

describe Pikuri::Lsp::PositionEncoding do
  # 'é' is 2 UTF-8 bytes / 1 UTF-16 unit; '🎉' is 4 bytes / 2 units.
  line = 'x = "héllo🎉" # ok'
  utf8 = Pikuri::Lsp::PositionEncoding::UTF8
  utf16 = Pikuri::Lsp::PositionEncoding::UTF16
  utf32 = Pikuri::Lsp::PositionEncoding::UTF32

  describe '.offset_for' do
    it 'counts characters for utf-32' do
      assert_equal 0, described_class.offset_for(line, 1, utf32)
      assert_equal 11, described_class.offset_for(line, 12, utf32)
    end

    it 'counts bytes for utf-8, so the accent shifts everything after it' do
      assert_equal 5, described_class.offset_for(line, 6, utf8)   # up to '"'
      assert_equal 8, described_class.offset_for(line, 8, utf8)   # 'é' cost 2
      assert_equal 15, described_class.offset_for(line, 12, utf8) # '🎉' cost 4
    end

    it 'counts utf-16 units, so the emoji counts twice' do
      assert_equal 10, described_class.offset_for(line, 11, utf16) # before '🎉'
      assert_equal 12, described_class.offset_for(line, 12, utf16) # after it
    end

    it 'accepts a column one past the last character' do
      assert_equal line.length, described_class.offset_for(line, line.length + 1, utf32)
    end

    it 'raises on a column pikuri could not have derived from that line' do
      assert_raises(ArgumentError) { described_class.offset_for(line, line.length + 2, utf16) }
      assert_raises(ArgumentError) { described_class.offset_for(line, 0, utf16) }
    end

    it 'raises on an unknown encoding' do
      assert_raises(ArgumentError) { described_class.offset_for(line, 1, 'utf-7') }
    end
  end

  describe '.column_for' do
    it 'round-trips every encoding at every column' do
      [utf8, utf16, utf32].each do |encoding|
        (1..(line.length + 1)).each do |column|
          offset = described_class.offset_for(line, column, encoding)
          assert_equal column, described_class.column_for(line, offset, encoding),
                       "#{encoding} column #{column}"
        end
      end
    end

    it 'reads the offset as a character count when the line text is unknown' do
      assert_equal 13, described_class.column_for(nil, 12, utf16)
    end

    it 'clamps an offset past the end of the line instead of raising' do
      assert_equal line.length + 1, described_class.column_for(line, 999, utf16)
      assert_equal line.length + 1, described_class.column_for(line, 999, utf8)
    end

    it 'raises on a negative offset' do
      assert_raises(ArgumentError) { described_class.column_for(line, -1, utf16) }
    end

    it 'raises on an unknown encoding even when the line text is unknown' do
      assert_raises(ArgumentError) { described_class.column_for(nil, 3, 'utf-7') }
    end
  end

  describe 'the encodings pikuri offers' do
    it 'leads with utf-8 and defaults to the utf-16 the spec defaults to' do
      assert_equal [utf8, utf16], described_class::OFFERED
      assert_equal utf16, described_class::DEFAULT
    end
  end
end
