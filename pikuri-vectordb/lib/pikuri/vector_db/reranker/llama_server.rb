# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  module VectorDb
    module Reranker
      # Cross-encoder reranker on a llama.cpp server's +/v1/rerank+:
      #
      #   reranker = LlamaServer.new(server: 'http://localhost:8080',
      #                              model: 'gpustack/bge-reranker-v2-m3-GGUF:Q8_0')
      #   reranker.rerank(query: 'capital of France?', documents: %w[Berlin Paris])
      #   # => [#<Hit index=1, score=4.7>, #<Hit index=0, score=-6.2>]
      #
      # The arguments are {Embedder}'s, so a host hands it the same server and
      # key; it likewise owns its +RubyLLM::Context+ (the Connection seam in
      # this gem's +AGENTS.md+) and runs +around_request:+ around every rerank.
      #
      # == Implementation details
      #
      # The request rides ruby_llm's +:gpustack+ provider, not +:openai+: in
      # ruby_llm 2.2 only GPUStack and OpenRouter speak the Jina-style
      # +POST rerank+ that llama-server serves, and +:openai+ refuses with
      # "OpenAI doesn't support reranking". GPUStack is never otherwise used
      # here; it is just the provider whose wire matches. Switch to +:openai+
      # once https://github.com/crmne/ruby_llm/issues/1684 lands.
      #
      # Every failure surfaces as a +RuntimeError+ naming the endpoint — the
      # one class {Tools::Search} catches to fall back to the unreranked
      # order — so a +RubyLLM::Error+ (HTTP status, refused connection) is
      # re-raised as one. ruby_llm retries a failed request on its own
      # (3 times, 0.1 s doubling) before that.
      class LlamaServer
        # @return [String] the reranker model id, trusted verbatim: RubyLLM's
        #   model registry is bypassed, as for {Embedder#model}.
        attr_reader :model

        # @return [String] the base URL the reranks dial, ending in +/v1+.
        attr_reader :api_base

        # @param server [String] server origin, with or without a trailing
        #   +/v1+, e.g. +"http://localhost:8080"+.
        # @param model [String] reranker model id served there, e.g.
        #   +"gpustack/bge-reranker-v2-m3-GGUF:Q8_0"+; a single-model server
        #   ignores it.
        # @param api_key [String, nil] sent as +Authorization: Bearer+, the
        #   header +llama-server --api-key+ checks; +nil+ sends none.
        # @param around_request [#call, nil] runs around every rerank request,
        #   as {Embedder}'s does; +nil+ for none.
        def initialize(server:, model:, api_key: nil, around_request: nil)
          @model    = model
          @api_base = "#{server.to_s.strip.chomp('/').delete_suffix('/v1')}/v1"
          base      = @api_base
          @context  = RubyLLM.context do |c|
            c.gpustack_api_base = base
            c.gpustack_api_key  = api_key
            if around_request
              Pikuri::Agent::RequestInstrumenter.install(c, hook: around_request, api_base: base,
                                                            cancellable: nil)
            end
          end
        end

        # Scores every document against +query+, best first. Empty
        # +documents+ answers +[]+ with no HTTP call.
        #
        # @param query [String]
        # @param documents [Array<String>] the candidates; a position becomes
        #   its {Hit#index}.
        # @return [Array<Hit>] one per document, descending by score.
        # @raise [RuntimeError] on any failure: HTTP error, unreachable server,
        #   or a response that doesn't score every document.
        def rerank(query:, documents:)
          return [] if documents.empty?

          results = @context.rerank(query, documents, model: @model, provider: :gpustack,
                                                      assume_model_exists: true).results
          # ruby_llm passes a body without +results+ through as no results, which
          # would drop every candidate instead of falling back.
          unless results.length == documents.length && results.all? { |r| r.score.is_a?(Numeric) }
            raise "Reranker::LlamaServer: #{@api_base}/rerank scored #{results.length} of " \
                  "#{documents.length} documents: #{results.inspect}"
          end

          results.map { |r| Hit.new(index: r.index, score: r.score.to_f) }.sort_by { |h| -h.score }
        rescue RubyLLM::Error => e
          raise "Reranker::LlamaServer: #{e.class.name.split('::').last} " \
                "calling #{@api_base}/rerank: #{e.message}"
        end
      end
    end
  end
end
