# frozen_string_literal: true

module Pikuri
  module Lsp
    # LSP's +positionEncoding+ values and the offset arithmetic each one
    # implies. A column is a *character* index inside pikuri and a code-unit
    # offset on the wire; column 12 of the same line is three different numbers
    # depending on who is asking:
    #
    #   line = 'x = "héllo🎉"'                        # 'é' is 2 bytes, '🎉' is 4
    #   PositionEncoding.offset_for(line, 12, UTF32)  # => 11  (just 0-based)
    #   PositionEncoding.offset_for(line, 12, UTF16)  # => 12  (the emoji counts twice)
    #   PositionEncoding.offset_for(line, 12, UTF8)   # => 15
    #   PositionEncoding.column_for(line, 12, UTF16)  # => 12  (round-trips)
    #
    # Converting in the wrong direction, or not at all, yields a *plausible*
    # column — so the server answers confidently about the wrong token instead
    # of failing. {DEFAULT} is what a server that negotiates nothing means.
    module PositionEncoding
      # Offsets count UTF-8 bytes. ruby-lsp accepts pikuri's offer of this.
      UTF8 = 'utf-8'

      # Offsets count UTF-16 code units, so an astral character (emoji, rare
      # CJK) counts twice. jdtls ignores the offer and stays here.
      UTF16 = 'utf-16'

      # Offsets count codepoints, i.e. exactly pikuri's own columns.
      UTF32 = 'utf-32'

      # What a server that answers no +positionEncoding+ means: UTF-16 is the
      # 3.17 default, and the conversion is therefore mandatory code rather
      # than a fallback for a hypothetical server.
      DEFAULT = UTF16

      # Encodings pikuri offers in +general.positionEncodings+, best first.
      # UTF-32 is out: no measured server offers it, and it would be one more
      # branch nothing exercises.
      OFFERED = [UTF8, UTF16].freeze

      # Every value a caller may pass.
      SUPPORTED = [UTF8, UTF16, UTF32].freeze

      module_function

      # Wire offset for a 1-based character column on +line_text+.
      #
      #   offset_for('def résolve', 8, UTF8)   # => 8  ("def rés" is 8 bytes)
      #
      # @param line_text [String] the line the column points into; a trailing
      #   newline is harmless.
      # @param column [Integer] 1-based character column, as {Position} holds it.
      # @param encoding [String] one of {SUPPORTED}.
      # @return [Integer] 0-based offset in that encoding's code units.
      # @raise [ArgumentError] if +column+ is below 1, points past the end of
      #   +line_text+ (pikuri derived a column its own line cannot hold — a bug
      #   in the caller, not a server quirk), or +encoding+ is unknown.
      def offset_for(line_text, column, encoding)
        raise ArgumentError, "column must be >= 1, got #{column}" if column < 1

        chars = column - 1
        if chars > line_text.length
          raise ArgumentError,
                "column #{column} is past the end of a #{line_text.length}-character " \
                "line: #{line_text.inspect}"
        end

        prefix = line_text[0, chars]
        case encoding
        when UTF32 then chars
        when UTF8  then prefix.bytesize
        when UTF16 then utf16_units(prefix)
        else raise ArgumentError, "unknown positionEncoding #{encoding.inspect}"
        end
      end

      # 1-based character column for a wire offset into +line_text+.
      #
      # An offset past the end of the line clamps to one-past-the-last
      # character rather than raising: a range's +end+ legitimately sits there,
      # and a server that overshoots is relayed, not fought.
      #
      # @param line_text [String, nil] the line the offset points into, or +nil+
      #   when the text is not to hand — the offset is then read as a character
      #   count, exact for an all-ASCII line and off by one per preceding
      #   multi-unit character otherwise. Locations a server walked to arrive
      #   this way, and only their line number gets rendered.
      # @param offset [Integer] 0-based offset in +encoding+'s code units.
      # @param encoding [String] one of {SUPPORTED}.
      # @return [Integer] 1-based character column.
      # @raise [ArgumentError] if +offset+ is negative or +encoding+ is unknown.
      def column_for(line_text, offset, encoding)
        raise ArgumentError, "offset must be >= 0, got #{offset}" if offset.negative?
        raise ArgumentError, "unknown positionEncoding #{encoding.inspect}" unless SUPPORTED.include?(encoding)
        return offset + 1 if line_text.nil? || encoding == UTF32

        chars =
          if encoding == UTF8
            (line_text.byteslice(0, offset) || line_text).scrub.length
          else
            chars_before_utf16(line_text, offset)
          end
        chars + 1
      end

      # UTF-16 code units +str+ occupies.
      #
      # @param str [String]
      # @return [Integer]
      def utf16_units(str)
        str.each_char.sum { |ch| ch.valid_encoding? && ch.ord > 0xFFFF ? 2 : 1 }
      end

      # Characters preceding a UTF-16 +offset+, clamped to the line's length.
      def chars_before_utf16(line_text, offset)
        units = 0
        line_text.each_char.with_index do |ch, index|
          return index if units >= offset

          units += utf16_units(ch)
        end
        line_text.length
      end
      private_class_method :chars_before_utf16
    end
  end
end
