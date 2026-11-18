# frozen_string_literal: true

require 'pathname'
require 'monitor'

module Pikuri
  module VectorDb
    # The auto-watch daemon: keep a persistent index in sync with a corpus on
    # disk without the user ever calling +vectordb_reindex+. A thin layer over
    # the +listen+ gem driving the {Corpus}'s per-file entry points
    # ({Corpus#reindex_file!} / {Corpus#remove_file!}) from filesystem events,
    # plus a boot reconciliation sweep ({Corpus#reconcile_plan}).
    #
    # == Host-owned, not agent-owned
    #
    # A web app has many {Agent}s but one corpus and one Watcher, so its
    # lifetime is the host *process*. The host constructs it once around the
    # same {Corpus} every agent's {Extension} shares:
    #
    #   server  = Pikuri::VectorDb::Server::Qdrant.ensure_running
    #   corpus = Pikuri::VectorDb::Corpus.new(backend: server.client(collection: 'notes'),
    #                                           source: '~/notes', embedder: embedder)
    #   # ... build agents, each with Extension.new(corpus: corpus) ...
    #   watcher = Pikuri::VectorDb::Watcher.new(corpus: corpus).start
    #
    # The {Extension} indexes nothing on its own, so the Watcher is the
    # population path: its boot sweep fills an empty backend, uniform across
    # backends.
    #
    # == Single work queue, last-intent-per-path
    #
    # The boot sweep and live events must not race, so both funnel into one
    # +@pending+ map (path → +:reindex+/+:remove+) drained by one worker thread:
    #
    # * Rapid edits to one file collapse to a single reindex (one intent per
    #   path); +listen+'s +latency+ window coalesces most before it reaches us.
    # * Order can't corrupt content: {#process} resolves the file from disk *at
    #   process time*, and reindexing a vanished file is itself a removal — so a
    #   stale +:reindex+ after a delete self-corrects rather than writing old
    #   bytes.
    #
    # The boot sweep is enqueued *after* the listener is subscribed, so a
    # mid-sweep change lands in the same queue rather than being lost.
    #
    # == Teardown drains the in-flight job
    #
    # The Watcher registers with {Pikuri::Finalizers} *last* (after the host's
    # {Server::Qdrant}), so LIFO closes it *first*. {#close} stops the listener,
    # then joins the worker, which finishes its in-flight job and exits — the
    # load-bearing ordering that guarantees no {Backend#replace_source} is still
    # writing when the container goes down. Still-queued jobs are abandoned; the
    # next boot's sweep catches them (the downtime-gap guarantee).
    #
    # == What it deliberately does not do
    #
    # * **No model/parameter awareness.** The change signal is the byte hash
    #   ({Corpus#file_hash}), so swapping the embedder/chunker config does *not*
    #   trigger reindex — recourse is a manual +vectordb_reindex+ (see {Extension}).
    # * **Symlinks are never indexed.** A live event reached through a symlink
    #   below the watch root (leaf or ancestor) is dropped, matching
    #   {Corpus#list_files} so watch and walk index the same set. Strict on
    #   purpose: a privacy boundary, and it closes an off-tree divergence — a
    #   symlink target changing outside the tree fires no event, so following it
    #   would leave stale chunks.
    # * **No backpressure.** Re-embedding competes with the chat model on a
    #   shared llama-server; vectordb targets low-churn corpora, so a burst is
    #   tolerated rather than throttled.
    class Watcher
      LOGGER = Pikuri.logger_for('VectorDb::Watcher')

      # +listen+ debounce window: how long filesystem events are batched
      # before the callback fires. The corpus is expected to change rarely,
      # so a coarse window coalesces editor save-storms at no cost.
      #
      # @return [Float] seconds
      LATENCY = 10.0

      # @param corpus [Corpus] the corpus to drive — supplies the
      #   watch {Corpus#root}, the source-vs-directory shape via
      #   {Corpus#source}, and the per-file + reconcile entry points.
      # @param listen_factory [#call, nil] dependency-injection seam
      #   for tests: +call(dir) { |modified, added, removed| ... }+
      #   returns an object responding to +#start+ / +#stop+. +nil+
      #   uses the real +Listen.to+ (required lazily — see the
      #   gemspec note).
      # @return [Watcher]
      def initialize(corpus:, listen_factory: nil)
        @corpus = corpus
        @listen_factory = listen_factory || lambda do |dir, &blk|
          require 'listen'
          Listen.to(dir, latency: LATENCY, &blk)
        end

        # Resolve the watch shape once, here, rather than re-stat'ing
        # per event. {Corpus#root} is the source for a directory tree
        # and the *parent* for a single file, so +source != watch_dir+
        # distinguishes the two without touching the filesystem — and
        # stays correct even if the single watched file is later
        # deleted (a +source.file?+ check would flip to directory mode
        # and start indexing its siblings).
        @source    = @corpus.source.expand_path
        @watch_dir = @corpus.root.expand_path
        @single_file = @source != @watch_dir

        @pending  = {} # path (String) → :reindex / :remove
        # The boot sweep's paths not yet processed, and its size — only for
        # the +[i/total]+ log prefix. A live event for a swept path consumes
        # its slot, so the count still ends at total.
        @sweep_left  = {}
        @sweep_total = 0
        @sweep_started = nil
        @monitor  = Monitor.new
        @cond     = @monitor.new_cond
        @closing  = false
        @started  = false
        @closed   = false
        @worker   = nil
        @listener = nil
        @finalizer_handle = nil
      end

      # Subscribe to filesystem events, spawn the worker thread (which
      # runs the boot reconcile sweep then drains events), and register
      # for teardown. Idempotent guard against a double start.
      #
      # @return [self]
      def start
        raise 'Watcher already started' if @started

        @started = true
        subscribe
        @worker = Thread.new { work_loop }
        # Register LAST so LIFO teardown closes the Watcher before the
        # Server::Qdrant the host registered earlier — see the class yardoc.
        @finalizer_handle = Pikuri::Finalizers.register(self)
        self
      end

      # Stop watching and tear down cleanly. Stops the listener so no
      # new events arrive, then joins the worker — which finishes its
      # in-flight job and exits, abandoning any still-queued work.
      # Idempotent and safe at process exit (the host may have called
      # it already, or only the +at_exit+ finalizer fires).
      #
      # @return [void]
      def close
        return if @closed

        @closed = true
        @listener&.stop
        @monitor.synchronize do
          @closing = true
          @cond.broadcast
        end
        @worker&.join
        Pikuri::Finalizers.unregister(@finalizer_handle) if @finalizer_handle
        nil
      end

      # The +listen+ callback body, also the test seam. Modified/added →
      # +:reindex+, removed → +:remove+; non-indexable paths (denylisted,
      # dot-files, outside the root) and symlinked paths are dropped. The
      # symlink check guards only +:reindex+ (it +lstat+s, which a removed path
      # lacks, and a +:remove+ for a never-indexed symlink source is a no-op).
      #
      # @param modified [Array<String>] absolute paths.
      # @param added [Array<String>] absolute paths.
      # @param removed [Array<String>] absolute paths.
      # @return [void]
      def process_event(modified, added, removed)
        (Array(modified) + Array(added)).each do |path|
          next unless indexable?(path)
          next if symlinked_below_root?(path)

          enqueue(:reindex, path)
        end
        Array(removed).each do |path|
          enqueue(:remove, path) if indexable?(path)
        end
        nil
      end

      # Process every currently-queued job synchronously and return.
      # The worker thread calls this implicitly via its blocking loop;
      # tests call it directly to drain without a thread. Does not wait
      # for new work and does not consult the closing flag.
      #
      # @return [void]
      def drain!
        loop do
          job = @monitor.synchronize do
            next nil if @pending.empty?

            key = @pending.keys.first
            [key, @pending.delete(key)]
          end
          break if job.nil?

          process(*job)
        end
        nil
      end

      private

      # Build and start the listener, wiring its callback to
      # {#process_event}. +listen+ hands absolute path strings; the
      # filtering happens in {#indexable?}, so we don't lean on
      # +listen+'s own ignore rules.
      def subscribe
        @listener = @listen_factory.call(@watch_dir.to_s) do |modified, added, removed|
          process_event(modified, added, removed)
        end
        @listener.start
      end

      # Worker-thread body: run the boot sweep first (now that the
      # listener is live), then block-drain the queue until closed.
      def work_loop
        enqueue_plan
        loop do
          job = next_job
          break if job.nil?

          process(*job)
        end
      end

      # Compute the boot reconcile plan and enqueue it. Failures
      # (backend unreachable, etc.) are logged, not raised — a failed
      # sweep must not take the worker down; live events still flow.
      #
      # The plan hashes every file before it returns, which on a big tree is
      # a long silence — hence the line before it.
      def enqueue_plan
        LOGGER.info("reconcile: scanning #{@watch_dir}…")
        plan = @corpus.reconcile_plan
        @monitor.synchronize do
          (plan[:reindex] + plan[:remove]).each { |path| @sweep_left[path.to_s] = true }
          @sweep_total = @sweep_left.size
          @sweep_started = Time.now
        end
        LOGGER.info(
          "reconcile: #{plan[:reindex].size} file(s) to (re)index, " \
          "#{plan[:remove].size} to remove"
        )
        plan[:reindex].each { |path| enqueue(:reindex, path) }
        plan[:remove].each  { |path| enqueue(:remove, path) }
      rescue StandardError => e
        LOGGER.warn("reconcile sweep failed: #{e.class}: #{e.message}")
      end

      # The +"[i/total] "+ log prefix for a boot-sweep path, consuming its
      # slot; +nil+ for a live event outside the sweep.
      #
      # @param path [String]
      # @return [String, nil]
      def sweep_progress(path)
        @monitor.synchronize do
          next nil unless @sweep_left.delete(path)

          "[#{@sweep_total - @sweep_left.size}/#{@sweep_total}] "
        end
      end

      # Log the sweep's end once its last file has been processed, not merely
      # picked up — else the line lands before the last file's own.
      #
      # @param progress [String, nil] the prefix {#sweep_progress} returned.
      # @return [void]
      def log_sweep_done(progress)
        return unless progress == "[#{@sweep_total}/#{@sweep_total}] "

        LOGGER.info(format('reconcile: done, %d file(s) in %.0fs', @sweep_total, Time.now - @sweep_started))
      end

      # Record an intent for a path, collapsing any prior intent for
      # the same path (last-intent-wins), and wake the worker.
      def enqueue(intent, path)
        @monitor.synchronize do
          @pending[path.to_s] = intent
          @cond.signal
        end
      end

      # Block until a job is available or the Watcher is closing.
      # Returns +nil+ on close so the worker exits — abandoning any
      # still-queued jobs (the boot sweep recovers them next run).
      def next_job
        @monitor.synchronize do
          loop do
            return nil if @closing
            unless @pending.empty?
              key = @pending.keys.first
              return [key, @pending.delete(key)]
            end

            @cond.wait
          end
        end
      end

      # Run one queued job. Per-job failures (an embedder outage on a
      # reindex, a backend blip) are logged and swallowed so one bad
      # file can't kill the worker; the file is picked up again on its
      # next change or the next boot sweep.
      def process(path, intent)
        progress = sweep_progress(path)
        case intent
        when :reindex then @corpus.reindex_file!(path, progress: progress)
        when :remove  then @corpus.remove_file!(path)
        end
      rescue StandardError => e
        LOGGER.warn("watch #{intent} #{path} failed: #{e.class}: #{e.message}")
      ensure
        log_sweep_done(progress)
      end

      # Should a changed path be acted on? For a directory source:
      # the path is under {Corpus#root}, not {Corpus#excluded?}, and no
      # path component is a dot-entry or in {Corpus::DENYLIST}. For a single-file source:
      # the path is exactly that file (the listener watches the
      # parent dir, so siblings must be filtered out). Works on
      # removed paths too — it's pure path math, no +stat+.
      def indexable?(path)
        path = Pathname.new(path).expand_path
        return path == @source if @single_file

        rel = path.relative_path_from(@watch_dir)
        return false if rel.to_s.start_with?('..')
        return false if @corpus.excluded?(path)

        rel.each_filename.none? do |part|
          part.start_with?('.') || Corpus::DENYLIST.include?(part)
        end
      rescue ArgumentError
        # relative_path_from raises when path is on a different prefix
        # than root — i.e. not under the watched tree.
        false
      end

      # Is +path+ reached through a symlink at or below the watch root? +lstat+s
      # each component from +@watch_dir+ down to the leaf, catching both a
      # symlinked leaf and a symlinked ancestor — matching {Corpus#list_files}.
      # The watch root's own prefix isn't checked (the host pointed at it, so
      # it's descended even through a link — as the walk does).
      #
      # @param path [String] an absolute path under the watch root.
      # @return [Boolean]
      def symlinked_below_root?(path)
        path = Pathname.new(path).expand_path
        cur = @watch_dir # the file's parent in single-file mode, the tree root otherwise
        path.relative_path_from(cur).each_filename do |part|
          cur += part
          return true if cur.symlink?
        end
        false
      rescue ArgumentError
        false
      end
    end
  end
end
