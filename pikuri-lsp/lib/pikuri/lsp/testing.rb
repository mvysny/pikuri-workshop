# frozen_string_literal: true

require 'json'

module Pikuri
  module Lsp
    # Test support: drive the **real** {Connection} / {ClientWrapper} against a
    # scripted language server over in-process pipes — no binary, no spawn, no
    # network, and one backtrace instead of two.
    #
    # Not loaded by default: +require 'pikuri/lsp/testing'+ from a spec. It lives
    # off the production load path (the gem's Zeitwerk loader ignores it).
    #
    # == Two ways to be a server, and when to pick which
    #
    # {Wire} is the *manual* half: it hands you the client's frames one at a time
    # and you answer them. Use it to assert on what the client wrote, and to play
    # the sequences no real server would perform on demand — a reply that never
    # arrives, a truncated frame, a notification mid-wait.
    #
    #   channel, wire = Testing::Wire.channel
    #   connection = Pikuri::Lsp::Connection.new(**channel, server_id: 'test')
    #   answer = Thread.new { connection.request('textDocument/hover') }
    #   wire.reply(wire.take, 'contents' => 'hi')
    #   answer.value                     # => {"contents"=>"hi"}
    #
    # {FakeServer} is the *scripted* half: it answers on its own thread, so the
    # code under test just makes calls. Use it whenever the client makes more than
    # one, and to replay recorded bytes.
    #
    #   server = Testing::FakeServer.new(capabilities: { 'definitionProvider' => true })
    #   server.on('textDocument/definition') { |_params| [] }
    #   client = Pikuri::Lsp::ClientWrapper.new(entry: entry, root: root, **server.channel)
    #   server.serve
    #   client.start                     # the handshake is answered for you
    #   client.request('textDocument/definition')   # => []
    #   client.close
    #   server.stop
    #
    # == Why the framing here is hand-rolled
    #
    # Neither class touches {Connection}'s framing or the {Location} / {Position}
    # value types to *build* what it sends. A fake that replies through the code
    # under test agrees with that code's bugs, so a serializer defect would show
    # up nowhere. Going the other way is deliberate and useful: parsing the
    # client's own output with {Position.from_wire} is how an asymmetry — a field
    # pikuri can write but not read — surfaces at once.
    #
    # For the *inbound* direction the same argument means canned Hashes are not
    # enough, so {FakeServer#on_json} and {FakeServer#send_frame} take recorded
    # bytes and put them on the wire untouched.
    module Testing
      # The server side of one LSP channel: hand-rolled framing over a pair of
      # pipes, blocking reads, and no behaviour of its own.
      #
      # Drive it from the *example's* thread with the client under test on a
      # worker (or use {FakeServer}). A spec that writes more than the pipe
      # buffer with nobody reading will deadlock.
      class Wire
        # @return [Array(Hash{Symbol => IO}, Wire)] the client's
        #   +{stdin:, stdout:}+ kwargs, and the server side of the same pair.
        def self.channel
          to_server = IO.pipe
          to_client = IO.pipe
          [{ stdin: to_server[1], stdout: to_client[0] },
           new(read: to_server[0], write: to_client[1])]
        end

        # @param read [IO] where the client's frames arrive.
        # @param write [IO] where this side's frames go.
        def initialize(read:, write:)
          @read = read
          @write = write
        end

        # The next message the client wrote, blocking until there is one.
        #
        # @return [Hash{String => Object}]
        # @raise [EOFError] when the client closed its end.
        def take
          headers = {}
          while (line = @read.readline("\r\n").chomp("\r\n")) != ''
            key, value = line.split(':', 2)
            headers[key.strip.downcase] = value.strip
          end
          JSON.parse(@read.read(Integer(headers.fetch('content-length'))))
        end

        # Frame and send +body+ exactly as given — the door recorded bytes come
        # through.
        #
        # @param body [String] a complete JSON-RPC message.
        # @return [void]
        def send_raw(body)
          @write.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
          @write.flush
        end

        # @param message [Hash] serialized with +JSON.generate+.
        # @return [void]
        def send_message(message)
          send_raw(JSON.generate(message))
        end

        # @param request [Hash] the message being answered; only its +id+ is read.
        # @param result [Hash, Array, String, Numeric, true, false, nil] the
        #   +result+ member — +nil+ and +[]+ are real answers.
        # @return [void]
        def reply(request, result)
          send_message('jsonrpc' => '2.0', 'id' => request['id'], 'result' => result)
        end

        # @param request [Hash] the message being refused.
        # @param code [Integer] JSON-RPC code, e.g. +-32601+ for
        #   +Method not found+.
        # @param message [String]
        # @return [void]
        def reply_error(request, code:, message:)
          send_message('jsonrpc' => '2.0', 'id' => request['id'],
                       'error' => { 'code' => code, 'message' => message })
        end

        # @param method [String] e.g. +"$/progress"+.
        # @param params [Hash]
        # @return [void]
        def notify(method, params = {})
          send_message('jsonrpc' => '2.0', 'method' => method, 'params' => params)
        end

        # Ask the *client* something, which a real server does for
        # +window/workDoneProgress/create+ and +workspace/configuration+.
        #
        # @param method [String]
        # @param params [Hash]
        # @param id [String, Integer] ids are the sender's to choose, and a String
        #   keeps a server-initiated request distinguishable in a spec.
        # @return [void]
        def request(method, params = {}, id: 'server-1')
          send_message('jsonrpc' => '2.0', 'id' => id, 'method' => method, 'params' => params)
        end

        # Play the server half of the handshake: answer +initialize+, absorb
        # +initialized+.
        #
        # @param capabilities [Hash{String => Object}] what to advertise.
        # @param server_info [Hash{String => String}, nil]
        # @return [Hash] the client's +initialize+ request, so an example can
        #   assert on what it declared.
        # @raise [RuntimeError] if the client said anything else first.
        def handshake(capabilities: {}, server_info: nil)
          request = take
          raise "expected initialize, got #{request['method'].inspect}" unless request['method'] == 'initialize'

          result = { 'capabilities' => capabilities }
          result['serverInfo'] = server_info if server_info
          reply(request, result)
          absorbed = take
          raise "expected initialized, got #{absorbed['method'].inspect}" unless absorbed['method'] == 'initialized'

          request
        end

        # Close both ends — from the client's side, indistinguishable from the
        # server dying.
        #
        # @return [void]
        def close
          [@write, @read].each { |io| io.close unless io.closed? }
        end
      end

      # A language server that answers on its own thread: the handshake for free,
      # one block per method, and everything the client said kept for assertions.
      #
      #   server = FakeServer.new(capabilities: { 'definitionProvider' => true })
      #   server.on('textDocument/definition') { |params| [{ 'uri' => params['uri'], 'range' => nil }] }
      #   server.on_json('typeHierarchy/supertypes') { File.read('spec/fixtures/ruby_lsp_supertypes.json') }
      #   server.serve
      #   client.start                                  # … and whatever else the example drives
      #   server.await('initialized')                   # the last frame of the handshake
      #   server.received.map { |message| message['method'] }
      #   # => ["initialize", "initialized"]
      #   server.stop
      #
      # An unrouted request is answered +-32601 Method not found+, which is what
      # ruby-lsp does for an operation it never advertised — so a call the example
      # did not expect fails loudly instead of hanging.
      #
      # Thread-safe for the calls above: the serving thread reads and answers
      # while the example scripts routes and reads {#received}.
      class FakeServer
        # JSON-RPC's code for a method the server does not implement.
        METHOD_NOT_FOUND = -32_601

        # @return [Wire] the raw channel, for a sequence no route can express.
        attr_reader :wire

        # @return [Hash{Symbol => IO}] the +{stdin:, stdout:}+ kwargs for
        #   {Connection#initialize} or {ClientWrapper#initialize}.
        attr_reader :channel

        # @param capabilities [Hash{String => Object}] advertised at +initialize+;
        #   the client's {ClientWrapper#supports?} reads exactly this.
        # @param server_info [Hash{String => String}, nil] +name+ / +version+.
        # @param initialize_result [String, nil] a recorded +initialize+ *result*
        #   member, as JSON text, put on the wire byte-for-byte. Overrides
        #   +capabilities+ and +server_info+ when given.
        def initialize(capabilities: {}, server_info: nil, initialize_result: nil)
          @capabilities = capabilities
          @server_info = server_info
          @initialize_result = initialize_result
          @routes = {}
          @received = []
          @mutex = Mutex.new
          @channel, @wire = Wire.channel
        end

        # Answer +method+ with whatever the block returns, serialized as the
        # +result+ member.
        #
        # @param method [String] e.g. +"textDocument/definition"+.
        # @yieldparam params [Hash, nil] the request's +params+.
        # @yieldreturn [Hash, Array, String, Numeric, true, false, nil] the
        #   +result+ member — +nil+ is an answer, not a miss.
        # @return [void]
        def on(method, &block)
          @mutex.synchronize { @routes[method] = { json: false, block: block } }
          nil
        end

        # Answer +method+ with recorded bytes: the block returns the +result+
        # member as JSON *text*, spliced into the response with only the id
        # filled in, so key order and spacing survive exactly as captured.
        #
        # @param method [String]
        # @yieldparam params [Hash, nil]
        # @yieldreturn [String] JSON text.
        # @return [void]
        def on_json(method, &block)
          @mutex.synchronize { @routes[method] = { json: true, block: block } }
          nil
        end

        # Refuse +method+ the way a server refuses an operation it does not have.
        #
        # @param method [String]
        # @param code [Integer]
        # @param message [String]
        # @return [void]
        def refuse(method, code: METHOD_NOT_FOUND, message: nil)
          on(method) { raise Refusal.new(code, message || "Method not found: #{method}") }
          nil
        end

        # Start the serving thread; a second call is a no-op. It has to be
        # running before the client's handshake, which is the first thing that
        # needs an answer.
        #
        # @return [self]
        def serve
          @thread ||= Thread.new { serve_loop }
          self
        end

        # Push a notification at the client, unprompted.
        #
        # @param method [String]
        # @param params [Hash]
        # @return [void]
        def notify(method, params = {})
          @wire.notify(method, params)
        end

        # Put a complete recorded frame on the wire untouched — how a captured
        # +$/progress+ or +window/logMessage+ notification is replayed.
        #
        # @param body [String] a complete JSON-RPC message as JSON text.
        # @return [void]
        def send_frame(body)
          @wire.send_raw(body)
        end

        # Ask the client something, to exercise its reply to a server-initiated
        # request.
        #
        # @param method [String]
        # @param params [Hash]
        # @param id [String, Integer]
        # @return [void]
        def request(method, params = {}, id: 'server-1')
          @wire.request(method, params, id: id)
        end

        # Die: close the channel with no warning and no +exit+, the way a crashed
        # child does.
        #
        # @return [void]
        def crash!
          @wire.close
        end

        # @return [Array<Hash>] every message the client sent, in order, parsed.
        #   A snapshot, and it can lag by one message: a client call returns when
        #   its *bytes* are written, and the serving thread records them a moment
        #   later. Assert through {#await} rather than racing it.
        def received
          @mutex.synchronize { @received.dup }
        end

        # Block until the client has sent a matching message, and return it.
        #
        #   server.await('textDocument/didOpen')
        #   server.await { |message| message['id'] == 'srv-1' && message.key?('result') }
        #
        # @param method [String, nil] match on the +method+ member; omit and pass
        #   a block to match on anything else (a *reply* to a server-initiated
        #   request carries no method at all).
        # @param timeout [Numeric] seconds before giving up.
        # @yieldparam message [Hash]
        # @yieldreturn [Boolean]
        # @return [Hash] the first matching message.
        # @raise [RuntimeError] on timeout, listing what did arrive — a spec
        #   waiting for the wrong thing must fail, not hang.
        def await(method = nil, timeout: 2)
          matcher = block_given? ? ->(message) { yield(message) } : ->(message) { message['method'] == method }
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          loop do
            found = @mutex.synchronize { @received.find(&matcher) }
            return found if found

            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              raise "waited #{timeout}s for #{method || 'a match'}; received " \
                    "#{received.map { |message| message['method'] }.inspect}"
            end

            sleep 0.01
          end
        end

        # Stop serving and close the channel. Idempotent.
        #
        # @return [void]
        def stop
          @wire.close
          @thread&.join(2)
          @thread&.kill
          @thread = nil
        end

        # Raised by a route to answer with a JSON-RPC error instead of a result.
        # {#refuse} is the ordinary way to reach it.
        class Refusal < StandardError
          # @return [Integer] JSON-RPC error code.
          attr_reader :code

          # @param code [Integer]
          # @param message [String]
          def initialize(code, message)
            @code = code
            super(message)
          end
        end

        private

        def serve_loop
          loop do
            message = @wire.take
            @mutex.synchronize { @received << message }
            dispatch(message)
          end
        rescue EOFError, IOError, Errno::EPIPE, Errno::EBADF
          nil # the client hung up, which is how a spec ends
        end

        def dispatch(message)
          method = message['method']
          return if message['id'].nil? # a notification: nothing to answer

          case method
          when 'initialize' then answer_initialize(message)
          when 'shutdown' then @wire.reply(message, nil)
          else answer_route(message, method)
          end
        end

        def answer_initialize(message)
          if @initialize_result
            @wire.send_raw(%({"jsonrpc":"2.0","id":#{message['id'].to_json},"result":#{@initialize_result}}))
            return
          end

          result = { 'capabilities' => @capabilities }
          result['serverInfo'] = @server_info if @server_info
          @wire.reply(message, result)
        end

        def answer_route(message, method)
          route = @mutex.synchronize { @routes[method] }
          return @wire.reply_error(message, code: METHOD_NOT_FOUND, message: "Method not found: #{method}") unless route

          begin
            value = route[:block].call(message['params'])
          rescue Refusal => e
            return @wire.reply_error(message, code: e.code, message: e.message)
          end

          if route[:json]
            @wire.send_raw(%({"jsonrpc":"2.0","id":#{message['id'].to_json},"result":#{value}}))
          else
            @wire.reply(message, value)
          end
        end
      end
    end
  end
end
