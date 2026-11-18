# frozen_string_literal: true

require 'pathname'
require 'digest'

module Pikuri
  module VectorDb
    # A folder of documents, the backend holding their index, and what the
    # agent may assume about them (+private:+ / +trusted:+). Indexing is one
    # of its jobs — it walks +source+ (skipping {DENYLIST} + dot-files),
    # extracts text via {Pikuri::FileType.read_as_text}, chunks via the
    # {Chunker}, embeds via the {Embedder}, and {Backend#upsert}s the result.
    #
    #   corpus = Pikuri::VectorDb::Corpus.new(
    #     backend:  Pikuri::VectorDb::Backend::InMemory.new,
    #     source:   '~/notes',
    #     embedder: Pikuri::VectorDb::Embedder.new(server: ..., model: ...),
    #     private:  true, trusted: true   # what this folder is; both default off
    #   )
    #   watcher = Pikuri::VectorDb::Watcher.new(corpus: corpus).start
    #   agent_a = Pikuri::Agent.new(...) { |c| c.add_extension Extension.new(corpus: corpus) }
    #   agent_b = Pikuri::Agent.new(...) { |c| c.add_extension Extension.new(corpus: corpus) }
    #   # ... at teardown:
    #   watcher.close; agent_a.close; agent_b.close
    #   corpus.close                   # closes the backend
    #
    # == One corpus per folder
    #
    # The host builds it once per folder and hands it to every extension and
    # {Watcher} over that folder; it owns its +backend:+ and {#close}s it.
    # Two corpora over one folder and one store each walk, embed and write
    # the same files, and if their embedders or chunkers differ, the store
    # silently mixes the two.
    #
    # Not the extension's to own: an extension is per agent, so three agents
    # would build three corpora. Nor a +Pikuri::Workspace::Workspace+'s: that
    # is per agent too (it holds one conversation's read record), and a
    # corpus is often a folder no file tool is wired over.
    #
    # Whole-corpus entry points: {#index_all!} (unconditional), {#reindex!}
    # (nuke-and-reload), {#index_if_empty!} (boot-time — InMemory always
    # indexes, Qdrant only on first boot / after a manual reindex).
    # One-file-at-a-time, driven by the {Watcher} daemon: {#reindex_file!},
    # {#remove_file!}, and {#reconcile_plan} (the boot sweep — a plan, not an
    # action).
    #
    # Each indexed file emits one +[i/total]+ INFO line through
    # {Pikuri::VectorDb::LOGGER}; indexing against a local llama.cpp embedder
    # takes minutes with the user blocked on boot, so progress visibility is
    # load-bearing (hosts with a richer channel reroute +PIKURI_LOG_VECTORDB+).
    # WARN lines surface skips (image/binary, missing path, no extractable text).
    #
    # == Chunk identity
    #
    # +Chunk.id+ is +"source:index"+ (relative path + ordinal-within-file) —
    # readable, deterministic, stable across reindexes. Incremental reindex
    # replaces by +source+ (not by content-addressed id), so the file's content
    # hash lives in +Chunk.metadata[:hash]+ (same value on every chunk of one
    # file) — that's what lets {#reconcile_plan} read one chunk per source and
    # still know whether the file changed. +Chunk.source+ is relative to the
    # source root: short, citation-friendly, survives moving the corpus;
    # absolute paths would tie the backend to a machine layout.
    #
    # == Errors mid-indexing
    #
    # An embedder failure mid-run propagates and aborts (caller is internal
    # pikuri code, not the LLM — "errors are loud"), leaving the backend partial.
    # Recourse is {#reindex!}. InMemory resets on restart anyway; only Qdrant
    # persists partial state, and a fresh reindex recovers cleanly.
    class Corpus
      LOGGER = Pikuri.logger_for('VectorDb::Corpus')

      # Basenames skipped during the walk — cruft that accumulates inside a
      # notes folder put under +source:+ (a cloned repo, a Python venv, a build
      # dir). Conservative; configurable ignore rules deferred (see
      # +design/ideas/vectordb-deferrals.md+).
      DENYLIST = %w[
        .git
        node_modules
        __pycache__
        venv
        target
        build
        dist
        out
        vendor
      ].freeze

      # @param backend [#upsert, #query, #delete_all, #count, #close] any
      #   {Backend}; this corpus owns it from here on.
      # @param source [String, Pathname] path to index (a file directly, a
      #   directory recursively). Tilde-expanded.
      # @param embedder [#embed] +embed(Array<String>) -> Array<Array<Float>>+,
      #   usually an {Embedder}. No default: an embedder needs a server to dial.
      # @param chunker [#chunk] +chunk(String) -> Array<Chunker::Piece>+;
      #   default {Chunker::FixedWindow} with +size: 512, overlap: 50+.
      # @param private [Boolean] see {#private?}.
      # @param trusted [Boolean] see {#trusted?} for the three clauses you are
      #   signing.
      # @param exclude [Array<String, Pathname>] folders or files under
      #   {#root} that are never indexed, relative to it or absolute — a
      #   library of books inside +~/Documents+, say, which would cost hours
      #   of embedding and crowd every search. Matched by whole path
      #   components, so +Books+ skips +Books/x.pdf+ but not +Bookshelf.md+.
      # @return [Corpus]
      # @raise [ArgumentError] if an +exclude+ entry lies outside {#root}: it
      #   could never match, and a skip rule that silently does nothing is
      #   exactly the one nobody notices.
      #
      # A *single* source, not an array: with multiple roots two files both
      # named +cooking.md+ would derive identical relative +source+ values,
      # hence identical +"source:ordinal"+ ids, and {Backend#upsert}'s
      # replace-by-id would silently let the second overwrite the first.
      # Multi-source is deferred — see +design/ideas/vectordb-deferrals.md+.
      def initialize(backend:, source:, embedder:,
                     chunker: Chunker::FixedWindow.new(size: 512, overlap: 50),
                     private: false, trusted: false, exclude: [])
        @backend  = backend
        @source   = Pathname.new(source).expand_path
        @embedder = embedder
        @chunker  = chunker
        @private  = private
        @trusted  = trusted
        @exclude  = exclude.map { |e| exclusion(e) }
      end

      # @return [#upsert, #query, #count] the backend this corpus fills, which
      #   the search and read tools query.
      attr_reader :backend

      # @return [#embed] the embedder the index was built with, which a search
      #   must embed its query with too.
      attr_reader :embedder

      # Close the backend, and with it everything the backend owns.
      # Idempotent.
      #
      # Close the {Watcher} first: it writes through this corpus.
      #
      # @return [void]
      def close
        @backend.close
        nil
      end

      # Files with at least this many chunks announce themselves before
      # embedding, not only after: a book is one embedding call that can run
      # for a minute, and without the line the log goes quiet for exactly
      # that minute.
      # @return [Integer]
      ANNOUNCE_CHUNKS = 20

      # Whether this corpus may hold data worth exfiltrating — the lethal
      # trifecta's private leg, which {Tools::Search} and {Tools::Read} inherit
      # through the {Extension}.
      #
      # The framework cannot answer this for you: sensitivity is a property of
      # the *data*, not of the tool, and +~/notes+ and +~/case-files+ are
      # indistinguishable from the outside. Same declaration
      # {Pikuri::Workspace::Filesystem#private?} makes for the file tools, on
      # the second object that owns a reachable set of documents. A trifecta
      # declaration, not a defense: it decides what the boot map *prints*.
      #
      # @return [Boolean] default +false+
      def private? = @private

      # Whether every byte in this corpus is yours — the opt-out from the two
      # reading tools' default +:hard+ untrusted leg. Three clauses, all of
      # them load-bearing:
      #
      # 1. *Every file under +source+ was reviewed by you in the form the
      #    model will read it.* For plain text that is the file. For anything
      #    the {Pikuri::Extractor} registry converts it is the *extraction*,
      #    and the gap is enormous: white-on-white text, hidden-text
      #    attributes, off-page glyphs, comments, tracked changes, form fields
      #    and metadata are invisible to a reader of the rendered document and
      #    fully present after extraction. Reading a rendered PDF approves a
      #    *proxy*, not the payload — the ingest mirror of why +curl+'s egress
      #    grades +:unreviewed+. So either keep such files out of a trusted
      #    corpus, or convert first (+Pikuri::Extractor.extract+), read the
      #    conversion, and index that text with the original left outside.
      # 2. *Nobody else writes into that folder.* Trust is a claim about who
      #    can write, not about today's content — with a {Watcher} a file that
      #    lands later is indexed within seconds. A shared Nextcloud folder, a
      #    team Drive, a scanner's output directory and a mail client's
      #    attachment folder all falsify the flag the moment someone else drops
      #    a file in.
      # 3. *The backend collection holds only what this folder filled it with.*
      #    A persistent backend keeps whatever it was given: point a reused
      #    collection at a new +source+ and yesterday's documents still answer
      #    queries under today's declaration. Give each corpus root its own
      #    collection name.
      #
      # Says nothing about *parser* exposure: a hostile PDF exploiting poppler
      # is a code-exec/DoS vector against the extractor, not an injection
      # vector against the model, and the extractor gem owns it — never read
      # this flag as "safe to parse".
      #
      # @return [Boolean] default +false+
      def trusted? = @trusted

      # @return [Pathname] the configured source, tilde-expanded (a file or a
      #   directory tree). The {Watcher} reads this to decide what to watch.
      attr_reader :source

      # The directory whose tree is indexed — the anchor for every relative
      # {Chunk#source}. A directory source is its own root; a single-file source
      # roots at its parent (citation is just the basename).
      #
      # @return [Pathname]
      def root
        @source.directory? ? @source : @source.parent
      end

      # Whether +path+ falls under one of the +exclude:+ entries — shared by
      # the walk and the {Watcher}, so a live event can't index what the walk
      # skips. Pure path math, so it works on a removed path too.
      #
      # @param path [String, Pathname] an absolute path.
      # @return [Boolean]
      def excluded?(path)
        return false if @exclude.empty?

        parts = Pathname.new(path).expand_path.relative_path_from(root).each_filename.to_a
        @exclude.any? { |ex| parts.first(ex.size) == ex }
      rescue ArgumentError
        false
      end

      # Walk every source, index every reachable non-denylisted
      # file. Returns the total chunk count emitted into the
      # backend across this invocation.
      #
      # @return [Integer]
      def index_all!
        files = enumerate_files
        if files.empty?
          LOGGER.warn("no indexable files found under source: #{@source}")
          return 0
        end

        LOGGER.info("indexing #{files.length} file(s) from #{@source}")
        started = Time.now
        total_chunks = 0
        files.each_with_index do |(root, path), i|
          total_chunks += index_file(root: root, path: path, i: i + 1, total: files.length)
        end
        LOGGER.info(format(
                      'done: %d file(s), %d chunks, %.1fs',
                      files.length, total_chunks, Time.now - started
                    ))
        total_chunks
      end

      # +backend.delete_all+ followed by {#index_all!}. The
      # v1 nuke-and-reload reindex path.
      #
      # @return [Integer] total chunks indexed.
      def reindex!
        LOGGER.info('reindex: clearing backend')
        @backend.delete_all
        index_all!
      end

      # Index only if the backend is currently empty. The boot-time
      # entry point — InMemory backends always re-index (RAM-only);
      # Qdrant backends only re-index on first boot or after a
      # manual +reindex!+.
      #
      # @return [Integer] total chunks indexed (0 if backend was
      #   non-empty and nothing was indexed).
      def index_if_empty!
        existing = @backend.count
        if existing.positive?
          LOGGER.info("backend already has #{existing} chunk(s); skipping boot index")
          return 0
        end
        index_all!
      end

      # Re-index a single file in place: extract → chunk → embed →
      # {Backend#replace_source} (the atomic unit the {Watcher} drives on a
      # modify/add event). The embed happens *before* the backend write, so an
      # embedder outage raises here leaving the prior chunks untouched (see
      # {Backend::Qdrant#replace_source}). A file that no longer yields text
      # (emptied, now-binary, vanished) is treated as a removal — its stale
      # chunks drop and nothing is written, so no orphans linger.
      #
      # @param path [String, Pathname] the file; need not exist (vanished ⇒
      #   removal).
      # @param progress [String, nil] a prefix for this file's log lines,
      #   e.g. +"[12/340] "+ — the {Watcher}'s boot-sweep position.
      # @return [Integer] chunks now stored (0 if removed).
      # @raise [RuntimeError] if the embedder or backend fails — the {Watcher}
      #   logs it and moves on.
      def reindex_file!(path, progress: nil)
        path   = Pathname.new(path).expand_path
        source = relative_source(path)

        pieces = begin
          pieces_for(path)
        rescue ArgumentError, Errno::ENOENT, RuntimeError => e
          LOGGER.info("#{progress}reindex #{source}: unindexable (#{e.message}); removing from index")
          @backend.delete_by_source(source)
          return 0
        end

        if pieces.empty?
          LOGGER.info("#{progress}reindex #{source}: no indexable text; removing from index")
          @backend.delete_by_source(source)
          return 0
        end

        if pieces.length >= ANNOUNCE_CHUNKS
          LOGGER.info("#{progress}reindex #{source}: embedding #{pieces.length} chunk(s)…")
        end
        # embed_and_build is *outside* the rescue: an embedder outage
        # raises straight out, before replace_source touches the
        # backend, so the prior chunks survive (embed-before-delete).
        chunks, vectors = embed_and_build(source: source, path: path, pieces: pieces)
        @backend.replace_source(source: source, chunks: chunks, vectors: vectors)
        LOGGER.info("#{progress}reindex #{source}: #{chunks.length} chunk(s)")
        chunks.length
      end

      # Drop a file's chunks from the index — the {Watcher}'s
      # response to a delete (or move-away) event. Idempotent:
      # removing a source that isn't indexed is a no-op.
      #
      # @param path [String, Pathname] the (now-absent) file.
      # @return [void]
      def remove_file!(path)
        source = relative_source(Pathname.new(path).expand_path)
        @backend.delete_by_source(source)
        LOGGER.info("removed #{source} from index")
        nil
      end

      # The boot reconciliation sweep, as a *plan* not an action: walk the tree,
      # hash every file, diff against {Backend#sources_with_hashes}, return the
      # work list. The {Watcher} feeds it through its single queue so the sweep
      # and live events share one last-intent-wins path (and teardown can
      # interrupt between files). Uniform across backends with no +is_a?+:
      # InMemory reports an empty manifest at boot (RAM reset) so every file
      # reads as new; Qdrant reports its persisted manifest so only changed
      # files return — which also closes the downtime gap (changes made while no
      # {Watcher} ran are invisible to filesystem events but caught by the diff).
      #
      # @return [Hash{Symbol => Array<Pathname>}] +{reindex:, remove:}+ — files
      #   new-or-changed, and files (as +root+/source paths) gone from disk.
      def reconcile_plan
        on_disk = {} # source (String) => Pathname
        enumerate_files.each { |_root, p| on_disk[relative_source(p)] = p }
        indexed = @backend.sources_with_hashes

        reindex = on_disk.select { |source, path| indexed[source] != file_hash(path) }.values
        remove  = (indexed.keys - on_disk.keys).map { |source| root.join(source) }
        { reindex: reindex, remove: remove }
      end

      private

      # Walk the configured source, return an array of
      # +[root, file_path]+ pairs. +root+ is the source root
      # used later to compute the relative +Chunk.source+. A
      # source that points at a single file lands as
      # +[file.parent, file]+ — citation is just the basename.
      # A source that doesn't exist on disk produces a WARN and
      # an empty array.
      def enumerate_files
        if @source.file?
          [[@source.parent, @source]]
        elsif @source.directory?
          list_files(@source).map { |f| [@source, f] }
        else
          LOGGER.warn("source path does not exist or is not a regular file/dir: #{@source}")
          []
        end
      end

      # Depth-first walk of +root+, applying {DENYLIST}, the dotfile skip rule
      # and +exclude:+, sorted by basename for deterministic order. An excluded
      # folder is never descended, so a big library costs no stat calls.
      #
      # Symlinks are skipped outright (the +#symlink?+ check uses +lstat+, so it
      # fires before the link is followed) — a deliberate strict policy, not the
      # OS default: it's a privacy boundary (a link to +~/.ssh+ never gets
      # embedded) and keeps this walk in exact agreement with
      # {Watcher#process_event}. +root+ itself is descended even through a
      # symlink; only links *discovered during* the walk are skipped.
      def list_files(root)
        files = []
        walk = lambda do |dir|
          entries = dir.each_child.to_a.sort_by { |e| e.basename.to_s }
          entries.each do |entry|
            name = entry.basename.to_s
            next if name.start_with?('.')
            next if DENYLIST.include?(name)
            next if entry.symlink?
            next if excluded?(entry)

            if entry.directory?
              walk.call(entry)
            elsif entry.file?
              files << entry
            end
          end
        end
        walk.call(root)
        files
      end

      # Process one file end-to-end: extract → chunk → embed → upsert. Catches
      # the "skip" cases ({FileType} refusal, after-enumeration race, malformed
      # PDF) as a single WARN rather than aborting the index; embedder/backend
      # failures still propagate.
      #
      # @return [Integer] chunks emitted for this file.
      def index_file(root:, path:, i:, total:)
        source = relative_source(path)
        pieces = begin
          pieces_for(path)
        rescue ArgumentError, Errno::ENOENT, RuntimeError => e
          LOGGER.warn("[#{i}/#{total}] skipping #{source}: #{e.message}")
          return 0
        end

        if pieces.empty?
          LOGGER.warn("[#{i}/#{total}] #{source}: no extractable text, skipping")
          return 0
        end

        # embed_and_build is outside the rescue so an embedder failure
        # propagates and aborts the run (see "Errors mid-indexing").
        chunks, vectors = embed_and_build(source: source, path: path, pieces: pieces)
        @backend.upsert(chunks: chunks, vectors: vectors)
        LOGGER.info("[#{i}/#{total}] #{source}: #{chunks.length} chunk(s)")
        chunks.length
      end

      # Normalize one +exclude:+ entry to its path components under {#root}.
      #
      # @param entry [String, Pathname] relative to {#root}, or absolute.
      # @return [Array<String>]
      # @raise [ArgumentError] if it lies outside {#root}.
      def exclusion(entry)
        rel = Pathname.new(entry).expand_path(root).relative_path_from(root)
        parts = rel.each_filename.to_a
        if parts.empty? || parts.first == '..'
          raise ArgumentError, "exclude #{entry.to_s.inspect} is not inside #{root}"
        end

        parts
      end

      # The relative path used as {Chunk#source} — the file's path
      # from {#root}. Single definition so the boot walk, the
      # incremental reindex, and the reconcile sweep all derive the
      # identical citation (and hence identical chunk ids) for a file.
      #
      # @param path [Pathname] an absolute path under {#root}.
      # @return [String]
      def relative_source(path)
        path.relative_path_from(root).to_s
      end

      # Read + chunk one file. Raised exceptions ({FileType} refusal, race,
      # malformed PDF) are left for the caller to interpret (boot skip vs.
      # incremental removal).
      #
      # @param path [Pathname]
      # @return [Array<Chunker::Piece>] empty when there's no extractable text.
      def pieces_for(path)
        @chunker.chunk(Pikuri::FileType.read_as_text(path))
      end

      # Embed the pieces' texts and assemble {Chunk}s with stable ids
      # (+"source:ordinal"+) and the metadata {Chunk} documents. Shared by
      # {#index_file} and {#reindex_file!} so boot and incremental reindex
      # produce byte-identical chunks. Keep the embed (the one network call)
      # out of any rescue that would swallow an outage.
      #
      # @param source [String]
      # @param path [Pathname] hashed for the +hash+ metadata.
      # @param pieces [Array<Chunker::Piece>] non-empty.
      # @return [Array(Array<Chunk>, Array<Array<Float>>)]
      def embed_and_build(source:, path:, pieces:)
        hash    = file_hash(path)
        vectors = @embedder.embed(pieces.map(&:text))
        chunks  = pieces.each_with_index.map do |piece, idx|
          Chunk.new(
            id: "#{source}:#{idx}",
            source: source,
            text: piece.text,
            metadata: { ordinal: idx, hash: hash, first_line: piece.first_line, last_line: piece.last_line }
          )
        end
        [chunks, vectors]
      end

      # SHA-256 of the file's raw bytes — the change signal the
      # reconcile sweep diffs against {Backend#sources_with_hashes}.
      # Bytes, deliberately not extracted text: a chunker/embedder
      # config change does *not* alter the hash, so the sweep won't
      # react to it. Changing those settings needs a full
      # +vectordb_reindex+ — documented loudly on {Extension}.
      #
      # @param path [Pathname]
      # @return [String] hex digest.
      def file_hash(path)
        Digest::SHA256.hexdigest(File.binread(path))
      end
    end
  end
end
