# frozen_string_literal: true

module Pikuri
  module Rag
    module Backend
      # One document {Fts5#find} listed — it holds every term somewhere —
      # with where each of its matching chunks starts:
      #
      #   DocumentMatch.new(source: 'acme-2026-08-14.md', first_lines: [1, 38, 77])
      #
      # * +source+ — the {Pikuri::VectorDb::Chunk#source} citation.
      # * +first_lines+ — +Array<Integer>+, ascending, one per chunk matching
      #   at least one term (so its length is the match count), numbered per
      #   {Pikuri::Extractor}'s == Lines: each a valid +offset:+ for the paged
      #   readers.
      #
      # The per-document counterpart of {Pikuri::VectorDb::Backend::Result},
      # which is one ranked chunk.
      DocumentMatch = Data.define(:source, :first_lines)
    end
  end
end
