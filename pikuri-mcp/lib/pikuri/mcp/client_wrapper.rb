# frozen_string_literal: true

require 'mcp'

module Pikuri
  module Mcp
    # Wraps one +MCP::Client+ + its transport with retry-and-restart on
    # stdio-subprocess death. On construction it builds a fresh transport and
    # runs the +initialize+ handshake; on a subprocess-died {#call_tool} it
    # closes the dead transport, respawns, re-handshakes, and retries up to
    # {MAX_CALL_ATTEMPTS} times, after which the +RequestHandlerError+ propagates
    # (the synthesized tool's closure turns it into an +Error: ...+ observation).
    #
    # Only subprocess-death messages trigger the restart: once an stdio
    # subprocess dies, +MCP::Client::Stdio+ is irreversibly broken
    # (+@wait_thread.alive?+ stays false, every call raises from
    # +ensure_running!+), so restarting is the only way back. Other
    # +RequestHandlerError+s (protocol mismatch, JSON parse, ValidationError)
    # leave the transport usable — a restart would just retry the same mistake.
    # {Registry::HttpEntry} is accepted but no HTTP failure matches those
    # patterns, so the wrapper is a pass-through for HTTP.
    #
    # Lifecycle: if the handshake fails, {#initialize} closes its own half-opened
    # transport before re-raising — a caller who saw +ClientWrapper.new+ raise
    # need not close anything (fully-initialized object, or no object at all).
    class ClientWrapper
      LOGGER = Pikuri.logger_for('Mcp::ClientWrapper')
      private_constant :LOGGER

      # Maximum number of +call_tool+ attempts including the initial
      # one, before propagating the underlying exception. 3 means: one
      # normal try plus up to two restart-then-retry attempts.
      MAX_CALL_ATTEMPTS = 3

      # Substrings of +RequestHandlerError#message+ signalling "stdio subprocess
      # dead, transport unrecoverable" — all from the +mcp+ gem's
      # +client/stdio.rb+: exited +wait_thread+, broken write pipe (+EPIPE+), and
      # +gets+ → +nil+ on a closed stdout.
      SUBPROCESS_DEAD_PATTERNS = [
        'Server process has exited',
        'Failed to write to server process',
        'Server process closed stdout unexpectedly'
      ].freeze
      private_constant :SUBPROCESS_DEAD_PATTERNS

      # @return [Registry::StdioEntry, Registry::HttpEntry] the
      #   registry entry the wrapper builds (and rebuilds) transports
      #   from.
      attr_reader :entry

      # @return [MCP::Client] the *current* live client. Replaced on
      #   each restart, so callers must not cache this across
      #   {#call_tool} invocations. Exposed for one-shot boot-time
      #   reads of +server_info+ / +tools+ by {Servers}, {Verifier},
      #   {Synthesizer}, and {Cache}.
      attr_reader :client

      # @param entry [Registry::StdioEntry, Registry::HttpEntry] the
      #   configured server.
      # @raise [StandardError] anything raised by the underlying
      #   transport's spawn / +connect+ handshake. The half-opened
      #   transport is closed before the exception propagates.
      def initialize(entry)
        @entry = entry
        @closed = false
        spawn_fresh!
      end

      # Server's cached +InitializeResult+, as exposed by the
      # transport. Delegates to {#client}.
      #
      # @return [Hash, nil]
      def server_info
        @client.server_info
      end

      # Enumerate the server's tools via +MCP::Client#tools+. Each
      # call is a real round-trip — callers typically invoke this
      # once at boot and cache the result.
      #
      # @return [Array<MCP::Client::Tool>]
      def tools
        @client.tools
      end

      # Call an MCP tool. On a {SUBPROCESS_DEAD_PATTERNS} failure, restart and
      # retry up to {MAX_CALL_ATTEMPTS} times; other failures propagate on the
      # first attempt (JSON-RPC errors don't reach here — they ride in the
      # response Hash).
      #
      # @param tool [MCP::Client::Tool] from {#tools} at boot. Only +name+ is
      #   used at call time, so a reference captured before a restart keeps
      #   working if the new server still exposes that name.
      # @param arguments [Hash] passed verbatim to the underlying +call_tool+.
      # @return [Hash] the JSON-RPC response.
      # @raise [MCP::Client::RequestHandlerError] when retries exhaust, or on the
      #   first non-recoverable failure.
      def call_tool(tool:, arguments:)
        attempt = 1
        begin
          @client.call_tool(tool: tool, arguments: arguments)
        rescue MCP::Client::RequestHandlerError => e
          raise unless subprocess_dead?(e)
          raise if attempt >= MAX_CALL_ATTEMPTS

          LOGGER.warn(
            "MCP server #{@entry.id.inspect} subprocess died " \
            "(#{e.message.inspect}); restarting and retrying " \
            "(attempt #{attempt + 1}/#{MAX_CALL_ATTEMPTS})."
          )
          restart!
          attempt += 1
          retry
        end
      end

      # Close the underlying transport. Idempotent — subsequent calls
      # are no-ops. After close, {#call_tool} will fail on the dead
      # client.
      #
      # @return [void]
      def close
        return if @closed

        begin
          @transport&.close
        rescue StandardError => e
          LOGGER.warn(
            "Error closing MCP transport for #{@entry.id.inspect}: " \
            "#{e.class}: #{e.message}"
          )
        end
        @closed = true
      end

      private

      def spawn_fresh!
        @transport = build_transport
        begin
          @client = MCP::Client.new(transport: @transport)
          @client.connect
        rescue StandardError
          # Handshake (or the stdio spawn it triggers) failed — close the
          # half-opened state so a subprocess that popen3'd but failed handshake
          # doesn't leak.
          begin
            @transport.close
          rescue StandardError
            nil
          end
          raise
        end
      end

      def restart!
        begin
          @transport.close
        rescue StandardError
          # The old transport's subprocess is presumed dead — close
          # may raise (e.g. on an already-closed pipe). We don't
          # care: we're about to discard the transport anyway, and
          # the recovery is the fresh spawn below.
          nil
        end
        spawn_fresh!
      end

      def build_transport
        case @entry
        when Registry::StdioEntry
          MCP::Client::Stdio.new(
            command: @entry.command.first,
            args: @entry.command.drop(1),
            # De-bundlerized, or a Ruby-written server resolves its own gems
            # out of *pikuri's* bundle. The entry's own env wins over it.
            env: Pikuri::BundlerEnv.clean_delta.merge(@entry.env)
          )
        when Registry::HttpEntry
          MCP::Client::HTTP.new(url: @entry.url, headers: @entry.headers)
        else
          raise ArgumentError, "Unknown MCP entry type: #{@entry.class}"
        end
      end

      def subprocess_dead?(error)
        msg = error.message.to_s
        SUBPROCESS_DEAD_PATTERNS.any? { |pat| msg.include?(pat) }
      end
    end
  end
end
