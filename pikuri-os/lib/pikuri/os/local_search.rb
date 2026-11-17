# frozen_string_literal: true

module Pikuri
  module Os
    # The GNOME desktop file index (+localsearch+, formerly tracker-miners),
    # queried in SPARQL through the +tinysparql+ CLI. The stateless backend
    # behind +fileindex_search+ / +fileindex_read+:
    #
    #   LocalSearch.search(query: 'lease', limit: 10, folder: '/home/u/Documents')
    #   # => [{ path: '/home/u/Documents/Housing/lease-agreement.pdf',
    #   #       snippet: 'Residential >>Lease<< Agreement Landlord: …',
    #   #       text_size: 4211 }, …]
    #   LocalSearch.read_text('/home/u/Documents/Housing/lease-agreement.pdf')
    #   # => "Residential Lease Agreement\nLandlord: …"   (nil when not indexed)
    #
    # Hits are ranked by relevance, one per file, each with one snippet of
    # about {SNIPPET_WORDS} words around the match, matched words marked
    # +>>like this<<+; a file matches by its name or its extracted text. PDFs
    # and office docs come for free: the index extracted their text, so
    # {.read_text} needs no extractor here.
    #
    # Needs +localsearch+ (the indexing daemon, a GNOME default) and the
    # +tinysparql+ CLI, which Debian/Ubuntu's +localsearch+ package depends on.
    #
    # == Implementation details
    #
    # Why SPARQL and not +localsearch search+: that CLI sorts its hits by
    # path, not relevance, before applying the limit, and cannot filter by
    # folder — so a common word returned the first ten paths A–Z under +$HOME+.
    #
    # +tinysparql query+ prints a row as its cells joined by +", "+, which
    # snippets and paths also contain. So every cell leaves SPARQL as
    # +"v:" + ENCODE_FOR_URI(value)+: no comma, space or newline survives
    # encoding, and the +v:+ marker sets data rows apart from the CLI's
    # +Results:+ / +None+ lines, which are translated by locale.
    #
    # Index URLs use GLib's escaping ({.file_uri}); a folder filter or a read
    # built with any other escaping silently matches nothing.
    module LocalSearch
      # @return [String] the SPARQL query CLI.
      BINARY = 'tinysparql'

      # @return [String] the D-Bus name the localsearch daemon serves its
      #   index under; querying it starts the daemon through D-Bus activation.
      DBUS_SERVICE = 'org.freedesktop.LocalSearch3'

      # @return [Integer] words of context in a snippet: enough to tell an
      #   invoice from a book that mentions one without reading either.
      SNIPPET_WORDS = 40

      # @return [Array(String, String)] what wraps each matched word in a
      #   snippet, so the model sees which words hit.
      MATCH_MARKERS = ['>>', '<<'].freeze

      # The ranked, folder-scoped search. A file matches by name (first
      # branch, no snippet) or by extracted text (second branch); +MAX+ over
      # the group keeps the better rank and the non-empty snippet. The
      # +OPTIONAL+ measures the file's stored text whichever branch matched;
      # a file indexed by name only leaves it unbound.
      #
      # @return [String]
      SEARCH_QUERY = <<~SPARQL
        SELECT (CONCAT("v:", ENCODE_FOR_URI(?url)) AS ?u)
               (CONCAT("v:", ENCODE_FOR_URI(MAX(?snippet))) AS ?s)
               (CONCAT("v:", STR(MAX(?length))) AS ?n)
        WHERE {
          {
            ?f fts:match ~query .
            BIND (fts:rank(?f) AS ?rank)
            BIND ("" AS ?snippet)
          } UNION {
            ?elem fts:match ~query ;
              nie:isStoredAs ?f .
            BIND (fts:rank(?elem) AS ?rank)
            BIND (fts:snippet(?elem, "#{MATCH_MARKERS[0]}", "#{MATCH_MARKERS[1]}", "…", #{SNIPPET_WORDS}) AS ?snippet)
          }
          ?f nie:url ?url .
          OPTIONAL {
            ?stored nie:isStoredAs ?f ;
              nie:plainTextContent ?text .
            BIND (STRLEN(?text) AS ?length)
          }
          FILTER (tracker:available(nie:dataSource(?f)))
          FILTER (STRSTARTS(?url, ~prefix))
        }
        GROUP BY ?url
        ORDER BY DESC(MAX(?rank)) ?url
        LIMIT ~limit
      SPARQL

      # @return [String] the stored text of the file at +~url+.
      READ_QUERY = <<~SPARQL
        SELECT (CONCAT("v:", ENCODE_FOR_URI(?text)) AS ?t)
        WHERE {
          ?f nie:url ~url .
          ?elem nie:isStoredAs ?f ;
            nie:plainTextContent ?text .
        }
        LIMIT 1
      SPARQL

      # Any one searchable file: a folder alone gives a search nothing to
      # find, and a file on an unmounted drive is filtered as {SEARCH_QUERY}
      # filters it.
      #
      # @return [String]
      PROBE_QUERY = <<~SPARQL
        SELECT (CONCAT("v:", ENCODE_FOR_URI(?url)) AS ?u)
        WHERE {
          ?f nie:url ?url .
          ?elem nie:isStoredAs ?f .
          FILTER NOT EXISTS { ?elem a nfo:Folder }
          FILTER (tracker:available(nie:dataSource(?f)))
        }
        LIMIT 1
      SPARQL

      # @return [Regexp] a byte GLib leaves unescaped in a +file://+ URI
      #   (+g_filename_to_uri+'s set, measured against the index); anything
      #   else, non-ASCII included, is +%XX+ per byte.
      URI_SAFE = %r{[A-Za-z0-9\-._~!$&'()*+,=:@/]}

      # Raised when a tinysparql invocation exits non-zero — a recoverable
      # failure the calling tool renders as +"Error: ..."+.
      class CommandError < StandardError; end

      # @return [String] short human name for this backend, used by the
      #   fileindex tools when prefixing an +"Error: ..."+ observation.
      def self.label = 'localsearch'

      # Uniform accessor mirroring {Recoll.limitations}; a constant here
      # because this index's blind spots are the same on every host.
      #
      # @return [String]
      def self.limitations = LIMITATIONS

      # What this index will not surface, appended to the fileindex tools'
      # LLM description so the model knows when to search the files directly
      # instead. Measured; see +pikuri-os/design/architecture.md+.
      #
      # @return [String]
      LIMITATIONS = <<~LIMITS.chomp
        Not covered by this index (fall back to a text/regex search over the files for these):
        - Source code and other developer files are not content-indexed — only their names are. Search their text directly.
        - Nothing inside a git checkout is indexed (any folder containing a .git). Search those files directly.
      LIMITS

      # Ranked full-text search, optionally limited to one folder's subtree.
      #
      # @param query [String] words to match, stemmed and ANDed by the index
      # @param limit [Integer] max files returned
      # @param folder [String, nil] absolute folder to search under; +nil+
      #   searches the whole index
      # @return [Array<Hash>] +[{ path: String, snippet: String|nil,
      #   text_size: Integer|nil }, …]+, best first, one per file;
      #   +text_size+ is the stored text's length in characters (SPARQL has
      #   no byte length; the two differ only by the non-ASCII share), +nil+
      #   for a file indexed by name only
      # @raise [CommandError] if tinysparql exits non-zero
      def self.search(query:, limit:, folder: nil)
        prefix = folder ? "#{file_uri(folder).chomp('/')}/" : 'file:///'
        raw = run(SEARCH_QUERY, query: query, prefix: prefix, limit: limit)
        parse_rows(raw).map do |url, snippet, length|
          snippet = snippet&.gsub(/\s+/, ' ')&.strip
          { path: path_of(url), snippet: (snippet unless snippet.to_s.empty?), text_size: length&.to_i }
        end
      end

      # Full stored plain text of an indexed file. Works for PDFs/office docs
      # (extracted at index time).
      #
      # @param path [String] absolute path
      # @return [String, nil] +nil+ when the path isn't indexed, has no stored
      #   text, or the query fails — the caller turns that into an LLM-facing
      #   message
      def self.read_text(path)
        row = parse_rows(run(READ_QUERY, url: file_uri(File.expand_path(path)))).first
        text = row&.first
        text && !text.strip.empty? ? text : nil
      rescue CommandError
        nil
      end

      # Why this index can't answer a search right now, for a human to act
      # on; +nil+ when it can. An index that answers but holds no files is
      # not ready either: every search would come back empty.
      #
      #   LocalSearch.unavailable_reason
      #   # => "the index holds no files yet. …"   (nil when ready)
      #
      # Starts the localsearch daemon if it is installed but not running, as
      # any query does (D-Bus activation).
      #
      # @return [String, nil]
      def self.unavailable_reason
        return nil unless parse_rows(run(PROBE_QUERY)).empty?

        'the index holds no files yet. Right after a first login GNOME may still be ' \
          'indexing: `localsearch status` shows how far it got. Otherwise pick the ' \
          'folders to index under GNOME Settings → Search.'
      rescue Errno::ENOENT
        "the '#{BINARY}' command is missing. Install the 'localsearch' and '#{BINARY}' " \
          "packages: GNOME's desktop file index and its query tool."
      rescue CommandError => e
        "the index doesn't answer (#{e.message}). Is the 'localsearch' package " \
          "installed? It is GNOME's desktop file indexer."
      end

      # The +file://+ URI the index stores for +path+, escaped the way GLib
      # escapes it.
      #
      #   LocalSearch.file_uri('/home/u/My Notes/ü#1.txt')
      #   # => "file:///home/u/My%20Notes/%C3%BC%231.txt"
      #
      # @param path [String] absolute path
      # @return [String]
      def self.file_uri(path)
        escaped = path.b.gsub(/./mn) { |c| c.match?(URI_SAFE) ? c : format('%%%02X', c.ord) }
        "file://#{escaped}"
      end

      # Parse +tinysparql query+ output into rows of decoded cells. Only rows
      # whose every cell carries the +v:+ marker count (see the class doc).
      #
      # @param raw [String] the CLI's stdout
      # @return [Array<Array<String, nil>>] one array of cells per row; an
      #   unbound cell (+(null)+) is +nil+
      def self.parse_rows(raw)
        raw.each_line(chomp: true).filter_map do |line|
          next unless line.start_with?('  ')

          cells = line.strip.split(', ')
          next unless cells.all? { |cell| cell == '(null)' || cell.start_with?('v:') }

          cells.map { |cell| cell == '(null)' ? nil : percent_decode(cell.delete_prefix('v:')) }
        end
      end

      # @param query [String] SPARQL text
      # @param args [Hash{Symbol => String, Integer}] the query's +~name+
      #   parameters
      # @return [String] stdout
      # @raise [CommandError] on a non-zero exit
      # @raise [Errno::ENOENT] if tinysparql is missing
      def self.run(query, **args)
        argv = [BINARY, 'query', '-b', DBUS_SERVICE]
        args.each do |name, value|
          type = value.is_a?(Integer) ? 'i' : 's'
          argv.push('--arg', "#{name}:#{type}:#{value}")
        end
        argv.push('-q', query)
        result = Pikuri::Subprocess.spawn(*argv, chdir: '/').wait
        return result.output if result.status.success?

        message = result.output.strip
        raise CommandError, message.empty? ? "exited #{result.status.exitstatus}" : message
      end
      private_class_method :run

      # @param url [String] a +file://+ URI from the index
      # @return [String] the absolute path it names
      def self.path_of(url)
        percent_decode(url.delete_prefix('file://'))
      end
      private_class_method :path_of

      # @param encoded [String]
      # @return [String] +%XX+ decoded per byte, tagged UTF-8
      def self.percent_decode(encoded)
        encoded.b.gsub(/%([0-9A-Fa-f]{2})/n) { ::Regexp.last_match(1).hex.chr }.force_encoding('UTF-8')
      end
      private_class_method :percent_decode
    end
  end
end
