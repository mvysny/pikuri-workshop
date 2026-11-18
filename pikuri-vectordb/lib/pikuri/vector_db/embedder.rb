# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  module VectorDb
    # Turns text into vectors through an OpenAI-compatible +/v1/embeddings+
    # endpoint, a local llama.cpp server by default:
    #
    #   embedder = Embedder.new(server: 'http://localhost:8080',
    #                           model: 'nomic-ai/nomic-embed-text-v1.5-GGUF:Q8_0')
    #   embedder.embed(%w[alpha beta])   # => [[0.018, ...], [-0.027, ...]]
    #
    # {#embed} always takes +Array<String>+ and returns one vector per text, in
    # order; +RubyLLM.embed+ answers a flat vector for a lone String, and
    # pinning the array shape keeps the {Corpus} from branching on it.
    # Batching is the {Corpus}'s: it calls {#embed} once per file, with all of
    # that file's chunks. Tests hand the {Corpus} any object with a matching +#embed+
    # instead of this class.
    #
    # == Connection
    #
    # The embedder owns its connection: one +RubyLLM::Context+, built from
    # +server+ and +api_key+ at construction, so an embed never reads the
    # process-global +RubyLLM.config+ (the Connection seam in this gem's
    # +AGENTS.md+). The arguments are
    # {Pikuri::Agent::ChatTransport.from_openai_server}'s, so a bin hands both
    # the same values, but not a +ChatTransport+ itself: its +context_window+,
    # +params+ and +modalities+ mean nothing to an embed.
    #
    # == Throttling
    #
    # +around_request:+ takes the same hook as {Pikuri::Agent#initialize}'s and
    # runs it around every embed request, so a host's throttle on a small
    # llama-server sees the {Watcher}'s reindex barrage beside the chat's
    # completions. Pass it the hook the host's agents get:
    #
    #   Embedder.new(server: s, model: m, around_request: agent_hook)
    #
    # The hook's +cancellable+ is always +nil+: an embed belongs to no turn,
    # even when a tool's call made it.
    #
    # RubyLLM exceptions propagate verbatim: this is internal code, not an
    # LLM-facing tool, so there is no +"Error: ..."+ return path.
    class Embedder
      # @return [String] the embedding model id, trusted verbatim: RubyLLM's
      #   model registry is bypassed, since a local server's ids (router
      #   aliases, HF repo paths) are not in its catalog.
      attr_reader :model

      # @return [String] the OpenAI base URL the embeds dial, ending in +/v1+.
      attr_reader :api_base

      # @param server [String] server origin, with or without a trailing
      #   +/v1+, e.g. +"http://localhost:8080"+.
      # @param model [String] embedding model id served there, e.g.
      #   +"nomic-ai/nomic-embed-text-v1.5-GGUF:Q8_0"+.
      # @param api_key [String] API key; the +"not-needed"+ placeholder for a
      #   keyless local server.
      # @param around_request [#call, nil] runs around every embed request (see
      #   "Throttling"); +nil+ for none.
      # @return [Embedder]
      def initialize(server:, model:, api_key: 'not-needed', around_request: nil)
        @model    = model
        @api_base = "#{server.to_s.strip.chomp('/').delete_suffix('/v1')}/v1"
        base      = @api_base
        @context  = RubyLLM.context do |c|
          c.openai_api_base = base
          c.openai_api_key  = api_key
          if around_request
            Pikuri::Agent::RequestInstrumenter.install(c, hook: around_request, api_base: base,
                                                          cancellable: nil)
          end
        end
      end

      # Embed +texts+ as a single call to the server. Empty input
      # short-circuits to +[]+ with no HTTP round-trip.
      #
      # @param texts [Array<String>] non-nil; every element must be a String.
      # @return [Array<Array<Float>>] parallel to +texts+: the i-th vector is
      #   the embedding of +texts[i]+.
      # @raise [ArgumentError] if +texts+ isn't an Array, or any element isn't
      #   a String.
      def embed(texts)
        unless texts.is_a?(Array)
          raise ArgumentError, "expected Array<String>, got #{texts.class}"
        end
        return [] if texts.empty?
        unless texts.all? { |t| t.is_a?(String) }
          bad = texts.reject { |t| t.is_a?(String) }.first
          raise ArgumentError, "all elements must be String, got #{bad.class}"
        end

        @context.embed(texts, model: @model, provider: :openai, assume_model_exists: true).vectors
      end
    end
  end
end
