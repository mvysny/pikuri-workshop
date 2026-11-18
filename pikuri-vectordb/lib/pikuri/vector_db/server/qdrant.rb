# frozen_string_literal: true

require 'fileutils'
require 'pathname'

module Pikuri
  module VectorDb
    module Server
      # Supervisor for a self-managed Qdrant podman/docker container — pairs with
      # {Backend::Qdrant} (this class owns the *process*; {#client} returns a
      # backend pre-pointed at it). Carries only the engine's *identity* and
      # composes a {Container} for the podman/docker work + shared rationale.
      #
      # *Port 6333 caveat:* +pikuri-memory+'s mem0 stack also
      # publishes its own internal Qdrant on host 6333 (a separate instance by
      # design), so running both at the defaults collides — pass a different
      # +port:+ here when the mem0 stack is up.
      class Qdrant
        # @return [String] pinned, fully qualified qdrant image; bump it to upgrade
        #   ({#ensure_running!} recreates the container on next boot, data dir
        #   untouched). **Kept in lockstep with
        #   +Pikuri::Memory::Mem0Server::DEFAULT_QDRANT_IMAGE+** so a host
        #   running both stacks holds one image; pikuri-memory's spec fails when
        #   they drift.
        IMAGE = 'docker.io/qdrant/qdrant:v1.12.4'

        # @return [String] container name; +"pikuri-internal-"+ namespace squat
        #   (see {Container}).
        CONTAINER_NAME = 'pikuri-internal-qdrant'

        # @return [String] container label.
        LABEL = 'pikuri.internal=true'

        # @return [String] the +-v+ target {#default_data_dir} bind-mounts onto
        #   — qdrant's documented storage root.
        CONTAINER_PERSIST_DIR = '/qdrant/storage'

        # @return [Integer] default host port, qdrant's native REST
        #   port. See the class header for the collision caveat
        #   with the mem0 stack's inspection port.
        DEFAULT_PORT = 6333

        # @return [Integer] default seconds to wait for the
        #   container's HTTP heartbeat to start returning 200 after
        #   +docker run+.
        DEFAULT_HEALTHCHECK_TIMEOUT = 30

        # Construct a server and immediately ensure it's running.
        # Convenience factory — equivalent to +new(...).tap(&:ensure_running!)+.
        #
        # @param data_dir [String, Pathname, nil] host path
        #   bind-mounted into the container's persist directory.
        #   +nil+ resolves to {#default_data_dir}. Created if missing.
        # @param port [Integer] host port bound to qdrant's 6333.
        #   Bound to 127.0.0.1 only.
        # @param healthcheck_timeout [Integer] seconds to poll
        #   +/healthz+ before giving up.
        # @return [Server::Qdrant]
        def self.ensure_running(data_dir: nil, port: DEFAULT_PORT,
                                healthcheck_timeout: DEFAULT_HEALTHCHECK_TIMEOUT)
          new(
            data_dir: data_dir, port: port,
            healthcheck_timeout: healthcheck_timeout
          ).tap(&:ensure_running!)
        end

        # @param data_dir [String, Pathname, nil] host path to
        #   bind-mount as qdrant's storage dir. +nil+ resolves to
        #   {#default_data_dir}.
        # @param port [Integer] host port to publish.
        # @param healthcheck_timeout [Integer]
        # @param connection [Faraday::Connection, nil] DI hook for
        #   tests. Production callers leave it +nil+.
        # @return [Server::Qdrant]
        def initialize(data_dir: nil, port: DEFAULT_PORT,
                       healthcheck_timeout: DEFAULT_HEALTHCHECK_TIMEOUT,
                       connection: nil)
          @data_dir = Pathname.new(data_dir || default_data_dir).expand_path
          @port = port
          @container = Container.new(
            name: CONTAINER_NAME, image: IMAGE, label: LABEL,
            host_port: port, container_port: 6333,
            volume: "#{@data_dir}:#{CONTAINER_PERSIST_DIR}",
            health_path: '/healthz',
            healthcheck_timeout: healthcheck_timeout,
            connection: connection
          )
          @finalizer_handle = nil
        end

        # @return [Pathname] host-side data directory.
        attr_reader :data_dir

        # @return [Integer] host-side port.
        attr_reader :port

        # @return [String] +"http://localhost:<port>"+. Useful for
        #   wiring custom +Backend::Qdrant+ constructions.
        def endpoint
          @container.endpoint
        end

        # Build a {Backend::Qdrant} pointing at the supervised
        # container. Constructor convenience — the supervisor
        # carries the host/port, the caller carries the collection
        # name.
        #
        # @param collection [String] Qdrant collection name.
        # @return [Backend::Qdrant]
        def client(collection:)
          Backend::Qdrant.new(host: 'localhost', port: @port, collection: collection)
        end

        # Idempotent: ensure a fresh container is running and healthy
        # (see {Container#ensure_running!} for the
        # reuse-or-recreate algorithm), then register {#close} with
        # {Pikuri::Finalizers} — once — so the container is removed
        # at process exit.
        #
        # @return [void]
        # @raise [RuntimeError] on missing podman and docker, any podman/docker
        #   command failure, or healthcheck timeout.
        def ensure_running!
          FileUtils.mkdir_p(@data_dir)
          @container.ensure_running!
          @finalizer_handle ||= Pikuri::Finalizers.register(self)
          nil
        end

        # Remove the supervised container, leaving the bind-mounted {#data_dir}
        # (the corpus survives). Best-effort and idempotent — see
        # {Container#close}.
        #
        # @return [void]
        def close
          @container.close
        end

        # Default host-side data directory
        # (+$XDG_CACHE_HOME/pikuri/qdrant+, else +~/.cache/pikuri/qdrant+).
        # Public so tests and chapter examples reference the same path.
        #
        # @return [String]
        def default_data_dir
          Pikuri::Paths.cache.join('qdrant').to_s
        end
      end
    end
  end
end
