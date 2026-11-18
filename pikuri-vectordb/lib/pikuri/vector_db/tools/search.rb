# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Tools
      # The LLM-facing +vectordb_search+ tool — agentic search, the agent
      # decides when to retrieve. Composes {Embedder} + {Backend} + optional
      # {Reranker}: embed the query, {Backend#query} for candidates
      # ({CANDIDATE_K} with a reranker to narrow back to {FINAL_K}, else
      # {FINAL_K} directly), optionally rerank (reorder by {Reranker::Hit.index},
      # take top {FINAL_K}), then format as a numbered list:
      #
      #   Found 5 matches.
      #
      #   [1] handbook.md lines 1210-1248
      #   Either party may terminate the agreement with three months' notice...
      #
      # The line range (per {Pikuri::Extractor}'s == Lines) is a ready
      # +offset:+ for +vectordb_read+, so the agent reads the passage in its
      # surroundings rather than answering from the {SNIPPET_LENGTH}-char
      # snippet alone.
      #
      # == Why no score is shown
      #
      # The rank is the whole signal the model gets. Every number behind it is
      # one the model can't calibrate: a cosine's useful band depends on the
      # embedder, a cross-encoder's relevance is often an unbounded logit
      # ({Reranker::Hit}), and +pikuri-rag+'s fused rank and +bm25()+ mean
      # nothing outside one query. Under one +score=+ label they invited the
      # model to read a well-ranked hit as weak, and naming each scale
      # (+cosine=+, +bm25=+) would only name a number it still can't read; it
      # judges the snippets anyway — measured, a cosine or per-leg label beside
      # each hit changed no pick (+D_rrf_tuning+). The score stays on
      # {Backend::Result} for a library caller.
      #
      # A reranker outage falls back, doesn't fail: its +RuntimeError+ (the
      # {Reranker} protocol's) is caught, WARN-logged, and the vector-only top {FINAL_K}
      # returned — reranker is a quality knob, degraded results beat a tool error.
      #
      # Single-param surface (+query:+ only, no +top_k:+/+reranker:+ toggle):
      # retrieval depth and rerank choice are host policy baked into {Extension},
      # not something the LLM should tune mid-conversation.
      #
      # == Who declares the legs
      #
      # Whether the retrieved chunks are confidential, and whether they are
      # bytes pikuri did not write, are properties of the *corpus* — so they
      # arrive pre-derived in +legs:+ from {Corpus}'s +private:+ /
      # +trusted:+ (the same shape {Pikuri::Workspace::Read} takes from its
      # {Pikuri::Workspace::Filesystem}), and both default to the pessimistic
      # value. The egress axis is not declared but structural: the query never
      # leaves the machine, which is the whole point of local retrieval.
      #
      # Sharing: +P_shared_locked+, and sharing is what you want — an index is
      # expensive to build and is the same corpus for every agent, so ten
      # agents over one {Backend} is the intended shape. {Backend::InMemory}
      # locks; the server backends serialize on their own side; the embedder
      # and reranker are stateless HTTP.
      class Search < Pikuri::Tool
        LOGGER = Pikuri.logger_for('VectorDb::Tools::Search')

        # @return [Integer] results returned to the LLM — the RAG sweet spot:
        #   enough for related-but-different angles, few enough to fit a turn.
        FINAL_K = 5

        # @return [Integer] over-fetch size with a reranker (retrieve-broad-then-
        #   narrow — the cross-encoder sees more candidates than vector search
        #   surfaces and reorders by query-conditional relevance).
        CANDIDATE_K = 50

        # @return [Integer] per-result text cap in the observation (~2.5 KB for a
        #   five-result page; the agent can re-query if a snippet cuts off).
        SNIPPET_LENGTH = 500

        # @return [String] static description shown to the LLM,
        #   opencode-shape (summary + +Usage:+ bullets).
        DESCRIPTION = <<~DESC
          Search the indexed document corpus for content relevant to a query.

          Usage:
          - Use when the user asks about facts, definitions, or topics that would live in their indexed documents (notes, docs, knowledge base).
          - Phrase the query as a complete question or topic statement — the embedder reads natural language, not keyword bags.
          - Returns up to #{FINAL_K} results with `source` paths, line ranges and text snippets; cite results back using the source path.
          - A snippet is a fragment. To read a result in context, call `vectordb_read` with its `source` and the first line of its range as `offset`.
          - If a query returns nothing useful, either the relevant doc isn't in the corpus, or the corpus hasn't been indexed yet — say which you suspect, and offer to run `vectordb_reindex` to build the index.
        DESC

        # @param embedder [#embed] anything implementing
        #   +embed(Array<String>) -> Array<Array<Float>>+.
        #   Typically {Pikuri::VectorDb::Embedder}.
        # @param backend [#query, #upsert, #delete_all, #count]
        #   any {Backend} implementation.
        # @param reranker [#rerank, nil] optional. +nil+ skips
        #   reranking and retrieves {FINAL_K} from the backend
        #   directly.
        # @param legs [Pikuri::Tool::TrifectaLegs] the corpus's
        #   declaration, derived by {Extension} from its
        #   corpus's +private:+ / +trusted:+ flags (see "Who declares
        #   the legs"). Required — a default here would be a
        #   second copy of that derivation.
        # @return [Search]
        def initialize(embedder:, backend:, legs:, reranker: nil)
          super(
            name: 'vectordb_search',
            description: DESCRIPTION,
            parameters: Pikuri::Tool::Parameters.build { |p|
              p.required_string :query,
                                'Natural-language search query, e.g. ' \
                                '"how does the deployment pipeline handle migrations?" or ' \
                                '"recipe with mushrooms and risotto rice".'
            },
            execute: lambda { |query:|
              Search.execute(
                embedder: embedder, backend: backend, reranker: reranker,
                query: query
              )
            },
            trifecta_legs: legs
          )
        end

        # Public so specs can exercise the search pipeline without
        # constructing a Tool wrapper.
        #
        # @param embedder [#embed]
        # @param backend [#query]
        # @param reranker [#rerank, nil]
        # @param query [String]
        # @return [Pikuri::Tool::Result] the formatted observation (+"Found 8
        #   matches"+), or {Pikuri::Tool::Result.error} for an empty query.
        def self.execute(embedder:, backend:, reranker:, query:)
          return Pikuri::Tool::Result.error('query is empty') if query.nil? || query.strip.empty?

          candidate_k = reranker ? CANDIDATE_K : FINAL_K
          query_vector = embedder.embed([query]).first
          candidates = backend.query(vector: query_vector, top_k: candidate_k)
          if candidates.empty?
            return Pikuri::Tool::Result.new(content: 'No matches found in the indexed corpus.',
                                            summary: 'Found 0 matches')
          end

          final = if reranker
                    reranked_or_fallback(reranker: reranker, query: query, candidates: candidates)
                  else
                    candidates
                  end.first(FINAL_K)

          format_observation(final)
        end

        # Attempt the rerank; on any reranker +RuntimeError+, WARN and return the
        # candidate ordering unchanged. On success each {Backend::Result} carries
        # the reranker's relevance score (via +Data#with+, replacing whatever the
        # candidate arrived with), so a caller reading +score+ sees the number
        # the order was built from.
        #
        # Public, with {.format_observation}: the two are the rerank-then-render
        # tail of the search pipeline, reusable by any tool set over this corpus
        # plumbing under its own +family:+ prefix. +candidates+ need not have
        # come from a vector search.
        #
        # @param reranker [#rerank]
        # @param query [String]
        # @param candidates [Array<Backend::Result>] best first.
        # @return [Array<Backend::Result>] reranked (score = rerank relevance) or
        #   the input unchanged.
        def self.reranked_or_fallback(reranker:, query:, candidates:)
          documents = candidates.map { |c| c.chunk.text }
          hits = reranker.rerank(query: query, documents: documents)
          hits.map { |h| candidates[h.index]&.with(score: h.score) }.compact
        rescue RuntimeError => e
          # Not "vector-only": the candidates may be a fused list, and this line
          # is the only thing a person reads while diagnosing an outage.
          LOGGER.warn("reranker outage; falling back to the candidate ordering: #{e.message}")
          candidates
        end

        # Format the results as a header + numbered +source lines a-b+ blocks
        # with the snippet below, truncated at {SNIPPET_LENGTH} with +...+, in
        # the order given and with no score (see "Why no score is shown"). A
        # chunk without +first_line:+ / +last_line:+ metadata — one not
        # written by the {Corpus} — prints no range.
        #
        # Public as the other half of the reusable tail — see
        # {.reranked_or_fallback}.
        #
        # @param results [Array<Backend::Result>]
        # @return [Pikuri::Tool::Result] the observation, carrying +"Found 8
        #   matches"+ — the count, never a snippet: these are corpus bytes, and
        #   a display line is read as status.
        def self.format_observation(results)
          header = "Found #{results.length} match#{'es' unless results.length == 1}.\n\n"
          body = results.each_with_index.map do |result, i|
            snippet = result.chunk.text
            snippet = snippet[0, SNIPPET_LENGTH] + '...' if snippet.length > SNIPPET_LENGTH
            "[#{i + 1}] #{result.chunk.source}#{line_range(result.chunk)}\n#{snippet}"
          end.join("\n\n")
          Pikuri::Tool::Result.new(
            content: header + body,
            summary: "Found #{Pikuri::Tool.pluralize(results.length, 'match', 'matches')}"
          )
        end

        # @param chunk [Chunk]
        # @return [String] +" lines 1210-1248"+, +" line 7"+ for a one-line
        #   chunk, or +""+ when the chunk carries no range.
        def self.line_range(chunk)
          first = chunk.metadata[:first_line]
          last = chunk.metadata[:last_line]
          return '' unless first && last

          first == last ? " line #{first}" : " lines #{first}-#{last}"
        end
        private_class_method :line_range
      end
    end
  end
end
