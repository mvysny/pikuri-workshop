# frozen_string_literal: true

module Pikuri
  module Memory
    class Mem0Server
      # The model mem0 decides what to remember with, plus the request-body
      # fields every extraction call sends — the same shape as a titler:
      # the chat model again, thinking off, so one model stays in memory:
      #
      #   Mem0Server::ExtractionModel.new(
      #     name: 'Ornith-1.5',
      #     params: { chat_template_kwargs: { enable_thinking: false } }
      #   )
      #
      # +params+ go out exactly as written (+pikuri:D_opaque_request_params+),
      # because the spelling is per model and server: llama.cpp with a
      # Qwen-style template wants the kwarg above, OpenAI +reasoning_effort+.
      # A model that thinks needs them: a thinking extractor can spend its
      # whole budget reasoning and return no JSON (design/architecture.md
      # §"Why a non-reasoning extraction model").
      #
      # @!attribute [r] name
      #   @return [String] model id on the router, e.g. +"Ornith-1.5"+
      # @!attribute [r] params
      #   @return [Hash{String, Symbol => Object}] extra request-body fields;
      #     empty sends none
      ExtractionModel = Data.define(:name, :params) do
        # @param name [String] model id on the router.
        # @param params [Hash{String, Symbol => Object}] extra request-body
        #   fields, e.g. +{ chat_template_kwargs: { enable_thinking: false } }+.
        # @raise [ArgumentError] when +params+ is not a Hash.
        def initialize(name:, params: {})
          raise ArgumentError, "params must be a Hash, got #{params.class}" unless params.is_a?(Hash)

          super
        end
      end
    end
  end
end
