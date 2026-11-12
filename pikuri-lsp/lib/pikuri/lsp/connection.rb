# frozen_string_literal: true

require 'json'

module Pikuri
  module Lsp
    # LSP's JSON-RPC channel over one pair of IOs: framing, a reader thread
    # that demuxes replies by id, and the answer every server-initiated request
    # needs. Given a subprocess's stdin/stdout it turns an asynchronous
    # bidirectional stream into a blocking {#request} plus a fire-and-forget
    # {#notify}:
    #
    #   conn = Connection.new(stdin: child_in, stdout: child_out, server_id: 'ruby')
    #   conn.on_notification do |method, params|
    #     puts params['message'] if method == 'window/logMessage'
    #   end
    #   caps = conn.request('initialize', { processId: Process.pid, rootUri: root_uri })
    #   conn.notify('initialized', {})
    #   conn.request('textDocument/definition', params, cancellable: cancellable)
    #   conn.close
    #
    # It knows no LSP vocabulary — no handshake, no capabilities, no document
    # state — and it spawns nothing: the IO pair arrives from outside, which is
    # what lets a fake server drive it over +IO.pipe+ in-process.
    #
    # == There is no timeout
    #
    # {#request} blocks until the server answers, however long that takes: a
    # cold jdtls import is minutes, and no defensible number separates "slow
    # index" from "hung". Two things replace the clock here — the child's death
    # (EOF on stdout ends the wait with {Closed}) and the +cancellable:+ poll,
    # which makes the human the timeout via Ctrl+C. The third is the server's
    # own progress notifications, which a handler turns into {ServerProgress} so
    # that a long wait at least looks like one.
    #
    # == Implementation details
    #
    # Server→client requests (+window/workDoneProgress/create+,
    # +workspace/configuration+, +client/registerCapability+) are answered
    # +result: null+ from the reader thread, because a server may *block* on the
    # reply and would then never answer the request pikuri is waiting for. No
    # hook to supply a real result: both measured servers proceed fine, and an
    # invented answer is worse than none.
    #
    # A JSON-RPC +error+ member is a {ServerError}, distinct from any other
    # failure on purpose — "the server refused this method" (ruby-lsp answers
    # +Method not found+ for an operation it never advertised) must not read
    # like "the server answered nothing".
    #
    # == Thread-safety
    #
    # Thread-safe, which is the point: one reader thread owns +stdout+ while any
    # number of callers write and wait. Notification handlers are the exception
    # to watch — they run on the *reader* thread, so a handler must not touch
    # anything thread-confined. Park the value there and let the waiting thread
    # pick it up.
    class Connection
      LOGGER = Pikuri.logger_for('Lsp::Connection')
      private_constant :LOGGER

      # How often a blocked {#request} wakes to re-check +cancellable+.
      POLL_INTERVAL = 0.1

      # How long {#close} waits for the reader thread to notice its IOs went
      # away before giving up on it.
      CLOSE_JOIN_TIMEOUT = 2

      # Raised when the channel is gone: the child died, the stream hit EOF
      # mid-message, a write failed, or {#close} was called. Terminal for this
      # object — the reason lives in the message and in {#dead_reason}, and
      # getting a working channel back means building another one.
      class Closed < StandardError; end

      # A JSON-RPC +error+ response. Not a bug in pikuri — the server
      # understood the frame and refused the call.
      class ServerError < StandardError
        # @return [Integer] JSON-RPC error code, e.g. +-32601+ for
        #   +Method not found+.
        attr_reader :code

        # @return [Hash, Array, String, Numeric, nil] the +data+ member, whose
        #   shape each server invents for itself.
        attr_reader :data

        # @param method [String] the request method that was refused.
        # @param error [Hash{String => Object}] the +error+ member.
        def initialize(method, error)
          @code = error['code']
          @data = error['data']
          super("#{method} failed: #{error['message']} (code #{@code})")
        end
      end

      # Starts the reader thread immediately, so a server that talks first is
      # heard.
      #
      # @param stdin [IO] the server's standard input — pikuri writes here.
      # @param stdout [IO] the server's standard output — the reader thread owns
      #   it exclusively from here on.
      # @param server_id [String] the registry entry's id, for log lines only.
      def initialize(stdin:, stdout:, server_id: 'lsp')
        @stdin = stdin
        @stdout = stdout
        @server_id = server_id
        @write_mutex = Mutex.new
        @state = Mutex.new
        @answered = ConditionVariable.new
        @pending = {}
        @handlers = []
        @next_id = 0
        @dead = nil
        @closed = false
        @reader = Thread.new { read_loop }
        @reader.name = "lsp-reader #{server_id}"
      end

      # Send a request and block until the server answers it.
      #
      # @param method [String] LSP method name, e.g. +"textDocument/definition"+.
      # @param params [Hash] the +params+ member, serialized as-is.
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] polled
      #   every {POLL_INTERVAL} while waiting; its +Cancelled+ propagates.
      # @return [Hash, Array, String, Integer, true, false, nil] the +result+
      #   member verbatim. +nil+ is a real answer ("nothing found"), not an
      #   error — and +java/classFileContents+ answers a bare String where the
      #   spec suggests an object, so callers accept what they get.
      # @raise [ServerError] on a JSON-RPC +error+ response.
      # @raise [Closed] if the channel dies before the answer arrives.
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] on cancellation.
      def request(method, params = {}, cancellable: nil)
        id = register_request
        begin
          write(jsonrpc: '2.0', id: id, method: method, params: params)
        rescue StandardError
          @state.synchronize { @pending.delete(id) }
          raise
        end
        await(id, method, cancellable)
      end

      # Send a request and deliberately *not* wait for its answer, for the one
      # case where the answer changes nothing: teardown, where +shutdown+ must
      # reach the server ahead of +exit+. A reply that does arrive is dropped as
      # an unknown id.
      #
      # @param method [String] e.g. +"shutdown"+.
      # @param params [Hash]
      # @return [Integer] the id it went out with.
      # @raise [Closed] if the channel is already gone or the write fails.
      def send_request(method, params = {})
        id = next_id!
        write(jsonrpc: '2.0', id: id, method: method, params: params)
        id
      end

      # Send a notification — no id, no reply, returns as soon as the bytes are
      # written.
      #
      # @param method [String] e.g. +"textDocument/didOpen"+.
      # @param params [Hash]
      # @return [void]
      # @raise [Closed] if the channel is already gone or the write fails.
      def notify(method, params = {})
        write(jsonrpc: '2.0', method: method, params: params)
      end

      # Register a handler for every server notification (+$/progress+,
      # +window/logMessage+, +language/status+, …), called in registration order
      # on the reader thread. One that raises is logged and skipped rather than
      # taking the reader — and with it the channel — down.
      #
      # @yieldparam method [String]
      # @yieldparam params [Hash, nil]
      # @return [void]
      def on_notification(&block)
        @state.synchronize { @handlers << block }
      end

      # @return [Boolean] whether the channel can still carry a request.
      def alive?
        @state.synchronize { @dead.nil? }
      end

      # @return [String, nil] why the channel died — +"server closed stdout
      #   (EOF)"+, a truncated frame, a parse failure, +"closed by pikuri"+ — or
      #   +nil+ while it is alive. What the *child* said on its way out is the
      #   stderr tail, which belongs to whoever spawned it.
      def dead_reason
        @state.synchronize { @dead }
      end

      # Close both IOs and stop the reader thread; every waiting and subsequent
      # {#request} raises {Closed}. Idempotent, and sends no +shutdown+ —
      # protocol lifecycle belongs to the layer that spawned the child.
      #
      # @return [void]
      def close
        already_closed = @state.synchronize do
          was_closed = @closed
          @closed = true
          was_closed
        end
        return if already_closed

        die!('closed by pikuri')
        close_io(@stdin)
        close_io(@stdout)
        return if @reader.join(CLOSE_JOIN_TIMEOUT)

        LOGGER.warn("#{@server_id}: reader thread did not stop within #{CLOSE_JOIN_TIMEOUT}s; killing it")
        @reader.kill
      end

      private

      def next_id!
        @state.synchronize do
          raise Closed, "#{@server_id}: #{@dead}" if @dead

          @next_id += 1
        end
      end

      def register_request
        id = next_id!
        @state.synchronize { @pending[id] = nil }
        id
      end

      def await(id, method, cancellable)
        @state.synchronize do
          loop do
            response = @pending[id]
            if response
              raise ServerError.new(method, response['error']) if response.key?('error')

              return response['result']
            end
            raise Closed, "#{@server_id}: #{@dead} (waiting for #{method})" if @dead

            @answered.wait(@state, POLL_INTERVAL)
            cancellable&.check!
          end
        ensure
          @pending.delete(id)
        end
      end

      def write(message)
        body = JSON.generate(message)
        @write_mutex.synchronize do
          raise Closed, "#{@server_id}: #{dead_reason}" unless alive?

          @stdin.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
          @stdin.flush
        end
      rescue IOError, SystemCallError => e
        reason = "write failed: #{e.class}: #{e.message}"
        die!(reason)
        raise Closed, "#{@server_id}: #{reason}"
      end

      def read_loop
        while (message = read_message)
          dispatch(message)
        end
        die!('server closed stdout (EOF)')
      rescue Closed => e
        report_reader_stopped(e.message)
        die!(e.message)
      rescue StandardError => e
        report_reader_stopped("#{e.class}: #{e.message}")
        die!("#{e.class}: #{e.message}")
      end

      # A reader that stops *after* {#close} pulled its IO out from under it is
      # the teardown working, so it says so at debug; anything else is the
      # channel dying on its own and belongs in the log at error.
      def report_reader_stopped(reason)
        line = "#{@server_id}: reader stopped — #{reason}"
        @state.synchronize { @closed } ? LOGGER.debug(line) : LOGGER.error(line)
      end

      # @return [Hash, nil] the parsed message, or +nil+ at a clean EOF.
      def read_message
        headers = {}
        loop do
          begin
            line = @stdout.readline("\r\n")
          rescue EOFError
            return nil if headers.empty?

            raise Closed, 'EOF inside a header block'
          end
          line = line.chomp("\r\n")
          break if line.empty?

          key, value = line.split(':', 2)
          headers[key.strip.downcase] = value.to_s.strip
        end

        length = Integer(headers.fetch('content-length'))
        body = @stdout.read(length)
        if body.nil? || body.bytesize < length
          raise Closed, "truncated frame: wanted #{length} bytes, got #{body&.bytesize.inspect}"
        end

        JSON.parse(body.force_encoding(Encoding::UTF_8))
      end

      def dispatch(message)
        id = message['id']
        if id && (message.key?('result') || message.key?('error'))
          complete(id, message)
        elsif id
          # A server may block on this reply, so it must not wait for the agent
          # thread — which is busy waiting for the request this would unblock.
          respond_null(id, message['method'])
        elsif message['method']
          notify_handlers(message['method'], message['params'])
        else
          LOGGER.warn("#{@server_id}: unrecognized message #{message.inspect}")
        end
      end

      def complete(id, message)
        @state.synchronize do
          unless @pending.key?(id)
            LOGGER.debug("#{@server_id}: response to unknown id #{id.inspect}")
            next
          end
          @pending[id] = message
          @answered.broadcast
        end
      end

      def respond_null(id, method)
        LOGGER.debug("#{@server_id}: answering server request #{method.inspect} with null")
        write(jsonrpc: '2.0', id: id, result: nil)
      rescue Closed
        nil
      end

      def notify_handlers(method, params)
        @state.synchronize { @handlers.dup }.each do |handler|
          handler.call(method, params)
        rescue StandardError => e
          LOGGER.error("#{@server_id}: notification handler for #{method.inspect} raised #{e.class}: #{e.message}")
        end
      end

      def die!(reason)
        @state.synchronize do
          @dead ||= reason
          @answered.broadcast
        end
      end

      def close_io(io)
        io.close unless io.closed?
      rescue IOError, SystemCallError => e
        LOGGER.debug("#{@server_id}: closing #{io.inspect} raised #{e.class}: #{e.message}")
      end
    end
  end
end
