# frozen_string_literal: true

module Pikuri
  module Lsp
    # One cursor position in pikuri's coordinates: 1-based line, 1-based
    # character column — the same numbers +read+ and +grep+ print, so a
    # rendered location needs no arithmetic and the model never sees an encoded
    # offset in either direction.
    #
    # The wire is 0-based and code-unit-encoded, and this pair of calls is the
    # only place that is true:
    #
    #   line = File.readlines('read.rb')[164]        # "    workspace.resolve_for_read(path)"
    #   pos  = Position.new(line: 165, column: line.index('resolve_for_read') + 1)
    #   pos.to_wire(line_text: line, encoding: PositionEncoding::UTF8)
    #   # => {:line=>164, :character=>14}
    #
    #   Position.from_wire({ 'line' => 164, 'character' => 14 },
    #                      line_text: line, encoding: PositionEncoding::UTF8).to_s
    #   # => "165:15"
    #
    # @!attribute [r] line
    #   @return [Integer] 1-based line number.
    # @!attribute [r] column
    #   @return [Integer] 1-based column, counted in characters (not bytes, not
    #     UTF-16 code units).
    Position = Data.define(:line, :column) do
      # Parse LSP's +Position+ object.
      #
      # @param hash [Hash{String => Integer}] +{"line" =>, "character" =>}+,
      #   0-based.
      # @param line_text [String, nil] the target line's text; +nil+ costs
      #   column exactness on a line with multi-unit characters, see
      #   {PositionEncoding.column_for}.
      # @param encoding [String] the server's negotiated +positionEncoding+.
      # @return [Position]
      # @raise [KeyError] if either wire field is missing.
      def self.from_wire(hash, line_text: nil, encoding: PositionEncoding::DEFAULT)
        new(line: Integer(hash.fetch('line')) + 1,
            column: PositionEncoding.column_for(line_text, Integer(hash.fetch('character')), encoding))
      end

      # @raise [ArgumentError] if either coordinate is below 1 — a 0 means an
      #   unconverted wire value leaked in, which is the bug this type exists
      #   to prevent.
      def initialize(line:, column:)
        raise ArgumentError, "line must be >= 1, got #{line}" if line < 1
        raise ArgumentError, "column must be >= 1, got #{column}" if column < 1

        super
      end

      # Render as LSP's +Position+ object.
      #
      # @param line_text [String] the text of {#line}, required because the
      #   column's encoding depends on the characters preceding it.
      # @param encoding [String] the server's negotiated +positionEncoding+.
      # @return [Hash{Symbol => Integer}] +{line:, character:}+, 0-based,
      #   ready for +JSON.generate+.
      # @raise [ArgumentError] if {#column} points past the end of +line_text+.
      def to_wire(line_text:, encoding: PositionEncoding::DEFAULT)
        { line: line - 1, character: PositionEncoding.offset_for(line_text, column, encoding) }
      end

      # @return [String] +"165:15"+ — the form a rendered location appends to a
      #   path.
      def to_s
        "#{line}:#{column}"
      end
    end
  end
end
