# frozen_string_literal: true

require 'faraday'
require 'fileutils'
require 'pathname'
require 'uri'

module Pikuri
  module Memory
    # Supervisor for a self-managed mem0 + Qdrant sidecar. This class owns
    # the *stack* (clone + patch the mem0 source, +docker compose up
    # --build+, heartbeat-poll, tear down); {Mem0Client} owns the HTTP
    # client, and {#client} returns one pre-pointed at the running server.
    # A host already running mem0 elsewhere skips this class and wires
    # {Mem0Client.new(endpoint:)} directly (the +Server::Chroma+-shaped
    # let-pikuri-manage-it vs bring-your-own choice).
    #
    #   Mem0Server.ensure_running(router_url: 'http://localhost:8080/v1',
    #                             llm_model: 'qwen2.5-7b', embedder_model: 'nomic')
    #             .client   # => a Mem0Client pointed at 127.0.0.1:8888
    #
    # == Why a compose stack, not a single +docker run+
    #
    # mem0's REST server has no usable published image (the Docker Hub
    # one is pre-v3), so it is *built from source*, and it needs Qdrant as
    # a second container. Two interdependent services with a build step is
    # what +docker compose+ models — driven here (through
    # {Pikuri::Subprocess.spawn}) over the compose file in the gem's
    # +docker/+ directory.
    #
    # == No Postgres; Qdrant, patched in at build
    #
    # Upstream's +DEFAULT_CONFIG+ hardcodes **pgvector**, whose mem0
    # provider has a top-k inversion bug (cosine *distance* ranked as a
    # *similarity*) *and* connects to Postgres eagerly at boot.
    # {#prepare_checkout!} applies +docker/qdrant-default-config.patch+ to
    # swap the default to **Qdrant** (env-driven host/port/dims) — correct
    # ranking *and* a Postgres-free stack. See design/architecture.md §"Root cause: the
    # pgvector top-k inversion".
    #
    # == Local LLM + embedder via the router
    #
    # mem0's provider validation accepts only +openai+/+anthropic+/+gemini+
    # (LLM) and +openai+/+gemini+ (embedder), so the local path keeps
    # +provider: "openai"+ and points +OPENAI_BASE_URL+ at the llama.cpp
    # router. The extraction model must be **non-reasoning** (e.g.
    # +Qwen2.5-7B-Instruct+) — a thinking model burns its budget on CoT
    # and returns empty/truncated JSON (design/architecture.md §"Extraction model
    # decision"). The vector store is not bundle-gated, so Qdrant is fine.
    #
    # == The router relay (container → host loopback)
    #
    # The LLM + embedder calls originate *inside* the container, but the
    # router conventionally binds the host's +127.0.0.1:8080+ — which
    # rootless docker refuses to route containers to
    # (+--disable-host-loopback+; re-enabling it daemon-wide would hand
    # *every* container, incl. untrusted MCP ones, a path to *every*
    # loopback-bound host service: CUPS, trust-auth Postgres, an
    # unauthenticated Redis…). Instead the supervisor builds a scoped hole:
    #
    # 1. Host side: +socat UNIX-LISTEN:<sock_dir>/router.sock,… TCP:<router>+,
    #    spawned as a daemon child (never +#wait+ed; stopped with
    #    +Subprocess#terminate+, swept by the exit reaper as a backstop).
    # 2. The compose stack's +router-proxy+ sidecar (pinned {SOCAT_IMAGE})
    #    bind-mounts the socket *directory* and relays it onto the
    #    stack-internal network as +http://router-proxy:8080+.
    # 3. mem0's +OPENAI_BASE_URL+ points at that sidecar.
    #
    # The socket *file* is the capability: only a container that mounts it
    # reaches the router, the host loopback stays sealed for everything
    # else, and the wiring is identical on rootful and rootless daemons.
    # The relay speaks plain TCP, so +router_url+ must be +http://+; an
    # +https+ router needs +container_router_url:+ (bypasses the relay,
    # caller's routing problem).
    #
    # == Pinned + patched checkout
    #
    # Built from {MEM0_REF} (a pinned commit), cloned once and reused. The
    # patch is applied with +git apply+ and is **fail-loud**: if it
    # neither applies cleanly nor is already applied, {#prepare_checkout!}
    # raises rather than build a wrong image.
    #
    # Both published ports bind +127.0.0.1+ only — the memory never
    # listens on a routable interface. Boot errors (missing docker/git,
    # build failure, healthcheck timeout) raise +RuntimeError+ with the
    # offending output; teardown failures are logged, not raised.
    class Mem0Server
      LOGGER = Pikuri.logger_for('Memory::Mem0Server')

      # @return [String] mem0 git remote the server is built from.
      MEM0_REPO_URL = 'https://github.com/mem0ai/mem0.git'

      # @return [String] pinned mem0 commit the image is built from
      #   (library 2.0.4, v3 token-efficient algorithm). Bumping this is
      #   how the mem0 version is upgraded — and the shipped patch must be
      #   regenerated against the new ref if +DEFAULT_CONFIG+ moved.
      MEM0_REF = 'a3154d59e52386d4e1189c1f5f44819868f76514'

      # @return [String] compose project name. The +pikuri-internal-+
      #   prefix is the namespace pikuri squats for self-managed infra.
      COMPOSE_PROJECT = 'pikuri-internal-mem0'

      # @return [String] absolute path to the shipped compose file.
      COMPOSE_FILE = File.expand_path('../../../docker/docker-compose.yml', __dir__)

      # @return [String] absolute path to the shipped DEFAULT_CONFIG
      #   pgvector→qdrant patch.
      PATCH_FILE = File.expand_path('../../../docker/qdrant-default-config.patch', __dir__)

      # @return [Integer] default host port mem0's REST API binds (127.0.0.1).
      DEFAULT_PORT = 8888

      # @return [Integer] default host port Qdrant binds (127.0.0.1),
      #   published for inspection only.
      DEFAULT_QDRANT_PORT = 6333

      # @return [Integer] default embedding dimension. 768 matches
      #   +nomic-embed-text-v1.5+; must equal the embedder's output dim or
      #   Qdrant rejects upserts.
      DEFAULT_EMBEDDING_DIMS = 768

      # @return [String] default Qdrant collection name.
      DEFAULT_COLLECTION = 'pikuri_memory'

      # @return [String] pinned Qdrant image. **Kept in lockstep with
      #   +Pikuri::VectorDb::Server::Qdrant::IMAGE+** (same tag → one
      #   image on disk for a host running both stacks). A convention,
      #   not a shared constant (the gems don't depend on each other);
      #   bump both together.
      DEFAULT_QDRANT_IMAGE = 'qdrant/qdrant:v1.12.4'

      # @return [Integer] seconds to wait for the REST API to answer after
      #   +compose up+ returns. Covers container-start readiness only —
      #   the first-run image build (minutes) is inside the blocking
      #   +--build+ call, not this poll.
      DEFAULT_HEALTHCHECK_TIMEOUT = 60

      # @return [String] pinned socat image for the +router-proxy+ sidecar
      #   (class header's "router relay"). Bumped manually.
      SOCAT_IMAGE = 'alpine/socat:1.8.0.3'

      # @return [String] socket filename inside {#sock_dir}; the sidecar
      #   sees it as +/sock/router.sock+.
      RELAY_SOCKET = 'router.sock'

      # @return [Integer] seconds to wait for the host-side socat to bind
      #   the relay socket. Binding is immediate in practice; the timeout
      #   fails loud when socat dies on startup (bad address, port typo)
      #   rather than surfacing later as silent extraction failures.
      RELAY_BIND_TIMEOUT = 5

      # Construct and immediately ensure the stack is running.
      # Convenience factory — +new(...).tap(&:ensure_running!)+.
      #
      # @return [Mem0Server]
      def self.ensure_running(**kwargs)
        new(**kwargs).tap(&:ensure_running!)
      end

      # @param router_url [String] llama.cpp OpenAI-compatible base URL
      #   *as seen from the host* (e.g. +"http://localhost:8080/v1"+) the
      #   mem0 server routes its LLM + embedder calls to. Must be
      #   +http://+ — the relay (class header) carries it into the
      #   container, so a loopback-bound router is fine.
      # @param llm_model [String] extraction model id on the router. Must
      #   be **non-reasoning** (see the class header).
      # @param embedder_model [String] embedder model id on the router.
      # @param container_router_url [String, nil] escape hatch: router
      #   base URL *as seen from inside the mem0 container*. When set,
      #   the relay is not spawned and routing the container to this URL
      #   is the caller's problem (e.g.
      #   +"http://host.docker.internal:8080/v1"+ on a rootful daemon, or
      #   an +https+ router on a routable address). Default +nil+ — use
      #   the relay.
      # @param port [Integer] host port for the REST API (127.0.0.1).
      # @param qdrant_port [Integer] host port for Qdrant (127.0.0.1).
      # @param embedding_dims [Integer] embedder output dimension.
      # @param collection [String] Qdrant collection name.
      # @param qdrant_image [String] Qdrant docker image.
      # @param cache_dir [String, Pathname, nil] where the mem0 checkout
      #   lives. +nil+ resolves to {#default_cache_dir}.
      # @param healthcheck_timeout [Integer] seconds to poll readiness.
      # @param connection [Faraday::Connection, nil] DI hook for tests.
      # @return [Mem0Server]
      # @raise [ArgumentError] when +router_url+ is not +http://+ and no
      #   +container_router_url+ is given (the TCP relay can't originate
      #   TLS).
      def initialize(router_url:, llm_model:, embedder_model:, container_router_url: nil,
                     port: DEFAULT_PORT, qdrant_port: DEFAULT_QDRANT_PORT,
                     embedding_dims: DEFAULT_EMBEDDING_DIMS, collection: DEFAULT_COLLECTION,
                     qdrant_image: DEFAULT_QDRANT_IMAGE, cache_dir: nil,
                     healthcheck_timeout: DEFAULT_HEALTHCHECK_TIMEOUT, connection: nil)
        @router_url = router_url
        @container_router_url = container_router_url
        if container_router_url.nil? && URI(router_url).scheme != 'http'
          raise ArgumentError, "Mem0Server: the socat relay carries plain TCP, so router_url must be " \
                               "http:// (got #{router_url.inspect}). For an https router, pass " \
                               'container_router_url: with an address the container can route to.'
        end
        @llm_model = llm_model
        @embedder_model = embedder_model
        @port = port
        @qdrant_port = qdrant_port
        @embedding_dims = embedding_dims
        @collection = collection
        @qdrant_image = qdrant_image
        @cache_dir = Pathname.new(cache_dir || default_cache_dir).expand_path
        @healthcheck_timeout = healthcheck_timeout
        @connection = connection
        @closed = false
        @finalizer_handle = nil
        @relay = nil
      end

      # @return [Integer] host port the REST API binds.
      attr_reader :port

      # @return [Pathname] the mem0 source checkout (the image build
      #   context). Under +temp/+ — it is a regenerable clone, not data.
      def checkout_dir
        @cache_dir.join('temp', 'git')
      end

      # @return [Pathname] host directory bind-mounted into the containers
      #   for persistent state — +data/qdrant+ holds the Qdrant corpus,
      #   +data/history+ the memory-history SQLite. Survives the ephemeral
      #   containers.
      def data_dir
        @cache_dir.join('data')
      end

      # @return [Pathname] host directory holding the relay's unix socket,
      #   bind-mounted into the +router-proxy+ sidecar. The *directory* is
      #   what's mounted — a restarted host-side socat re-creates the
      #   socket file, and a file bind-mount would pin the stale inode.
      def sock_dir
        @cache_dir.join('sock')
      end

      # @return [String] +"http://localhost:<port>"+.
      def endpoint
        "http://localhost:#{@port}"
      end

      # Build a {Mem0Client} pointed at the supervised server.
      #
      # @return [Mem0Client]
      def client
        Mem0Client.new(endpoint: endpoint, connection: @connection)
      end

      # Idempotent: ensure the checkout exists + is patched, bring the
      # compose stack up (building the image on first run), heartbeat-poll
      # the REST API until ready, then register {#close} with
      # {Pikuri::Finalizers} so the stack is stopped at process exit.
      #
      # @return [void]
      # @raise [RuntimeError] on missing docker/git, clone/patch failure,
      #   +compose up+ failure, or healthcheck timeout.
      def ensure_running!
        prepare_checkout!
        # Pre-create the bind-mount sources so docker doesn't create them
        # root-owned (and so a missing dir isn't silently a fresh volume).
        FileUtils.mkdir_p(data_dir.join('qdrant'))
        FileUtils.mkdir_p(data_dir.join('history'))
        FileUtils.mkdir_p(sock_dir, mode: 0o700)
        start_relay! unless @container_router_url
        begin
          LOGGER.info("starting #{COMPOSE_PROJECT} (mem0 + Qdrant + relay) on 127.0.0.1:#{@port}; " \
                      'first run builds the mem0 image and may take a few minutes')
          compose!('up', '-d', '--build')
          wait_for_healthy!
        rescue StandardError
          # Self-heal: don't leave the relay as a stray when the stack
          # never came up (same discipline as Agent's build-phase rescue).
          stop_relay!
          raise
        end
        register_for_cleanup
      end

      # Stop the stack (+docker compose down+), leaving {#data_dir}'s
      # bind-mounted host directories — the Qdrant corpus and memory
      # history survive. Registered with
      # {Pikuri::Finalizers} by {#ensure_running!}; safe to call directly.
      # Best-effort and idempotent: a non-zero +down+ is logged, not
      # raised (teardown shouldn't abort on an already-gone stack).
      #
      # @return [void]
      def close
        return if @closed

        @closed = true
        result = compose('down')
        stop_relay!
        return if result.status.success?

        LOGGER.warn("docker compose down failed (exit #{result.status.exitstatus}): #{result.output.strip}")
      end

      # Default cache root for this supervisor: +<Pikuri::Paths.cache>/mem0+
      # (+$XDG_CACHE_HOME/pikuri/mem0+ or +~/.cache/pikuri/mem0+), holding
      # +temp/git+ (the checkout) and +data/+ (the bind-mounted corpus +
      # history).
      #
      # @return [String]
      def default_cache_dir
        Pikuri::Paths.cache.join('mem0').to_s
      end

      private

      # Clone mem0 at {MEM0_REF} (once) and apply the Qdrant patch
      # (idempotently, fail-loud). Reused across runs — a populated,
      # already-patched checkout is a no-op.
      def prepare_checkout!
        ensure_clone!
        apply_patch!
      end

      # Shallow-fetch the pinned commit into {#checkout_dir} if not already
      # there. GitHub serves a fetch-by-SHA, so this stays a one-commit
      # fetch rather than a full clone.
      def ensure_clone!
        dir = checkout_dir
        return if dir.join('.git').directory? && git('rev-parse', 'HEAD', chdir: dir).output.strip == MEM0_REF

        LOGGER.info("fetching mem0 @ #{MEM0_REF[0, 12]} into #{dir}")
        FileUtils.mkdir_p(dir)
        run_loud!(git('init', '-q', chdir: dir), 'git init')
        # `remote add` is non-idempotent; ignore its failure (already added).
        git('remote', 'add', 'origin', MEM0_REPO_URL, chdir: dir)
        run_loud!(git('fetch', '--depth', '1', 'origin', MEM0_REF, chdir: dir),
                  "git fetch #{MEM0_REF}")
        run_loud!(git('checkout', '-q', '--detach', 'FETCH_HEAD', chdir: dir),
                  'git checkout FETCH_HEAD')
      end

      # Apply {PATCH_FILE} unless it is already applied. Fail loud if it
      # neither applies cleanly nor is already present (upstream drift
      # past the pinned ref) — never build a wrong image silently.
      def apply_patch!
        dir = checkout_dir
        return if git('apply', '--reverse', '--check', PATCH_FILE, chdir: dir).status.success?

        result = git('apply', PATCH_FILE, chdir: dir)
        return if result.status.success?

        raise "Mem0Server: failed to apply #{PATCH_FILE} to mem0 @ #{MEM0_REF} " \
              "(exit #{result.status.exitstatus}): #{result.output.strip}. " \
              'The pinned ref or the patch may have drifted; regenerate the patch.'
      end

      # Run +docker compose+ with the supervisor's env, raising on
      # failure. Used for +up+ (boot — loud).
      def compose!(*args)
        run_loud!(compose(*args), "docker compose #{args.join(' ')}")
      end

      # Run +docker compose+ with the supervisor's env, returning the
      # {Pikuri::Subprocess::Result} (caller decides loud vs quiet). Used
      # for +down+ (teardown — quiet).
      def compose(*args)
        docker('compose', '-p', COMPOSE_PROJECT, '-f', COMPOSE_FILE, *args, env: compose_env)
      end

      # Environment the compose file interpolates (+${PIKURI_*}+) — the
      # checkout path as the build context plus the router + model wiring.
      # +PIKURI_ROUTER_URL+ is the router URL *as the container sees it*:
      # the relay sidecar's address, unless +container_router_url:+
      # overrode the routing.
      def compose_env
        {
          'PIKURI_MEM0_SRC' => checkout_dir.to_s,
          'PIKURI_DATA_DIR' => data_dir.to_s,
          'PIKURI_SOCK_DIR' => sock_dir.to_s,
          'PIKURI_SOCAT_IMAGE' => SOCAT_IMAGE,
          'PIKURI_ROUTER_URL' => container_router_url,
          'PIKURI_LLM_MODEL' => @llm_model,
          'PIKURI_EMBEDDER_MODEL' => @embedder_model,
          'PIKURI_MEM0_PORT' => @port.to_s,
          'PIKURI_QDRANT_PORT' => @qdrant_port.to_s,
          'PIKURI_QDRANT_IMAGE' => @qdrant_image,
          'PIKURI_COLLECTION' => @collection,
          'PIKURI_EMBEDDING_DIMS' => @embedding_dims.to_s
        }
      end

      # Router base URL as seen from inside the mem0 container: the
      # explicit override, or the relay sidecar with +router_url+'s path
      # (normally +/v1+) carried over.
      def container_router_url
        @container_router_url || "http://router-proxy:8080#{URI(@router_url).path}"
      end

      # Spawn the host-side half of the router relay (class header):
      # +socat+ listening on the unix socket, forwarding to the router's
      # TCP address. A daemon child, never +#wait+ed; a drain thread keeps
      # its pipe from filling. Fails loud if the socket doesn't appear
      # within {RELAY_BIND_TIMEOUT}.
      def start_relay!
        uri = URI(@router_url)
        sock = sock_dir.join(RELAY_SOCKET)
        LOGGER.info("relay: socat #{sock} → #{uri.host}:#{uri.port}")
        @relay = Pikuri::Subprocess.spawn(
          'socat',
          "UNIX-LISTEN:#{sock},fork,unlink-early,mode=600",
          "TCP:#{uri.host}:#{uri.port}",
          chdir: '/'
        )
        drain_relay_output!
        wait_for_relay_socket!(sock)
      rescue Errno::ENOENT
        raise 'Mem0Server: `socat` not found on PATH — the relay that lets the mem0 ' \
              'container reach the host router needs it. Install it (sudo apt install ' \
              'socat), or pass container_router_url: to route the container yourself.'
      end

      # Log whatever socat prints (errors only, in practice) and keep the
      # pipe from blocking the child. Ends at EOF when the relay exits.
      def drain_relay_output!
        relay = @relay
        Thread.new do
          relay.io.each_line { |line| LOGGER.warn("relay: #{line.chomp}") }
        rescue IOError
          # pipe closed mid-read during teardown — fine
        ensure
          relay.io.close unless relay.io.closed?
        end
      end

      # Poll until socat has bound the socket, failing loud on timeout
      # (see {RELAY_BIND_TIMEOUT}).
      def wait_for_relay_socket!(sock)
        deadline = Time.now + RELAY_BIND_TIMEOUT
        until File.socket?(sock)
          if Time.now > deadline
            raise "Mem0Server: relay socket #{sock} did not appear within " \
                  "#{RELAY_BIND_TIMEOUT}s — socat failed to start (see 'relay:' log lines)"
          end
          sleep 0.05
        end
      end

      # SIGTERM the relay's process group. Idempotent; nil-safe for the
      # +container_router_url:+ path where no relay was spawned.
      def stop_relay!
        @relay&.terminate
        @relay = nil
      end

      # Poll the REST API's +/docs+ (FastAPI serves it once startup —
      # including Qdrant collection creation — completes) until 200 or the
      # timeout elapses. Connection errors during the wait are normal
      # (the container takes a moment to bind) and just feed the loop.
      def wait_for_healthy!
        deadline = Time.now + @healthcheck_timeout
        last_error = 'no attempts'

        until Time.now > deadline
          begin
            response = http.get('/docs')
            return if response.status == 200

            last_error = "HTTP #{response.status}"
          rescue Faraday::Error => e
            last_error = "#{e.class.name.split('::').last}: #{e.message}"
          end
          sleep 0.5
        end

        raise "Mem0Server: #{COMPOSE_PROJECT} did not become healthy within " \
              "#{@healthcheck_timeout}s at #{endpoint} (last: #{last_error})"
      end

      # Heartbeat-poll connection. Uses the injected +connection:+ when
      # given (DI for tests), else a fresh plain connection against the
      # endpoint.
      def http
        @http ||= @connection || Faraday.new(url: endpoint) do |f|
          f.adapter Faraday.default_adapter
        end
      end

      # Register {#close} with the process-global teardown registry, once.
      def register_for_cleanup
        @finalizer_handle ||= Pikuri::Finalizers.register(self)
      end

      # +docker+ chokepoint — routes through {Pikuri::Subprocess.spawn}
      # (subprocess seam). Surfaces a clearer message when docker is absent.
      def docker(*argv, env: {})
        Pikuri::Subprocess.spawn('docker', *argv, chdir: '/', env: env).wait
      rescue Errno::ENOENT
        raise 'Mem0Server: `docker` not found on PATH. Install docker (with the ' \
              'compose plugin), or point Mem0Client at an existing mem0 endpoint ' \
              'via Pikuri::Memory::Mem0Client.new(endpoint:).'
      end

      # +git+ chokepoint — routes through {Pikuri::Subprocess.spawn}.
      def git(*argv, chdir:)
        Pikuri::Subprocess.spawn('git', *argv, chdir: chdir.to_s).wait
      rescue Errno::ENOENT
        raise 'Mem0Server: `git` not found on PATH. Install git, or point ' \
              'Mem0Client at an existing mem0 endpoint.'
      end

      # Raise with the command's output if +result+ is non-zero.
      def run_loud!(result, what)
        return result if result.status.success?

        raise "Mem0Server: #{what} failed (exit #{result.status.exitstatus}): #{result.output.strip}"
      end
    end
  end
end
