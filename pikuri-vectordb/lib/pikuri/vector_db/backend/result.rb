# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Backend
      # A single query hit: the matched {Chunk} + its score, returned in
      # descending-score order from a backend's +#query+.
      #
      # * +chunk+ — the stored {Chunk}.
      # * +score+ — cosine similarity +Float+ +[-1.0, 1.0]+ (in practice
      #   +[0.0, 1.0]+ for the normalized vectors most embedders produce; 1.0 =
      #   exact match, 0.0 = orthogonal). But this is cosine only *as returned by
      #   the backend* — {Tools::Search} substitutes the reranker's relevance
      #   score (via +Data#with+) when a reranker reorders, so a *surfaced* score
      #   is cosine only in vector-only mode (see {Tools::Search}'s "Which score
      #   is shown").
      #
      # {Tools::Search} cites hits as +chunk.source+ + +chunk.text+ + score; +id+
      # is never surfaced, +metadata+ carries optional deep-link extras.
      Result = Data.define(:chunk, :score)
    end
  end
end
