# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Reranker
      # A single rerank result, returned in descending +score+ order from a
      # reranker's +#rerank+.
      #
      # * +index+ — +Integer+, the position in the +documents+ array passed to
      #   +#rerank+; callers use it to look up text/metadata they already hold.
      # * +score+ — +Float+ relevance, range model-dependent (Cohere +[0.0, 1.0]+
      #   via a logistic head; raw logits range further). Treat as opaque — use
      #   for ordering, not thresholding (a "0.5 cutoff" means different things
      #   to different models).
      Hit = Data.define(:index, :score)
    end
  end
end
