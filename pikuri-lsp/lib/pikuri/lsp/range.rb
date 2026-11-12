# frozen_string_literal: true

module Pikuri
  module Lsp
    # A span between two {Position}s, in pikuri's 1-based coordinates. Servers
    # answer with ranges everywhere — a definition's whole body, an
    # identifier's own extent, the slice of a class file worth showing — so
    # this is mostly a parse target:
    #
    #   range = Range.from_wire({ 'start' => { 'line' => 12, 'character' => 6 },
    #                             'end'   => { 'line' => 12, 'character' => 22 } },
    #                           text: File.read(path), encoding: PositionEncoding::UTF8)
    #   range.to_s         # => "13:7-13:23"
    #   range.start.line   # => 13
    #
    # There is deliberately no +#to_wire+: pikuri sends positions (an anchor
    # for a query), never ranges. The one client-to-server range in LSP is a
    # +didChange+ edit, and pikuri re-sends +didOpen+ instead.
    #
    # Note the shadowing: inside +Pikuri::Lsp+, +Range+ is this class, so
    # Ruby's own needs +::Range+.
    #
    # @!attribute [r] start
    #   @return [Position] first position inside the span.
    # @!attribute [r] end
    #   @return [Position] one position *past* the span, LSP's half-open
    #     convention, so a zero-width range has +start == end+.
    Range = Data.define(:start, :end) do
      # Parse LSP's +Range+ object.
      #
      # @param hash [Hash{String => Hash}] +{"start" =>, "end" =>}+.
      # @param text [String, nil] the *whole* document the range points into,
      #   which is what makes both columns exact; +nil+ when the text is not to
      #   hand (see {PositionEncoding.column_for}).
      # @param encoding [String] the server's negotiated +positionEncoding+.
      # @return [Range]
      # @raise [KeyError] if +start+ or +end+ is missing.
      def self.from_wire(hash, text: nil, encoding: PositionEncoding::DEFAULT)
        lines = text&.lines
        wire_start = hash.fetch('start')
        wire_end = hash.fetch('end')
        new(start: Position.from_wire(wire_start, line_text: line_at(lines, wire_start), encoding: encoding),
            end: Position.from_wire(wire_end, line_text: line_at(lines, wire_end), encoding: encoding))
      end

      # The text of the line a wire position sits on, or +nil+ when the
      # document text was not supplied.
      def self.line_at(lines, wire_position)
        lines && lines[Integer(wire_position.fetch('line'))]
      end
      private_class_method :line_at

      # @return [Boolean] whether the span begins and ends on one line, i.e.
      #   whether a one-line snippet can show all of it.
      def single_line?
        start.line == self.end.line
      end

      # @return [String] +"13:7-13:23"+.
      def to_s
        "#{start}-#{self.end}"
      end
    end
  end
end
