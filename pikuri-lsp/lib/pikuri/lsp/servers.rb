# frozen_string_literal: true

module Pikuri
  module Lsp
    # Every language server this agent may use: one {ClientWrapper} per
    # {Registry} entry, and the routing that picks which one answers for a file.
    # **Nothing is spawned until a call needs it** — construction is pure, and
    # each of the two routes starts what it needs:
    #
    #   servers = Servers.new(registry: registry, root: filesystem.project_root)
    #   servers.client_for('lib/pikuri/agent.rb')   # the claiming server, spawned now
    #   servers.client_for('README.md')             # => nil, and nothing spawned
    #   servers.active                              # every project-relevant server, spawned
    #   servers.close
    #
    # Arm teardown straight after construction, not after the first call: a
    # server that started before a later one failed is registered here precisely
    # so an already-armed +close+ still sweeps it.
    #
    # == Implementation details
    #
    # Because a start is lazy, a misconfigured +command+ is discovered by the
    # call that needed it — a {ClientWrapper::ServerDied} naming the id and the
    # argv, which {Navigator} relays as an +"Error: …"+ observation. That is the
    # same path a server dying *after* a successful spawn already took.
    #
    # Sharing: +P_one_agent+, accepted for today — +@clients+ / +@active+ are
    # unguarded, {#close} kills children another caller may be mid-request on,
    # and a per-agent {Pikuri::Agent::Control::Cancellable} is threaded into
    # every handshake. A shared server pool is buildable and simply isn't built,
    # so N agents over one project means N sets of language servers.
    class Servers
      LOGGER = Pikuri.logger_for('Lsp::Servers')
      private_constant :LOGGER

      # @return [Registry] the configuration these clients run.
      attr_reader :registry

      # @param registry [Registry] which servers exist. {Registry::EMPTY} makes
      #   every method here a no-op answer, so a host with no config wires no
      #   tool and nothing else has to care.
      # @param root [String, Pathname] the workspace root: every child's cwd, the
      #   +rootUri+ it indexes, and the tree {#active_entries} scans.
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] threaded
      #   into each handshake.
      # @param spawn [Proc, nil] +entry+ → a started {ClientWrapper}. The seam a
      #   spec replaces to drive fake servers over pipes; production passes
      #   nothing.
      def initialize(registry:, root:, cancellable: nil, spawn: nil)
        @registry = registry
        @root = root
        @cancellable = cancellable
        @spawn = spawn || lambda { |entry|
          ClientWrapper.spawn(entry, root: @root, cancellable: @cancellable)
        }
        @clients = {}
        @active = nil
      end

      # The fan-out set: every project-relevant server, **each spawned here** if
      # it was not running.
      #
      # Relevant rather than registered because a fan-out cannot choose between
      # servers without starting them — {Navigator} gates on what each advertised
      # in *this* workspace, and only a live handshake carries that.
      #
      # @return [Array<ClientWrapper>] in declaration order; empty when nothing is
      #   configured or nothing in the project matches.
      # @raise [ClientWrapper::ServerDied] from the first server that cannot be
      #   started.
      def active
        active_entries.map { |entry| client(entry) }
      end

      # The registered entries this project has files for — the relevance question
      # answered without spawning anything.
      #
      # Rescanned while the answer is *incomplete*, memoized once every
      # registered entry is accounted for. A project gains its first +.java+
      # file mid-session — the agent wrote it — and a scan memoized at the first
      # call would leave jdtls out of every later fan-out, which the model reads
      # as "no such symbol" rather than "nobody asked". A walk costs ~4 ms on
      # this repo against a path that is about to block on a whole index, so
      # paying it until the answer stops changing is free; once every entry is
      # relevant nothing can invalidate it and the walk stops.
      #
      # The first entry claiming a basename wins, exactly as
      # {Registry#entry_for} decides, so an entry shadowed by an earlier one is
      # never activated by files it would not be asked about.
      #
      # @return [Array<Registry::StdioEntry>] in declaration order.
      def active_entries
        return @active if @active && @active.size == @registry.entries.size

        @active = relevant_entries
      end

      # The server that answers for +path+, started if it was not running.
      #
      # Cheap: the path is its own evidence of relevance, so this route never
      # walks the project the way {#active_entries} must.
      #
      # @param path [String, Pathname] matched on its basename by
      #   {Registry::StdioEntry#claims?}.
      # @return [ClientWrapper, nil] +nil+ when no entry claims the file.
      # @raise [ClientWrapper::ServerDied] when the claiming server cannot start.
      def client_for(path)
        entry = @registry.entry_for(path)
        entry && client(entry)
      end

      # @return [Array<String>] ids of the servers actually running, in start
      #   order — nothing at all until a call needs one.
      def started_ids
        @clients.keys
      end

      # @return [Boolean] whether there is nothing to ask — a *registry* question,
      #   not a liveness one: a configured server counts whether or not it has
      #   started, or this would answer "none" to the very first call.
      def empty?
        @registry.empty?
      end

      # Shut every started server down. Idempotent, and never raises — it runs
      # from an +on_close+ at exit, where one bad teardown must not take the rest
      # of the sweep with it ({ClientWrapper#close} already swallows its own).
      #
      # @return [void]
      def close
        @clients.each_value(&:close)
        @clients.clear
        LOGGER.debug('closed')
        nil
      end

      private

      # @return [ClientWrapper]
      def client(entry)
        # A raising spawn stays unmemoized on purpose: installing the missing
        # binary mid-session then recovers, and re-learning an ENOENT is free.
        started = @clients[entry.id] ||= begin
          LOGGER.info("#{entry.id}: starting on first use")
          @spawn.call(entry)
        end
        note_relevant(entry)
        started
      end

      # A started server is relevant by construction: the file that routed here
      # is the evidence {#relevant_entries} goes walking for. That outranks the
      # walk, which skips dot-directories and symlinks — without this, a server
      # started for +.hidden/Foo.java+ would be rescanned for, never found, and
      # left out of every fan-out.
      #
      # @param entry [Registry::StdioEntry]
      # @return [void]
      def note_relevant(entry)
        return if @active.nil? || @active.include?(entry)

        @active = @registry.entries.select { |e| e == entry || @active.include?(e) }
        nil
      end

      # One pruned walk, stopping as soon as every entry is accounted for.
      #
      # Neither dot-directories nor symlinked ones are descended — +.git+ and a
      # vendored bundle say nothing about what *this* project is written in, and
      # not following a symlink is the cheapest cycle-free rule. So relevance is
      # a heuristic, and it only ever narrows the fan-out: {#client_for} starts
      # its server regardless.
      #
      # @return [Array<Registry::StdioEntry>]
      def relevant_entries
        return [] if @registry.empty?

        pending = @registry.entries.dup
        found = []
        scan(@root.to_s, pending, found)
        @registry.entries.select { |entry| found.include?(entry) }
      end

      # @return [void]
      def scan(dir, pending, found)
        Dir.children(dir).each do |name|
          return if pending.empty?

          path = File.join(dir, name)
          if !File.symlink?(path) && File.directory?(path)
            scan(path, pending, found) unless name.start_with?('.')
          else
            claimant = pending.find { |entry| entry.claims?(name) }
            next if claimant.nil?

            found << claimant
            pending.delete(claimant)
          end
        end
      rescue SystemCallError => e
        # A heuristic must not fail the call it serves, and an unreadable
        # directory says nothing about relevance either way.
        LOGGER.debug("relevance scan skipped #{dir}: #{e.message}")
        nil
      end
    end
  end
end
