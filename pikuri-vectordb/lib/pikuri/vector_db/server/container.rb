# frozen_string_literal: true

require 'faraday'

module Pikuri
  module VectorDb
    module Server
      # Lifecycle engine for one named, disposable podman/docker container with persistent
      # bind-mounted data, composed by {Server::Qdrant}. The supervisor carries the engine's identity
      # (image pin, name, persist/heartbeat paths) as constructor parameters;
      # this class does the podman/docker work: create/recreate/remove, publish the
      # port, heartbeat-poll until ready.
      #
      # == Podman or docker
      #
      # {.runtime} picks +podman+ when it is on +PATH+, else +docker+. Podman
      # first because it runs rootless and daemonless by default, which is the
      # posture the book asks docker users to set up by hand (the +docker+
      # group is passwordless root). Every command below is one both CLIs
      # accept verbatim; image pins are fully qualified (+docker.io/...+)
      # because podman refuses a short name it can't resolve unambiguously.
      #
      # == Namespace squat: pikuri-internal-*
      #
      # Containers are named +"pikuri-internal-<engine>"+ with a
      # +pikuri.internal=true+ label, and are treated as fully pikuri-owned —
      # wrong image, stopped, or crash-orphaned, they are removed and recreated
      # on the pinned image without ceremony. The bind-mounted data volume is
      # *not* nuked — the corpus is the user's even when its container is
      # replaced. The convention scales to any future +pikuri-internal-*+.
      #
      # == Ephemeral container, persistent data
      #
      # All engine state lives on the host volume, so the container carries
      # nothing worth keeping: {#ensure_running!} *recreates* it every boot,
      # except one this instance already started and left running (reused, so
      # repeated calls stay cheap). Anything else — stopped, or running from a
      # previous run / crash / concurrent pikuri — is removed and recreated
      # rather than adopted: a fresh container on the pinned image against the
      # persistent volume is always a clean start with no image tag to
      # reconcile. {#close} +rm -f+s it. The single-named-container
      # convention assumes one active pikuri at a time.
      #
      # Podman/docker shell-outs route through {Pikuri::Subprocess.spawn} per the
      # subprocess seam — this class is *not* the seam's exception. The
      # port publish is built +-p 127.0.0.1:<host>:<container>+, never the docker
      # default (which binds every interface and would expose the corpus to the
      # LAN) — centralized here as the single privacy enforcement point. Errors
      # are loud at boot (no container CLI, +run+ non-zero, healthcheck timeout →
      # +RuntimeError+ — internal caller, bug territory) and quiet at teardown
      # ({#close} best-effort, logs instead of raising).
      class Container
        LOGGER = Pikuri.logger_for('VectorDb::Server')

        # The CLI this process drives, chosen once: +podman+ if on
        # +PATH+, else +docker+ (which may be missing too — the first command
        # then raises naming both). See "Podman or docker".
        #
        # @return [String] +"podman"+ or +"docker"+
        def self.runtime
          @runtime ||= %w[podman docker].find { |bin| on_path?(bin) } || 'docker'
        end

        # @param bin [String]
        # @return [Boolean]
        def self.on_path?(bin)
          ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
            File.executable?(File.join(dir, bin))
          end
        end
        private_class_method :on_path?

        # @param name [String] container name, e.g.
        #   +"pikuri-internal-qdrant"+ — see "Namespace squat" in the
        #   class header.
        # @param image [String] pinned, fully qualified image, e.g.
        #   +"docker.io/qdrant/qdrant:v1.12.4"+.
        # @param label [String] label set on the container,
        #   e.g. +"pikuri.internal=true"+.
        # @param host_port [Integer] host port to publish, bound to
        #   127.0.0.1 only.
        # @param container_port [Integer] the engine's port inside
        #   the container, e.g. +6333+ for qdrant.
        # @param volume [String] full +-v+ bind-mount argument,
        #   +"<host dir>:<container persist dir>"+. The host side
        #   must exist before {#ensure_running!} (the supervisor
        #   +mkdir_p+s it — docker would otherwise create it
        #   root-owned).
        # @param health_path [String] HTTP path heartbeat-polled
        #   until it returns 200, e.g. +"/healthz"+.
        # @param healthcheck_timeout [Integer] seconds to poll
        #   +health_path+ before giving up.
        # @param connection [Faraday::Connection, nil] DI hook for
        #   tests. Production callers leave it +nil+.
        # @return [Container]
        def initialize(name:, image:, label:, host_port:, container_port:,
                       volume:, health_path:, healthcheck_timeout:,
                       connection: nil)
          @name = name
          @image = image
          @label = label
          @host_port = host_port
          @container_port = container_port
          @volume = volume
          @health_path = health_path
          @healthcheck_timeout = healthcheck_timeout
          @connection = connection
          @owns_container = false
          @closed = false
        end

        # @return [String] container name.
        attr_reader :name

        # @return [String] +"http://localhost:<host_port>"+.
        def endpoint
          "http://localhost:#{@host_port}"
        end

        # Idempotent: ensure a fresh container is running, then heartbeat-poll
        # until ready. One this instance already started is reused; anything
        # else is removed (if present) and recreated on the pinned image. See
        # "Ephemeral container, persistent data".
        #
        # @return [void]
        # @raise [RuntimeError] on a missing container CLI, any command failure,
        #   or healthcheck timeout.
        def ensure_running!
          state = container_state
          if @owns_container && state == :running
            LOGGER.info("#{@name} already running")
          else
            remove_container! unless state == :missing
            run_container!
          end

          @owns_container = true
          @closed = false
          wait_for_healthy!
        end

        # Remove the container (+rm -f+), leaving the
        # bind-mounted host volume — the data survives. Best-effort
        # and idempotent: a no-op if this instance never started a
        # container or has already closed, and a non-zero +rm+ is
        # logged rather than raised — that's teardown, boot is loud.
        #
        # @return [void]
        def close
          return if @closed || !@owns_container

          @closed = true
          result = cli('rm', '-f', @name)
          return if result.status.success?

          LOGGER.warn(
            "#{self.class.runtime} rm -f #{@name} failed " \
            "(exit #{result.status.exitstatus}): #{result.output.strip}"
          )
        end

        private

        # Inspect the container by name. Returns one of +:missing+ /
        # +:stopped+ / +:running+. +inspect+ exits non-zero
        # when the container doesn't exist. The image tag is *not*
        # consulted: a wrong-image container falls into the same
        # remove-and-recreate path as any other non-owned container
        # (see {#ensure_running!}), so there is nothing to branch on.
        def container_state
          result = cli('inspect', '--format', '{{.State.Running}}', @name)
          return :missing unless result.status.success?

          result.output.strip == 'true' ? :running : :stopped
        end

        def run_container!
          LOGGER.info(
            "starting #{@name} (#{@image}) with #{self.class.runtime} on 127.0.0.1:#{@host_port}, " \
            "volume: #{@volume}"
          )
          result = cli(
            'run', '-d',
            '--name', @name,
            '--label', @label,
            '-p', "127.0.0.1:#{@host_port}:#{@container_port}",
            '-v', @volume,
            @image
          )
          return if result.status.success?

          raise "#{@name}: #{self.class.runtime} run failed " \
                "(exit #{result.status.exitstatus}): #{result.output.strip}"
        end

        def remove_container!
          result = cli('rm', '-f', @name)
          return if result.status.success?

          raise "#{@name}: #{self.class.runtime} rm -f failed " \
                "(exit #{result.status.exitstatus}): #{result.output.strip}"
        end

        # Poll +GET <health_path>+ until 200 or
        # +@healthcheck_timeout+ elapses. 500ms between attempts.
        # Faraday connection errors during the wait are normal (the
        # container's HTTP listener takes a few seconds to bind on
        # cold start); they don't propagate, just feed the loop. Only
        # the final timeout raises.
        def wait_for_healthy!
          deadline = Time.now + @healthcheck_timeout
          last_error = 'no attempts'

          until Time.now > deadline
            begin
              response = http.get(@health_path)
              return if response.status == 200

              last_error = "HTTP #{response.status}"
            rescue Faraday::Error => e
              last_error = "#{e.class.name.split('::').last}: #{e.message}"
            end
            sleep 0.5
          end

          raise "#{@name}: did not become healthy within " \
                "#{@healthcheck_timeout}s at #{endpoint} (last: #{last_error})"
        end

        def http
          @connection ||= Faraday.new(url: endpoint) do |f|
            f.request :json
            f.response :json
            f.adapter Faraday.default_adapter
          end
        end

        # Single chokepoint for every container-CLI invocation. Routes
        # through {Pikuri::Subprocess.spawn} per the subprocess
        # seam; rescues +Errno::ENOENT+ to surface a clearer
        # message when neither CLI is installed.
        def cli(*argv)
          Pikuri::Subprocess.spawn(self.class.runtime, *argv, chdir: '/').wait
        rescue Errno::ENOENT
          raise "#{@name}: neither `podman` nor `docker` found on PATH. Install one, " \
                'or point the engine Backend at a server you run yourself ' \
                '(e.g. Backend::Qdrant.new(host:, port:, collection:)).'
        end
      end
    end
  end
end
