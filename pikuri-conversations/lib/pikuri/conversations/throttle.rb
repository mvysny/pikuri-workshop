# frozen_string_literal: true

module Pikuri
  class Conversations
    # How many LLM requests may fly against one inference server at a time,
    # process-wide. It is pikuri's +around_request:+ hook, and every agent a
    # {Conversations} list builds carries it already; pass it to the agents you
    # build yourself, a titler for one, so they queue with the rest:
    #
    #   Pikuri::Agent.new(transport:, system_prompt:, around_request: Pikuri::Conversations::Throttle)
    #
    # pikuri-vectordb's +Embedder+ takes the same hook, so a RAG reindex queues
    # beside the chat's completions instead of crowding them off a small server:
    #
    #   Pikuri::VectorDb::Embedder.new(server:, model:, around_request: Pikuri::Conversations::Throttle)
    #
    # Its +Reranker::LlamaServer+ takes it too, the same way.
    #
    # The permits are shared only when the embeds dial the chat's server, a
    # llama.cpp router serving both models. A separate embedding server is a
    # key of its own that no turn probes, so it stays unlimited until you
    # {.limit} it.
    #
    # A host sizes a server it knows is small; everything else is unlimited:
    #
    #   Throttle.limit('http://localhost:8080', 1)        # llama-server --parallel 1
    #   Throttle.limit('https://api.openai.com/v1', nil)  # explicit "doesn't care"
    #
    # Usually a host sizes nothing: a conversation's turn probes llama.cpp's
    # +/props+ ({Probe}) and seeds its +total_slots+ through {.default}, so N
    # conversations against the default local server already queue. {.limit}
    # wins over any such default.
    #
    # One permit per HTTP request, streamed response and retries included —
    # never per turn: a turn spends seconds in tools while the server idles,
    # and a parent holding a turn-long permit would deadlock against the
    # sub-agent its tool spawns (+pikuri:D_llm_request_throttle+).
    #
    # Keys drop a trailing +/+ and +/v1+, as +ChatTransport.from_openai_server+
    # does, so +http://x:8080+ and +http://x:8080/v1/+ are one server.
    #
    # == Implementation details
    #
    # Process-wide rather than per {Conversations} list: what a permit protects
    # is the server, and two lists against one llama.cpp would each hand out its
    # slots (+pikuri:D_rate_limiter_scope+).
    #
    # Thread-safe.
    module Throttle
      # The permit object for a server nobody sized. Frozen, so a stray attempt
      # to hold state on it raises rather than rationing the wrong server.
      #
      # @return [Semaphore]
      UNLIMITED = Semaphore.new(nil).freeze

      @sizes = {}
      @explicit = {}
      @semaphores = {}
      @mutex = Mutex.new

      class << self
        # The +around_request:+ hook: run one request holding a permit for
        # +api_base+.
        #
        # @param api_base [String, nil] the base URL the request dials; +nil+
        #   (a fixed-base provider such as Anthropic) is unlimited
        # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] polled
        #   while parked on a permit
        # @yield the request
        # @return [Object] the block's value
        # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] if cancelled
        #   while parked, before the request is sent
        def call(api_base, cancellable, &request)
          self.for(api_base).acquire(cancellable:, &request)
        end

        # Size a server, overriding whatever {Probe} found.
        #
        # @param server [String] the server's base URL, with or without +/v1+
        # @param permits [Integer, nil] concurrent requests; +nil+ for unlimited
        # @return [void]
        # @raise [ArgumentError] on a non-positive or non-Integer +permits+, or a
        #   +server+ with nothing to key on
        def limit(server, permits)
          store(server, permits, explicit: true)
        end

        # Size a server unless it is sized already — the probe's door: the first
        # probe wins, and a host's {.limit} always wins.
        #
        # @param server [String] the server's base URL, with or without +/v1+
        # @param permits [Integer, nil] concurrent requests
        # @return [void]
        # @raise [ArgumentError] as {.limit}
        def default(server, permits)
          store(server, permits, explicit: false)
        end

        # @param server [String, nil] the server's base URL
        # @return [Semaphore] {UNLIMITED} for a server nobody sized — every
        #   cloud endpoint — and for no server at all
        def for(server)
          key = key_for(server)
          return UNLIMITED if key.nil?

          @mutex.synchronize do
            size = @sizes[key]
            next UNLIMITED if size.nil?

            @semaphores[key] ||= Semaphore.new(size)
          end
        end

        # Whether this server's concurrency is on record, from either door — a
        # recorded "unlimited" included.
        #
        # @param server [String, nil]
        # @return [Boolean] +false+ for a blank +server+
        def sized?(server)
          key = key_for(server)
          return false if key.nil?

          @mutex.synchronize { @sizes.key?(key) }
        end

        # @return [Hash{String => Integer, nil}] every sized server by key; a
        #   +nil+ value is an explicit "unlimited"
        def sizes
          @mutex.synchronize { @sizes.dup }
        end

        # Forget every size — a spec's +after+ hook, so one example's server
        # cannot ration another's.
        #
        # @return [void]
        def reset!
          @mutex.synchronize do
            @sizes.clear
            @explicit.clear
            @semaphores.clear
          end
          nil
        end

        # @param server [String, nil] a server base URL
        # @return [String, nil] +server+ without a trailing +/+ or +/v1+, or
        #   +nil+ when there is nothing to key on
        def key_for(server)
          key = server.to_s.strip.chomp('/').delete_suffix('/v1')
          key.empty? ? nil : key
        end

        private

        def store(server, permits, explicit:)
          unless permits.nil? || (permits.is_a?(Integer) && permits.positive?)
            raise ArgumentError, "permits must be a positive Integer or nil, got #{permits.inspect}"
          end

          key = key_for(server)
          raise ArgumentError, "no server to size in #{server.inspect}" if key.nil?

          @mutex.synchronize do
            next if !explicit && (@explicit[key] || @sizes.key?(key))

            # Dropping the memoized semaphore is what makes a re-size take
            # effect. A request holding a permit releases into the old one, so a
            # re-size under load briefly overlaps the two — accepted, since hosts
            # size at boot.
            @semaphores.delete(key) unless @sizes[key] == permits
            @sizes[key] = permits
            @explicit[key] = true if explicit
          end
          nil
        end
      end
    end
  end
end
