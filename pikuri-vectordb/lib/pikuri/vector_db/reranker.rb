# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for rerankers — the optional quality knob that narrows a top-N
    # candidate set (~50) down to the top-k the LLM sees (~5) by scoring each
    # candidate against the query with a cross-encoder. One ships: {LlamaServer},
    # over ruby_llm's rerank, which also speaks Cohere's, OpenRouter's and
    # Bedrock's — another backend is mostly a +provider:+ swap.
    #
    # == Reranker protocol
    #
    # Duck-typed: +#rerank(query:, documents:)+ → +Array<{Hit}>+ sorted
    # descending by +score+, one entry per input document, +Hit.index+ the
    # position in +documents+; empty +documents+ → +[]+ with no HTTP call. An
    # outage raises +RuntimeError+, which {Tools::Search} turns into the
    # unreranked order.
    #
    # Index, not document text: {Tools::Search} already holds the candidate
    # texts, so returning bare indices avoids re-shuttling them over HTTP
    # (Cohere's +return_documents+ exists for callers that *don't* have the
    # text, which isn't us).
    #
    # nil-skip, not a NOOP default: {Extension} takes +reranker: nil+ as "skip
    # rerank, retrieve top-k directly." A +Reranker::NOOP+ was **rejected** — it
    # wouldn't unify the candidate-window choice (still branch on real-vs-fake)
    # and its faux scores would pollute observations and logs.
    module Reranker
    end
  end
end
