# frozen_string_literal: true

module Pikuri
  module Os
    # The +fileindex_search+ tool — a fast, cheap keyword lookup over a
    # desktop file index, returning matching paths each with the *single*
    # snippet the index provides and the size of its indexed text, so the
    # model can tell a file it may read whole from one it should search
    # with +fileindex_read+'s +pattern+. A {Pikuri::Tool} in the
    # {Pikuri::Workspace::Search::Grep} shape, shelling out through the
    # backend.
    #
    # The +backend:+ is the stateless module {FileIndex.pick} returns —
    # {LocalSearch} or {Recoll}. Backend-specific text (the blind-spot note,
    # the error label) is read from the backend, so a new index arm ships
    # its own without touching the tool.
    #
    # It's a locator, not a window: the index reports at most one match per
    # file, so the tool previews one match each and tells the LLM to read
    # the file for full content / other matches. It sees inside PDFs and
    # office docs (indexed at extract time), and being an index lookup is
    # cheap to run repeatedly.
    #
    # Sharing: +P_stateless+ — the backend is a stateless module and each call
    # shells out to its own query, so one instance serves any number of agents.
    class FileindexSearch < Pikuri::Tool
      # @return [Integer] default / max matching files returned.
      DEFAULT_LIMIT = 10
      MAX_LIMIT     = 25

      # @return [Integer] hard byte cap on combined output (matches
      #   {Pikuri::Workspace::Search::Grep::MAX_BYTES}).
      MAX_BYTES = 50 * 1024

      # @return [String] human-readable form of {MAX_BYTES}.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # @return [String] how much text one +fileindex_read+ call returns,
      #   the yardstick a hit's text size is read against.
      READ_PAGE_LABEL = Pikuri::Tool.format_bytes(Pikuri::Extractor::PAGE_MAX_BYTES)

      # @return [String] opencode-shape description (summary + Usage),
      #   backend-neutral. The *runtime* tool description is this constant
      #   plus the backend's +#limitations+, appended at construction (see
      #   {#initialize}) — and it is that appended text, not this constant,
      #   that states *which folders the index actually covers* and what it
      #   misses (recoll lists its +topdirs+; localsearch names source code
      #   and git checkouts). So keep coverage claims out of here; they
      #   belong with the backend that knows them.
      DESCRIPTION = <<~DESC
        Find files whose contents contain your words or phrase, using the desktop search index.

        Usage:
        - Searches inside PDFs, Word/ODT/spreadsheet documents and plain text — reach for this when the answer may live in a file's contents.
        - Keyword match (and word stems); type the actual words that would appear in the file.
        - Pass `folder` to search only under one folder (subfolders included) — the way to find a common word inside one project instead of across the whole disk.
        - The index returns at most ONE match per file and may be slightly stale — this is a locator, not the full story. To read a file's full, current text, read it (see fileindex_read).
        - Each file shows the size of its indexed text. fileindex_read returns up to #{READ_PAGE_LABEL} per call, so a smaller file reads whole in one call; in a bigger one, find the lines you need with fileindex_read's `pattern` first.
        - Cheap: it queries a prebuilt index rather than walking the filesystem, so it barely touches the disk of the machine the user is on — fine to run many times to narrow down.
        - Only indexed folders are covered; system paths like /etc or /var are not — search those with a text/regex tool instead.
        - Output is truncated to #{MAX_BYTES_LABEL}; narrow the query if it ends in a truncation marker.
      DESC

      # @param backend [Module] a ready file-index backend, from
      #   {FileIndex.pick}; this tool uses its +search+, +limitations+,
      #   +label+ and +CommandError+.
      # @return [FileindexSearch]
      def initialize(backend:)
        @backend = backend
        super(
          name: 'fileindex_search',
          description: "#{DESCRIPTION}\n#{backend.limitations}",
          parameters: Parameters.build { |p|
            p.required_string :query,
                              'Words or a phrase to find in file contents, ' \
                              'e.g. "tax return 2024".'
            p.optional_integer :limit,
                               "Max number of matching files to return " \
                               "(default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}), e.g. 10."
            p.optional_string :folder,
                              'Absolute path of a folder to search under, subfolders ' \
                              'included; omit to search everything indexed, e.g. "~/Documents/taxes".'
          },
          execute: lambda { |query:, limit: DEFAULT_LIMIT, folder: nil|
            FileindexSearch.search(query: query, limit: limit, folder: folder, backend: backend)
          },
          # Private and hard untrusted, both fixed rather than derived: this searches
          # the *whole machine's* file index, which is the whole-disk case by
          # construction — a reachable set nobody can vouch for, holding whatever the
          # user keeps on disk.
          trifecta_legs: Pikuri::Tool::TrifectaLegs.new(private: true, untrusted: :hard, egress_payload_review: :no_egress)
        )
      end

      # @param query [String]
      # @param limit [Integer]
      # @param folder [String, nil] folder to search under, absolute or
      #   +~+-relative; +nil+ or blank searches everything indexed
      # @param backend [Module] the file-index backend to query
      # @return [Pikuri::Tool::Result] the hits + disclaimer (+"Found 8
      #   files"+), or {Pikuri::Tool::Result.error} for a bad +folder+ or a
      #   backend failure
      def self.search(query:, backend:, limit: DEFAULT_LIMIT, folder: nil)
        q = query.to_s.strip
        return Pikuri::Tool::Result.error('empty query.') if q.empty?

        folder = folder.to_s.strip
        folder = nil if folder.empty?
        if folder
          unless folder.start_with?('/', '~')
            return Pikuri::Tool::Result.error("folder must be an absolute path, got '#{folder}'.")
          end

          begin
            folder = File.expand_path(folder)
          rescue ArgumentError => e # "~nosuchuser"
            return Pikuri::Tool::Result.error("bad folder '#{folder}': #{e.message}")
          end
          # A file as folder reads as "every match in this file", which the
          # index can't answer: it keeps one snippet per file.
          if File.file?(folder)
            return Pikuri::Tool::Result.error("#{folder} is a file, not a folder. The index shows only one " \
                                              'match per file; to see every match in this file, read its ' \
                                              'full text with fileindex_read.')
          end
          return Pikuri::Tool::Result.error("no such folder: #{folder}") unless File.directory?(folder)
        end

        limit = clamp(limit, 1, MAX_LIMIT)
        hits = backend.search(query: q, limit: limit, folder: folder)
        if hits.empty?
          return Pikuri::Tool::Result.new(content: no_match_message(q, folder), summary: 'Found 0 files')
        end

        content, marker = head_truncate(hits.map { |hit| render_hit(hit) }.join("\n"))
        Pikuri::Tool::Result.new(
          content: [content.chomp, '', disclaimer(hits.size) + marker].join("\n"),
          summary: "Found #{Pikuri::Tool.pluralize(hits.size, 'file')}"
        )
      rescue backend::CommandError => e
        # Cap the error too — a raw subprocess error returned verbatim is
        # the shape that overflows the model's context; share the success
        # path's ceiling.
        content, marker = head_truncate(e.message)
        Pikuri::Tool::Result.error("#{backend.label}: #{content}#{marker}")
      end

      # @param hit [Hash] +{ path:, snippet:, text_size: }+ from the backend
      # @return [String] +"<path>  (<size> of text)"+, then +"\n  <snippet>"+
      #   when there is one
      def self.render_hit(hit)
        size = hit[:text_size] ? "#{Pikuri::Tool.format_bytes(hit[:text_size])} of text" : 'no indexed text'
        head = "#{hit[:path]}  (#{size})"
        hit[:snippet] && !hit[:snippet].empty? ? "#{head}\n  #{hit[:snippet]}" : head
      end
      private_class_method :render_hit

      # @return [String]
      def self.disclaimer(count)
        "Found #{count} #{count == 1 ? 'file' : 'files'} (one match shown per file; " \
          'the index may be slightly stale). Read a file to see its full text and any other matches.'
      end
      private_class_method :disclaimer

      # @return [String]
      def self.no_match_message(query, folder)
        where = folder ? " under #{folder}" : ''
        "No files found matching '#{query}'#{where}. (Searches your indexed folders, " \
          'not system paths; the index may also be disabled or still building.)'
      end
      private_class_method :no_match_message

      # Head-truncate to {MAX_BYTES} at the last newline boundary.
      #
      # @return [Array(String, String)] +[content, marker]+ (marker empty
      #   when no truncation)
      def self.head_truncate(raw)
        total = raw.bytesize
        return [raw, ''] if total <= MAX_BYTES

        head = raw.byteslice(0, MAX_BYTES)
        last_nl = head.rindex("\n")
        head = head.byteslice(0, last_nl) if last_nl
        omitted = total - head.bytesize
        [head, "\n\n... [#{omitted} bytes omitted; total was #{total} bytes; narrow the query] ..."]
      end
      private_class_method :head_truncate

      # @return [Integer] +value+ clamped to +[lo, hi]+ (lo on bad input)
      def self.clamp(value, lo, hi)
        Integer(value).clamp(lo, hi)
      rescue ArgumentError, TypeError
        lo
      end
      private_class_method :clamp
    end
  end
end
