# frozen_string_literal: true

require 'ruby_llm'
require 'faraday'
require 'json'
require 'cgi'

module Pikuri
  class Conversations
    module Probe
      # Asks the server that serves the model what it is capable of, one live
      # request per call; {Probe} is the cache in front of it:
      #
      #   props = Detector.detect(transport)
      #   props.n_ctx        # => 16384 — the window to budget against
      #   props.total_slots  # => 4 — how many requests it serves at once
      #   props.modalities   # => {vision: true, video: true, audio: false}
      #
      #   Detector.detect_modalities(transport)   # => {vision: true, audio: false}
      #
      # On a router, {.detect} loads the model to answer; {.detect_modalities}
      # is the lookup that never does. Every field is +nil+ — an honest "we
      # don't know" — for anything but a llama.cpp: its non-standard +/props+
      # reports the server's *launched* +n_ctx+ (possibly smaller than the
      # model's max, e.g. +llama-server -c 8192+ on a 128k model), its slot
      # count and the input kinds the model's projector accepts.
      #
      # This probe and a transport's stated +context_window+ are the only cap
      # sources: +RubyLLM::Model#context_window+ is never consulted
      # (+pikuri:D_context_window_sources+).
      #
      # == Implementation details
      #
      # Only ruby_llm's +:openai+ provider is probed, at the base URL the chat
      # dials (+/props+ is at the host root, so a +/v1+ suffix is stripped). A
      # bare +:openai+ at real +api.openai.com+ gets one fast 404 that degrades
      # to +nil+.
      #
      # The chat's own key goes along as +Authorization: Bearer+: +llama-server
      # --api-key SECRET+ leaves only +/health+ and +/models+ public, so an
      # unauthenticated +/props+ is a 401 that silently costs every fact. A
      # keyless server ignores the header.
      #
      # A llama.cpp *router* answers a bare +/props+ with +{"role":"router",
      # ..., "n_ctx":0}+ — no single loaded model. The per-model answer is one
      # hop away, +GET /props?model=<id>+, which routes to that model's instance
      # (loading it). A single-model server never takes this hop.
      #
      # Best-effort: an HTTP error, a timeout or a non-JSON body returns
      # {Props::NONE} with one +warn+ line, and a missing +n_ctx+ warns but keeps
      # a +total_slots+ the same document carried — a wedged or non-llama.cpp
      # server must not fail a turn over a cosmetic readout.
      class Detector
        # What one probe learned. Every field is optional, because the two
        # documents a llama.cpp answers carry different halves (a router's bare
        # +/props+ has neither) and a non-llama server has no +/props+ at all.
        #
        # @!attribute [r] n_ctx
        #   @return [Integer, nil] the server's launched context window.
        # @!attribute [r] total_slots
        #   @return [Integer, nil] how many requests it serves concurrently —
        #     what {Throttle} sizes the server's permits from.
        # @!attribute [r] modalities
        #   @return [Hash{Symbol => Boolean}, nil] llama.cpp's +modalities+
        #     object as reported, e.g. +{vision: false, video: false, audio:
        #     false}+ for a model launched without a projector.
        class Props < Data.define(:n_ctx, :total_slots, :modalities)
          # @param n_ctx [Integer, nil]
          # @param total_slots [Integer, nil]
          # @param modalities [Hash{Symbol => Boolean}, nil]
          def initialize(n_ctx:, total_slots:, modalities: nil)
            super
          end

          # Nothing learned: not an +:openai+ transport, no base URL, or a failed
          # probe.
          #
          # @return [Props]
          NONE = new(n_ctx: nil, total_slots: nil)
        end

        # Subsystem logger; set its level with +PIKURI_LOG_PROBE+ or the global
        # +PIKURI_LOG+.
        #
        # @return [Logger]
        LOGGER = Pikuri.logger_for('Probe')

        # Connect timeout (s) for the +/props+ probe. Short: a server that isn't
        # listening should fail fast rather than stall a turn.
        #
        # @return [Integer]
        OPEN_TIMEOUT = 2
        # Read timeout (s) for the +/props+ probe — generous, unlike
        # {OPEN_TIMEOUT}: a router answers +/props?model=<id>+ only after spinning
        # up that model's instance, and a cold load can take 10+s (which the next
        # chat turn must wait for anyway). A shorter timeout would lose the cap
        # exactly when switching to a cold model.
        #
        # @return [Integer]
        READ_TIMEOUT = 30
        # Read timeout (s) for {.detect_modalities}: neither document it reads
        # waits on a model load.
        #
        # @return [Integer]
        LOOKUP_TIMEOUT = 5

        # Probe the server +transport+ targets.
        #
        # @param transport [Pikuri::Agent::ChatTransport] +provider+ gates the probe,
        #   +model+ drives the router +?model=+ hop
        # @param openai_base [String, nil] the server's base URL; defaults to the
        #   transport's own, else the live +RubyLLM.config.openai_api_base+
        # @param openai_key [String, nil] fallback credential for a transport
        #   that overrides no key of its own, i.e. one riding the global config;
        #   same default-and-override shape as +openai_base+, and it must stay
        #   that way — a key resolved from a different place than the base
        #   authenticates against the wrong server after a cross-server switch
        # @return [Props] what the server reported; {Props::NONE} for a
        #   non-+:openai+ transport, an unconfigured base, or any probe failure
        def self.detect(transport, openai_base: transport.api_base || RubyLLM.config.openai_api_base,
                        openai_key: RubyLLM.config.openai_api_key)
          return Props::NONE unless transport.provider == :openai

          url = props_url(openai_base)
          return Props::NONE if url.nil?

          new(probe_url: url, model_id: transport.model,
              api_key: transport.api_key || openai_key).probe
        end

        # Which input kinds +transport+'s model accepts, looked up without
        # loading it.
        #
        # A llama.cpp router lists every model's +input_modalities+ in
        # +/v1/models+, loaded or not (+["text"]+ → +vision: false+). A
        # single-model +llama-server+ lists none, but its bare +/props+ is cheap:
        # its one model loaded at startup. The router's +/props?model=<id>+ hop,
        # which would load the model, is never taken.
        #
        # @param transport [Pikuri::Agent::ChatTransport] +provider+ gates the lookup,
        #   +model+ (an id or an alias) picks the +/v1/models+ entry
        # @param openai_base [String, nil] the server's base URL; defaults to the
        #   transport's own, else the live +RubyLLM.config.openai_api_base+
        # @param openai_key [String, nil] fallback credential, as for {.detect}
        # @return [Hash{Symbol => Boolean}, nil] +nil+ when neither document
        #   answered
        def self.detect_modalities(transport, openai_base: transport.api_base || RubyLLM.config.openai_api_base,
                                   openai_key: RubyLLM.config.openai_api_key)
          return nil unless transport.provider == :openai

          url = props_url(openai_base)
          return nil if url.nil?

          new(probe_url: url, model_id: transport.model,
              api_key: transport.api_key || openai_key).lookup_modalities
        end

        # Derive the +/props+ URL from the OpenAI-compatible base (+/props+ is at
        # the host root, so a trailing +/v1+ is stripped).
        #
        # @param openai_base [String, nil]
        # @return [String, nil] the +/props+ URL, or +nil+ when the base is blank
        def self.props_url(openai_base)
          base = openai_base.to_s.strip.chomp('/')
          return nil if base.empty?

          "#{base.delete_suffix('/v1')}/props"
        end

        # @param probe_url [String] full URL to llama.cpp +/props+
        # @param model_id [String, nil] the chat model id, used to follow a
        #   llama.cpp router via +/props?model=<id>+ when the bare probe
        #   reports +role: router+. +nil+ or empty disables that second hop.
        # @param api_key [String, nil] sent as +Authorization: Bearer+ on every
        #   hop; +nil+ or empty sends no header.
        def initialize(probe_url:, model_id:, api_key: nil)
          @probe_url = probe_url
          @model_id = model_id
          @api_key = api_key
        end

        # @return [Props] what the server reported; {Props::NONE} if the probe
        #   produced nothing
        def probe
          probe_llama_cpp
        end

        # @return [Hash{Symbol => Boolean}, nil] see {.detect_modalities}
        def lookup_modalities
          listed_modalities || bare_props_modalities
        end

        private

        # @return [Hash{Symbol => Boolean}, nil] the model's +/v1/models+
        #   +input_modalities+ in +/props+ vocabulary; +nil+ when the model or
        #   the field is not listed
        def listed_modalities
          return nil unless model_id_present?

          data = fetch_json("#{@probe_url.delete_suffix('/props')}/v1/models", timeout: LOOKUP_TIMEOUT)
          models = data['data'] if data.is_a?(Hash)
          return nil unless models.is_a?(Array)

          entry = models.find do |m|
            m.is_a?(Hash) && (m['id'] == @model_id || Array(m['aliases']).include?(@model_id))
          end
          kinds = entry&.dig('architecture', 'input_modalities')
          return nil unless kinds.is_a?(Array)

          { vision: kinds.include?('image'), audio: kinds.include?('audio') }
        end

        # @return [Hash{Symbol => Boolean}, nil] a bare +/props+'s +modalities+;
        #   +nil+ from a router, whose bare +/props+ carries none
        def bare_props_modalities
          data = fetch_json(@probe_url, timeout: LOOKUP_TIMEOUT)
          modalities_from(data['modalities']) if data.is_a?(Hash)
        end

        def probe_llama_cpp
          data = fetch_json(@probe_url)
          return Props::NONE if data.nil?

          props = props_from(data)
          return props if props.n_ctx

          # llama.cpp router: the bare /props carries no model, so its
          # n_ctx is 0 (and it reports no slot count either). Follow the router
          # to the model's own instance, which reports both.
          return probe_router_model if data['role'] == 'router' && model_id_present?

          warn_and_keep(
            props,
            "no positive integer at default_generation_settings.n_ctx in #{@probe_url} response"
          )
        end

        def probe_router_model
          url = "#{@probe_url}?model=#{CGI.escape(@model_id)}"
          data = fetch_json(url)
          return Props::NONE if data.nil?

          props = props_from(data)
          return props if props.n_ctx

          warn_and_keep(
            props, "no positive integer at default_generation_settings.n_ctx in router probe #{url}"
          )
        end

        # GETs +url+ and parses its JSON body.
        #
        # @param url [String] a llama.cpp +/props+ or +/v1/models+ URL
        # @param timeout [Integer] read timeout (s)
        # @return [Object, nil] the parsed body, or +nil+ (after one +warn+
        #   line) on non-200, timeout, transport error, or non-JSON body
        def fetch_json(url, timeout: READ_TIMEOUT)
          response = Faraday.new(
            request: { open_timeout: OPEN_TIMEOUT, timeout: timeout }
          ).get(url) do |req|
            req.headers['Accept'] = 'application/json'
            req.headers['Authorization'] = "Bearer #{@api_key}" if key?
          end

          return warn_and_nil(http_failure(response.status, url)) unless response.status == 200

          JSON.parse(response.body)
        rescue Faraday::Error, JSON::ParserError => e
          warn_and_nil("#{e.class.name.split('::').last}: #{e.message}")
        end

        # @return [Boolean] whether there is a credential to send.
        def key?
          !@api_key.nil? && !@api_key.empty?
        end

        # The +warn+ line's text for a non-200 status. A bare "HTTP 401" is
        # nobody's diagnosis of a misconfigured key, and this warning is the only
        # signal an operator gets — the probe degrades rather than raising.
        #
        # @param status [Integer] the response status.
        # @param url [String] the probed URL.
        # @return [String] never carrying the key itself, only whether one went.
        def http_failure(status, url)
          line = "HTTP #{status} from #{url}"
          return line unless [401, 403].include?(status)

          sent = key? ? 'the key sent was rejected' : 'none was sent'
          "#{line}: the server requires an API key (#{sent})"
        end

        # @param data [Hash] a parsed +/props+ body
        # @return [Props] the launched +n_ctx+ (nested under
        #   +default_generation_settings+) and +total_slots+ (top level), each
        #   +nil+ unless present and positive, and +modalities+ (top level)
        def props_from(data)
          Props.new(n_ctx: positive_int(data.dig('default_generation_settings', 'n_ctx')),
                    total_slots: positive_int(data['total_slots']),
                    modalities: modalities_from(data['modalities']))
        end

        # @param value [Object] the +modalities+ value off a +/props+ body
        # @return [Hash{Symbol => Boolean}, nil] its Boolean entries, symbol-keyed;
        #   +nil+ when it is absent or not an object (an older llama.cpp, or a
        #   router's bare +/props+)
        def modalities_from(value)
          return nil unless value.is_a?(Hash)

          value.select { |_, v| [true, false].include?(v) }.transform_keys(&:to_sym)
        end

        # @param value [Object] a value off a +/props+ body
        # @return [Integer, nil]
        def positive_int(value)
          value if value.is_a?(Integer) && value.positive?
        end

        def model_id_present?
          !@model_id.nil? && !@model_id.empty?
        end

        # @param reason [String]
        # @return [nil]
        def warn_and_nil(reason)
          LOGGER.warn("llama.cpp probe failed: #{reason}")
          nil
        end

        # Warn about the missing +n_ctx+ but keep whatever the document *did*
        # carry — a +total_slots+ beside a missing cap is still the slot count.
        #
        # @param props [Props] what {#props_from} parsed; equal to {Props::NONE}
        #   when the document carried neither field
        # @param reason [String] the +warn+ line's text
        # @return [Props] +props+, unchanged
        def warn_and_keep(props, reason)
          warn_and_nil(reason)
          props
        end
      end
    end
  end
end
