# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Chunker
      # One chunk as a {Chunker} emits it: the text to embed plus where in the
      # document it came from.
      #
      #   Piece.new(text: 'Notice period is three months', first_line: 1210, last_line: 1214)
      #
      # The lines number {Pikuri::FileType.read_as_text}'s output per
      # {Pikuri::Extractor}'s == Lines (1-based, inclusive, LF-only), so they
      # are valid +offset:+ values for the paged readers over the same file.
      Piece = Data.define(:text, :first_line, :last_line)
    end
  end
end
