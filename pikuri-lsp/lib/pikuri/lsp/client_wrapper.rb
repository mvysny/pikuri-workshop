# frozen_string_literal: true

require 'open3'

module Pikuri
  module Lsp
    # One long-lived language server: the child process, the LSP handshake, and
    # a restart when it dies under us. {Connection} carries the bytes; this owns
    # the lifecycle around them.
    #
    #   client = ClientWrapper.spawn(entry, root: filesystem.project_root)
    #   client.supports?('definitionProvider')   # => true
    #   client.position_encoding                 # => "utf-8"  (ruby-lsp; jdtls stays utf-16)
    #   client.wait_until_ready { |progress| emitter.call(progress) }
    #   client.request('textDocument/definition', params, cancellable: cancellable)
    #   client.close
    #
    # {#wait_until_ready} before the first request is not optional politeness:
    # ruby-lsp answers a mid-index query with a successful +[]+, which an agent
    # reads as "no definition exists". See {Readiness}.
    #
    # {.spawn} raises rather than returning a half-live object, so a missing
    # binary or a server that dies during its handshake is a boot-time failure
    # with the child's own last words attached ({#stderr_tail}) — the one thing
    # that says *why* it died.
    #
    # == Capabilities are per workspace, not per binary
    #
    # {#supports?} answers from *this* +initialize+ response, never from a matrix
    # keyed on the binary: the same ruby-lsp advertises document formatting in a
    # project whose bundle has rubocop and withholds it in one that doesn't. That
    # is why the check belongs at dispatch time, and why {#capabilities} stays a
    # plain Hash — pikuri only ever asks whether a key is there.
    #
    # == Restart, and what a fresh server has forgotten
    #
    # A {Connection::Closed} mid-call means the child is gone for good, so
    # {#request} respawns and retries up to {MAX_ATTEMPTS} times before raising
    # {ServerDied}; a wrapper built with no +respawn:+ (a test over pipes) raises
    # on the first death instead. Documents need no replay — pikuri re-sends
    # +didOpen+ before every call anyway — but a fresh server's *index* is empty,
    # so a restart also puts {#ready?} back to +false+ and the next
    # {#wait_until_ready} waits the new child out from scratch.
    #
    # == Documents: an agent is not an editor, so it re-opens
    #
    # {#open_document} sends +textDocument/didOpen+ with the file's current disk
    # text before every position-based call, and {#close_document} hands it back
    # when the call is done. No open-URI set and no version comparison — the pair
    # is per call, which is also what keeps it correct across a restart, since a
    # respawned child inherits no open documents. See {#open_document} for why
    # each alternative to re-opening was measured and rejected.
    #
    # == The Subprocess-seam exception
    #
    # +Subprocess.spawn+ is one-shot (stdin closed, output merged, read to EOF)
    # and a language server is the opposite on all three counts, so this is the
    # documented exception to the chokepoint convention alongside stdio MCP's:
    # +Open3.popen3+ here, and {#close} owns the teardown — +shutdown+, +exit+,
    # then SIGTERM to the whole process group, because jdtls forks helpers.
    class ClientWrapper
      LOGGER = Pikuri.logger_for('Lsp::ClientWrapper')
      private_constant :LOGGER

      # Total {#request} attempts, including the first — 3 means one normal try
      # plus two restart-then-retry rounds.
      MAX_ATTEMPTS = 3

      # Lines of the child's stderr kept for {#stderr_tail}. jdtls is chatty;
      # what matters is the last thing it said before dying.
      STDERR_TAIL_LINES = 20

      # Seconds {#close} gives the child to leave on its own, at each escalation
      # (EOF, then SIGTERM, then SIGKILL). Teardown is the one place with a
      # clock, and this is what it is spent on: a close that blocks forever is
      # worse than an impolite one.
      CLOSE_GRACE = 2

      # Seconds a death report waits for the child's exit status and its final
      # stderr, both of which are in flight the moment stdout hits EOF.
      REAP_ON_DEATH = 0.5

      # What pikuri tells the server it can do. Four declarations are
      # load-bearing, each measured against a real server: +positionEncodings+
      # (offer utf-8 and convert when a server ignores the offer),
      # +workDoneProgress+ (jdtls emits *no* +$/progress+ without it, narrating
      # startup through a non-spec notification instead), +linkSupport+ (so a
      # definition answers +LocationLink+ and pins the identifier's own range),
      # and +contentFormat+ for hover. The empty objects merely say "this
      # operation exists here"; +documentSymbol+ deliberately does not claim
      # hierarchical support, so symbols arrive flat.
      CLIENT_CAPABILITIES = {
        general: { positionEncodings: PositionEncoding::OFFERED },
        window: { workDoneProgress: true },
        textDocument: {
          synchronization: { dynamicRegistration: false },
          definition: { linkSupport: true },
          typeDefinition: { linkSupport: true },
          implementation: { linkSupport: true },
          references: {},
          hover: { contentFormat: %w[markdown plaintext] },
          documentSymbol: {},
          typeHierarchy: {},
          callHierarchy: {}
        },
        workspace: { symbol: {}, workspaceFolders: true }
      }.freeze

      # The server cannot answer: it never started, it exited, or it stopped
      # answering and restarts did not bring it back. The message carries the
      # exit status and {#stderr_tail}, which is everything a caller needs to
      # report the failure — and nothing that steers what to do instead.
      class ServerDied < StandardError; end

      # +window/logMessage+ +type+ → logger level. Level 1 is where ruby-lsp
      # reports having crashed on a notification, which is otherwise invisible.
      LOG_LEVELS = { 1 => :error, 2 => :warn, 3 => :info, 4 => :debug }.freeze
      private_constant :LOG_LEVELS

      # Spawn the child, run the handshake, return a ready client.
      #
      # @param entry [Registry::StdioEntry] what to launch.
      # @param root [String, Pathname] the workspace root: the child's cwd *and*
      #   the +rootUri+ it indexes. One value, so the server's idea of the
      #   project cannot drift from the confinement boundary.
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] breaks the
      #   handshake wait.
      # @return [ClientWrapper] started, handshaken; indexing continues in the
      #   background.
      # @raise [ServerDied] if the binary is missing, or the child dies before
      #   completing the handshake. Nothing is left half-open.
      def self.spawn(entry, root:, cancellable: nil)
        respawn = -> { spawn_child(entry, root) }
        wrapper = new(entry: entry, root: root, respawn: respawn, **respawn.call)
        begin
          wrapper.start(cancellable: cancellable)
        rescue StandardError
          wrapper.close
          raise
        end
      end

      # @return [Hash{Symbol => Object}] the {#initialize} channel kwargs:
      #   +{stdin:, stdout:, stderr:, wait_thread:}+.
      # @raise [ServerDied] when the binary cannot be executed.
      def self.spawn_child(entry, root)
        stdin, stdout, stderr, wait_thread =
          Open3.popen3(Pikuri::BundlerEnv.clean_delta.merge(entry.env),
                       *entry.command, chdir: root.to_s, pgroup: true)
        LOGGER.info("#{entry.id}: spawned #{entry.command.join(' ')} (pid #{wait_thread.pid}) in #{root}")
        { stdin: stdin, stdout: stdout, stderr: stderr, wait_thread: wait_thread }
      rescue SystemCallError => e
        raise ServerDied, "#{entry.id}: cannot spawn #{entry.command.join(' ')}: #{e.message}"
      end
      private_class_method :spawn_child

      # @return [Registry::StdioEntry] the configuration this client runs.
      attr_reader :entry

      # @return [Hash{String => Object}] the server's advertised capabilities,
      #   verbatim from +initialize+ — +{}+ before {#start}. Values are unions in
      #   practice (+true+ from one server, an options object from another), which
      #   is why nothing types them.
      attr_reader :capabilities

      # @return [Hash{String => Object}, nil] the server's +serverInfo+
      #   (+name+ / +version+), when it sent one.
      attr_reader :server_info

      # @return [String, nil] the negotiated +positionEncoding+ — every
      #   {Position} crossing this channel converts with it — or +nil+ before
      #   {#start}. {PositionEncoding::DEFAULT} when the server answers nothing,
      #   which is jdtls's answer.
      attr_reader :position_encoding

      # Adopts the channel and starts reading it, but sends nothing: {#start} is
      # the handshake. Splitting the two is what lets a fake server drive a
      # wrapper over +IO.pipe+, with no binary in sight.
      #
      # @param entry [Registry::StdioEntry]
      # @param root [String, Pathname] workspace root, reported as +rootUri+.
      # @param stdin [IO] the server's stdin.
      # @param stdout [IO] the server's stdout.
      # @param stderr [IO, nil] the server's stderr, drained into {#stderr_tail};
      #   +nil+ when there is no child to have one.
      # @param wait_thread [Process::Waiter, nil] the child's waiter, for exit
      #   status and signalling; +nil+ over pipes.
      # @param respawn [Proc, nil] returns the kwargs for a fresh child
      #   (+{stdin:, stdout:, stderr:, wait_thread:}+). Without it, a dead
      #   channel is terminal — see the class's restart note.
      # @param readiness [Readiness, nil] the indexing gate, which this
      #   subscribes to the server's notifications. Injectable so a spec can
      #   shorten the settle window; production passes nothing.
      def initialize(entry:, root:, stdin:, stdout:, stderr: nil, wait_thread: nil, respawn: nil,
                     readiness: nil)
        @entry = entry
        @root = File.expand_path(root.to_s)
        @respawn = respawn
        @handlers = []
        @capabilities = {}
        @stderr_tail = []
        @stderr_io = nil
        @tail_mutex = Mutex.new
        @started = false
        @document_version = 0
        @closed = false
        @readiness = readiness || Readiness.new(server_id: entry.id)
        adopt(stdin: stdin, stdout: stdout, stderr: stderr, wait_thread: wait_thread)
        on_notification { |method, params| @readiness.observe(method, params) }
      end

      # Run the LSP handshake: +initialize+, then +initialized+.
      #
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil]
      # @return [self]
      # @raise [ServerDied] if the child dies mid-handshake.
      # @raise [KeyError] if the server answers no +capabilities+ — it is not
      #   speaking LSP.
      def start(cancellable: nil)
        raise "#{@entry.id}: already started" if @started

        handshake(cancellable)
        @started = true
        self
      end

      # Send a request, restarting the server and retrying if it dies.
      #
      # @param method [String] e.g. +"textDocument/definition"+.
      # @param params [Hash]
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil]
      # @return [Hash, Array, String, Integer, true, false, nil] the +result+
      #   member; +nil+ and +[]+ are answers, not failures.
      # @raise [ServerDied] when the server is gone and restarts did not help.
      # @raise [Connection::ServerError] when the server refuses the method —
      #   which a capability check should have caught first.
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] on cancellation.
      def request(method, params = {}, cancellable: nil)
        with_restart(cancellable) { @connection.request(method, params, cancellable: cancellable) }
      end

      # Send a notification (+textDocument/didOpen+, +exit+), restarting on death
      # like {#request} — a notification that vanishes into a dead pipe would
      # otherwise be discovered by the *next* request answering nonsense.
      #
      # @param method [String]
      # @param params [Hash]
      # @return [void]
      # @raise [ServerDied] when the server is gone and restarts did not help.
      def notify(method, params = {})
        with_restart(nil) { @connection.notify(method, params) }
      end

      # Tell the server what this file says *now*, by re-opening it.
      #
      #   client.open_document(path, filesystem.resolve_for_read(path).read)
      #
      # This is the whole document-sync policy, and it is sound rather than lucky
      # because **pikuri has no unsaved buffers**. An editor owns text the disk
      # does not have, which is the only reason LSP's sync model exists; +write+
      # and +edit+ land on disk immediately, so the disk is always the truth and
      # the server's copy is only ever a cache of it. Re-opening is how you say
      # "here is the truth again", and the text it needs is the text the tool has
      # already read to locate the symbol.
      #
      # Every alternative was measured and each fails differently:
      #
      # * A **rangeless whole-document +didChange+** is not ours to send: both
      #   servers advertise *incremental* sync, and +TextDocumentSyncKind+ is the
      #   server's declaration of which shape it accepts. jdtls tolerates it;
      #   ruby-lsp raises inside +push_edits+, which reads +edit[:range][:start]+
      #   unconditionally, and a notification has no reply channel, so the only
      #   report is a +window/logMessage+ line while the document keeps its old
      #   text.
      # * The **ranged** whole-document change is honoured by both, and then
      #   desynchronizes ruby-lsp's *index* from the document it just updated:
      #   +RubyDocument#should_index?+ reindexes only when the edit's start
      #   position looks like a declaration, and a whole-file replace starts at
      #   0:0 — the +frozen_string_literal+ comment. +documentSymbol+ then reports
      #   the new name while +definition+ answers +[]+ for it.
      # * **+didClose+ alone**, as the way to refresh: it resyncs ruby-lsp (its
      #   store entry is dropped, so the next request re-reads disk) and does
      #   nothing for jdtls, which keeps answering its pre-close copy. Rejected as
      #   the *mechanism* — {#close_document} still sends it, to balance the open
      #   rather than to refresh anything.
      # * The spec's own out-of-band channel, +didChangeWatchedFiles+, is ignored
      #   by both *for a URI the client has opened* — a client that opened a
      #   document is presumed to be its authority, which is exactly the
      #   assumption an agent writing straight to disk breaks.
      #
      # Re-opening was the only mechanism that worked on both servers, refreshing
      # document *and* index. The cost, named: the server re-parses the file on
      # every call. That is a local child process doing what it does on every
      # keystroke in an editor, and the alternative is a correctness bug that
      # reports success.
      #
      # @param path [String, Pathname] absolute path of the document; the +file:+
      #   URI is derived from it.
      # @param text [String] its current contents, read through the +Workspace+
      #   seam by the caller.
      # @return [void]
      # @raise [ServerDied] when the server is gone and restarts did not help.
      def open_document(path, text)
        @document_version += 1
        notify('textDocument/didOpen',
               { textDocument: { uri: Uris.for_path(path), languageId: @entry.language_id,
                                 version: @document_version, text: text } })
      end

      # Hand the document back, so the server returns to reading it from disk.
      #
      # Balances {#open_document} (+D_lsp_document_sync+), and must go out *after*
      # the reply to the request it brackets: a server that answers concurrently
      # can otherwise process the close first and answer about a document it has
      # just dropped.
      #
      # Alone among the notifications here it neither restarts nor raises — a
      # respawned child never received the +didOpen+ this balances, so there is
      # nothing for a retry to reach.
      #
      # @param path [String, Pathname] the document opened earlier.
      # @return [void]
      def close_document(path)
        return unless alive?

        @connection.notify('textDocument/didClose', { textDocument: { uri: Uris.for_path(path) } })
      rescue Connection::Closed => e
        LOGGER.debug("#{@entry.id}: could not close #{path}: #{e.message}")
      end

      # Register a server-notification handler, kept across restarts and
      # re-attached to each new channel.
      #
      # @yieldparam method [String]
      # @yieldparam params [Hash, nil]
      # @return [void]
      # @see Connection#on_notification for the reader-thread contract
      def on_notification(&block)
        @handlers << block
        @connection.on_notification(&block)
        nil
      end

      # Whether the server advertised an operation *in this workspace*.
      #
      # @param name [String] a capability key, e.g. +"definitionProvider"+.
      # @return [Boolean] +false+ both when the key is absent and when it is
      #   explicitly +false+.
      def supports?(name)
        value = @capabilities[name]
        !value.nil? && value != false
      end

      # @return [Boolean] whether the server has finished indexing — see
      #   {Readiness} for what that means and why it is one rule for every
      #   server. A request sent while this is +false+ is answered wrongly by
      #   ruby-lsp and not at all by jdtls.
      def ready?
        @readiness.ready?
      end

      # Block until the index is built, yielding progress while it is not.
      #
      #   client.wait_until_ready(cancellable: cancellable) { |progress| emitter.call(progress) }
      #
      # There is no timeout: a cold jdtls import is minutes, no number separates
      # a slow index from a hung one, and the yielded {ServerProgress} is what
      # keeps the block legible rather than a hang. What ends a wait instead is
      # readiness, the child's death, or +cancellable+ — the human as the
      # timeout. A server that dies waiting is restarted and waited on again,
      # {MAX_ATTEMPTS} times, because a fresh child indexes from nothing — but a
      # replacement that cannot get through its *handshake* ends the attempt
      # there and then, so a misconfigured server costs one respawn rather than
      # a spawn per attempt.
      #
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil]
      # @yieldparam progress [ServerProgress] on the *calling* thread, which is
      #   what makes it safe to emit as an agent event.
      # @return [true]
      # @raise [ServerDied] when the server died indexing and restarts did not
      #   get it further.
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] on cancellation.
      def wait_until_ready(cancellable: nil, &progress)
        progress ||= ->(_update) {}
        with_restart(cancellable) do
          next true if @readiness.wait(cancellable: cancellable, alive: -> { alive? }, &progress)

          raise Connection::Closed, 'died while its index was building'
        end
      end

      # @return [Boolean] whether a request could still be answered.
      def alive?
        !@closed && @connection.alive?
      end

      # @return [String] the child's last {STDERR_TAIL_LINES} stderr lines,
      #   newline-joined, +""+ when it said nothing (or when there is no child).
      #   Reset on restart, so this is always the *current* child's account.
      def stderr_tail
        @tail_mutex.synchronize { @stderr_tail.join("\n") }
      end

      # @return [Integer, nil] the child's pid, +nil+ over pipes.
      def pid
        @wait_thread&.pid
      end

      # Shut the server down: +shutdown+, +exit+, close the channel, then signal
      # anything still breathing. Idempotent, and never raises — teardown runs at
      # exit, where a raise would take the rest of the sweep with it.
      #
      # @return [void]
      def close
        return if @closed

        @closed = true
        say_goodbye
        @connection.close
        # After the child is gone, not before: closing our read end while it is
        # still writing hands a dying server EPIPE on its own log channel.
        reap_child
        close_stderr
        nil
      rescue StandardError => e
        LOGGER.warn("#{@entry.id}: teardown raised #{e.class}: #{e.message}")
        nil
      end

      private

      def adopt(stdin:, stdout:, stderr: nil, wait_thread: nil)
        close_stderr
        @wait_thread = wait_thread
        @tail_mutex.synchronize { @stderr_tail.clear }
        @connection = Connection.new(stdin: stdin, stdout: stdout, server_id: @entry.id)
        @connection.on_notification { |method, params| log_server_message(method, params) }
        @handlers.each { |handler| @connection.on_notification(&handler) }
        @stderr_io = stderr
        @stderr_thread = stderr && drain_stderr(stderr)
      end

      # The previous child's stderr pipe, which +Connection#close+ never saw.
      def close_stderr
        @stderr_io&.close unless @stderr_io&.closed?
        @stderr_io = nil
      rescue IOError, SystemCallError
        nil
      end

      def handshake(cancellable)
        result = @connection.request('initialize', initialize_params, cancellable: cancellable)
        @capabilities = result.fetch('capabilities')
        @server_info = result['serverInfo']
        @position_encoding = @capabilities['positionEncoding'] || PositionEncoding::DEFAULT
        @connection.notify('initialized', {})
        LOGGER.info("#{@entry.id}: ready — #{@server_info&.fetch('name', nil) || 'unnamed server'}, " \
                    "#{@position_encoding}, #{@capabilities.keys.size} capabilities")
      rescue Connection::Closed => e
        raise ServerDied, death_message(e, during: 'startup')
      end

      def initialize_params
        {
          processId: Process.pid,
          clientInfo: { name: 'pikuri', version: Pikuri::VERSION },
          rootUri: Uris.for_path(@root),
          # Deprecated in favour of rootUri since 3.3, and jdtls still reads it.
          rootPath: @root,
          workspaceFolders: [{ uri: Uris.for_path(@root), name: File.basename(@root) }],
          capabilities: CLIENT_CAPABILITIES,
          initializationOptions: @entry.init_options
        }.compact
      end

      def with_restart(cancellable)
        attempt = 1
        begin
          yield
        rescue Connection::Closed => e
          raise ServerDied, death_message(e) if @closed || @respawn.nil? || attempt >= MAX_ATTEMPTS

          LOGGER.warn("#{@entry.id}: #{e.message}; restarting " \
                      "(attempt #{attempt + 1}/#{MAX_ATTEMPTS})")
          restart(cancellable)
          attempt += 1
          retry
        end
      end

      def restart(cancellable)
        @connection.close
        reap_child
        adopt(**@respawn.call)
        @readiness.reset!
        handshake(cancellable)
      end

      def say_goodbye
        return unless @connection.alive?

        # The shutdown reply is never awaited: a server wedged mid-index would
        # turn teardown into a hang, and the grace it would buy — time to persist
        # before dying — is already {#reap_child}'s, waiting on the real signal.
        @connection.send_request('shutdown')
        @connection.notify('exit')
      rescue StandardError => e
        LOGGER.debug("#{@entry.id}: could not say goodbye (#{e.class}: #{e.message})")
      end

      def reap_child
        return unless @wait_thread

        stop_leader
        # Swept even when the leader left on its own: a server that honours
        # +exit+ still strands the helpers it forked, and the group is the only
        # handle on those.
        signal_group('TERM')
      end

      def stop_leader
        return unless @wait_thread.alive?
        return if @wait_thread.join(CLOSE_GRACE)

        signal_group('TERM')
        return if @wait_thread.join(CLOSE_GRACE)

        LOGGER.warn("#{@entry.id}: pid #{@wait_thread.pid} ignored SIGTERM; killing the group")
        signal_group('KILL')
        @wait_thread.join(CLOSE_GRACE)
      end

      # Signals the whole group, not the pid: jdtls forks helpers, and the group
      # is what +pgroup: true+ bought.
      def signal_group(name)
        Process.kill("-#{name}", @wait_thread.pid)
      rescue Errno::ESRCH, Errno::EPERM => e
        LOGGER.debug("#{@entry.id}: SIG#{name} to the group failed (#{e.class})")
      end

      def drain_stderr(stderr)
        Thread.new do
          stderr.each_line do |line|
            line = line.chomp
            @tail_mutex.synchronize do
              @stderr_tail << line
              @stderr_tail.shift while @stderr_tail.size > STDERR_TAIL_LINES
            end
            LOGGER.debug("#{@entry.id} stderr: #{line}")
          end
        rescue IOError, SystemCallError
          nil
        end
      end

      def log_server_message(method, params)
        return unless %w[window/logMessage window/showMessage].include?(method)

        level = LOG_LEVELS.fetch(params&.fetch('type', nil), :info)
        LOGGER.public_send(level, "#{@entry.id}: #{params&.fetch('message', nil)}")
      end

      def death_message(error, during: nil)
        # EOF on stdout means the child is on its way out; give it a moment to
        # land so the report can name an exit status instead of guessing.
        @wait_thread&.join(REAP_ON_DEATH)
        @stderr_thread&.join(REAP_ON_DEATH)
        status = @wait_thread && !@wait_thread.alive? ? @wait_thread.value : nil
        headline = status ? "exited with #{status_text(status)}" : 'stopped answering'
        headline += " during #{during}" if during
        tail = stderr_tail
        message = "#{@entry.id} #{headline} — #{error.message}"
        tail.empty? ? message : "#{message}; last stderr: #{tail}"
      end

      def status_text(status)
        status.exitstatus ? "exit #{status.exitstatus}" : "signal #{status.termsig}"
      end
    end
  end
end
