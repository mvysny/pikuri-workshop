# frozen_string_literal: true

module Pikuri
  class Conversations
    # What the server says about a model — its context window, its slot count,
    # the inputs it takes — asked once per server and model for the whole
    # process, not once per agent:
    #
    #   Probe.props(transport)       # GET /props; on a llama.cpp router, loads the model
    #   Probe.modalities(transport)  # cheap: never loads a model
    #   Probe.facts(transport)       # no I/O: the transport with what is known filled in
    #   # => #<ChatTransport model="qwen3.6" context_window=16384 modalities={vision: true} ...>
    #
    # A {Conversation} calls {.props} at the start of each turn — never at boot,
    # since on a router it loads the model, and a conversation may switch away
    # before its first message (+pikuri:D_deferred_cap_probe+). It calls
    # {.modalities} at boot, so {Conversation#status} and {Conversation#submit}
    # know which attachments the model refuses before the first turn. The slot
    # count goes to {Throttle.default}, and the agent gets {.facts} — pikuri's
    # +Agent+ never probes, so its cap and modalities are whatever its
    # transport states.
    #
    # Stated facts win: a transport's own +context_window+ and +modalities+ are
    # never overwritten by {.facts}.
    #
    # == Implementation details
    #
    # {Detector} does the asking; it reaches only a llama.cpp behind ruby_llm's
    # +:openai+ provider and answers +nil+ fields for anything else. A failed
    # probe is cached for {RETRY_AFTER}, so a server
    # without +/props+ costs one 404 a minute rather than one a turn. Two turns
    # asking about one uncached model at once probe it once: the second waits
    # for the first.
    #
    # Thread-safe.
    module Probe
      # How long (s) an answer that carried nothing stays cached before it is
      # asked again — a server that was down at the first probe gets its cap
      # once it is back.
      #
      # @return [Integer]
      RETRY_AFTER = 60

      Props = Detector::Props
      private_constant :Props

      Entry = Data.define(:value, :at)
      private_constant :Entry

      @props = {}
      @modalities = {}
      @asking = {}
      @mutex = Mutex.new

      class << self
        # The full answer for +transport+'s model, cached.
        #
        # @param transport [Pikuri::Agent::ChatTransport]
        # @return [Detector::Props] every field
        #   +nil+ when the server answered nothing
        def props(transport)
          ask(@props, transport) do
            Detector.detect(transport, openai_base: server(transport))
          end || Props::NONE
        end

        # Which inputs +transport+'s model takes, looked up without loading it.
        #
        # @param transport [Pikuri::Agent::ChatTransport]
        # @return [Hash{Symbol => Boolean}, nil] +nil+ when unknown
        def modalities(transport)
          return transport.modalities if transport.modalities

          cached = cached(@props, transport)&.modalities
          return cached if cached

          ask(@modalities, transport) do
            Detector.detect_modalities(transport, openai_base: server(transport))
          end
        end

        # +transport+ with the cap and modalities known so far filled in where
        # it states none. No I/O.
        #
        # @param transport [Pikuri::Agent::ChatTransport]
        # @return [Pikuri::Agent::ChatTransport]
        def facts(transport)
          props = cached(@props, transport)
          cap = transport.context_window || props&.n_ctx
          modalities = transport.modalities || props&.modalities || cached(@modalities, transport)
          return transport if cap == transport.context_window && modalities == transport.modalities

          transport.with(context_window: cap, modalities:)
        end

        # Forget every answer — a spec's +after+ hook.
        #
        # @return [void]
        def reset!
          @mutex.synchronize do
            @props.clear
            @modalities.clear
          end
          nil
        end

        # @param transport [Pikuri::Agent::ChatTransport]
        # @return [String, nil] the base URL +transport+'s requests dial
        def server(transport)
          transport.api_base || RubyLLM.config.openai_api_base
        end

        private

        def key(transport)
          [Throttle.key_for(server(transport)), transport.model]
        end

        def cached(cache, transport)
          @mutex.synchronize { fresh(cache[key(transport)]) }&.value
        end

        def fresh(entry)
          return nil if entry.nil?
          return entry if useful?(entry.value)

          entry if now - entry.at < RETRY_AFTER
        end

        def useful?(value)
          value.is_a?(Hash) || (value.is_a?(Props) && value != Props::NONE)
        end

        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # Answer from +cache+, or run the block once per key however many
        # threads ask at once.
        def ask(cache, transport)
          k = key(transport)
          asking = @mutex.synchronize do
            hit = fresh(cache[k])
            return hit.value if hit

            @asking[[cache.object_id, k]] ||= Mutex.new
          end
          asking.synchronize do
            hit = @mutex.synchronize { fresh(cache[k]) }
            next hit.value if hit

            value = yield
            @mutex.synchronize { cache[k] = Entry.new(value:, at: now) }
            value
          end
        end
      end
    end
  end
end
