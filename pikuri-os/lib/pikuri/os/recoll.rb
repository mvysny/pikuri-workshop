# frozen_string_literal: true

require 'base64'

module Pikuri
  module Os
    # Backend wrapper over the +recoll+ full-text index, via its headless
    # +recollq+ CLI (Xapian-backed). The DE-independent sibling of
    # {LocalSearch}: same seam shape ({.search} / {.read_text} /
    # {.unavailable_reason}), interchangeable behind the +fileindex_search+ /
    # +fileindex_read+ tools; {FileIndex.pick} takes it when localsearch
    # isn't ready.
    #
    # Recall on prose ties +localsearch+, so recoll is *not* a better
    # engine — it earns its place where +localsearch+ is structurally blind
    # (source trees, +.git+ checkouts, non-GNOME desktops). Its blind spot
    # is the inverse: recoll indexes exactly the *folders* the user
    # configured (+topdirs+), source code included — everything outside them
    # is invisible. The measured survey behind the pick-one-per-host order
    # is in +pikuri-os/design/architecture.md+.
    #
    # {.search} asks +recollq -F 'url abstract dbytes'+ for three base64-encoded
    # fields per line (recoll's own recommended machine shape) so paths and
    # snippets with spaces/brackets/newlines survive with no escaping
    # guesswork. {.read_text} uses +recollq -d+, which dumps a document's
    # stored/extracted text (PDFs/office docs included) after a header line.
    module Recoll
      # @return [String] the headless recoll query CLI.
      BINARY = 'recollq'

      # @return [String] the recoll indexer/config CLI (used only to locate
      #   the config; never invoked to *index* from here).
      INDEXER = 'recollindex'

      # @return [String] recoll config filename inside the config dir.
      CONFIG_FILE = 'recoll.conf'

      # recoll's compiled-in default when +topdirs+ is unset: the whole
      # home directory (the sample config ships +topdirs = ~+ too).
      #
      # @return [String]
      DEFAULT_TOPDIRS = '~'

      # @return [String] the Xapian index directory name inside the config
      #   dir; missing until +recollindex+ first runs.
      INDEX_DIR = 'xapiandb'

      # @return [String] a query matching every document in the index.
      ANY_DOCUMENT = 'mime:*'

      # Raised when a recollq invocation exits non-zero — a recoverable
      # failure the calling tool renders as +"Error: ..."+.
      class CommandError < StandardError; end

      # @return [String] short human name for this backend, used by the
      #   fileindex tools when prefixing an +"Error: ..."+ observation.
      def self.label = 'recoll'

      # Plain-English note of what this backend will *not* surface, appended
      # to the fileindex tools' LLM description so the model knows when to
      # fall back to a filesystem text/regex search. A *method*, not a
      # constant like {LocalSearch::LIMITATIONS}, because the blind spot is
      # host-specific: the user's +topdirs+, only readable at runtime
      # ({.indexed_dirs}). Falls back to a generic caveat when the config
      # can't be read.
      #
      # @return [String]
      def self.limitations
        dirs = indexed_dirs
        return generic_limitation if dirs.empty?

        listed = dirs.map { |dir| "- #{dir}" }.join("\n")
        <<~LIMITS.chomp
          Only files under these folders are indexed (anything elsewhere on disk is not in this index — search those files' text directly instead):
          #{listed}
        LIMITS
      end

      # Folders recoll is configured to index, read from +topdirs+ in the
      # active config file. Resolution mirrors recoll itself: the config dir
      # is +$RECOLL_CONFDIR+ or +~/.recoll+; +topdirs+ is a space-separated
      # list (quoted entries may contain spaces, a trailing +\+ continues to
      # the next line) living in the global section, i.e. above the first
      # +[section]+ header. Entries are +~+- and +$VAR+-expanded to absolute
      # paths. Defaults to the home dir ({DEFAULT_TOPDIRS}) when the config
      # is absent or names no +topdirs+, matching recoll's own default.
      #
      # @return [Array<String>] absolute folder paths, or +[]+ if the config
      #   dir exists but the file is unreadable
      def self.indexed_dirs
        path = File.join(confdir, CONFIG_FILE)
        raw = File.exist?(path) ? File.read(path) : nil
        entries = raw ? parse_topdirs(raw) : [DEFAULT_TOPDIRS]
        entries = [DEFAULT_TOPDIRS] if entries.empty?
        entries.map { |entry| expand_entry(entry) }
      rescue SystemCallError
        []
      end

      # The recoll configuration directory recoll would use: +$RECOLL_CONFDIR+
      # if set and non-empty, else +~/.recoll+.
      #
      # @return [String]
      def self.confdir
        env = ENV['RECOLL_CONFDIR']
        env && !env.empty? ? File.expand_path(env) : File.expand_path('~/.recoll')
      end

      # Run +recollq -F 'url abstract dbytes' -n <limit>+ and parse the results.
      # A +folder+ becomes a +dir:"<folder>"+ clause, which recoll matches by
      # whole path components (+/a/sp+ does not match +/a/sp ace+).
      #
      # @param query [String] recoll query-language string
      # @param limit [Integer]
      # @param folder [String, nil] absolute folder to search under; +nil+
      #   searches the whole index
      # @return [Array<Hash>] +[{ path: String, snippet: String|nil,
      #   text_size: Integer|nil }, …]+, de-duplicated by path; +text_size+
      #   is the extracted text's bytes (+dbytes+), +nil+ when there is none
      # @raise [CommandError] if recollq exits non-zero, or +folder+ contains
      #   a +"+ (recoll's query language cannot quote one)
      def self.search(query:, limit:, folder: nil)
        if folder
          raise CommandError, "can't search a folder whose path contains a double quote: #{folder}" if folder.include?('"')

          query = "#{query} dir:\"#{folder}\""
        end
        result = Pikuri::Subprocess.spawn(BINARY, '-F', 'url abstract dbytes', '-n', limit.to_s, query,
                                          chdir: '/').wait
        unless result.status.success?
          stderr = result.output.strip
          stderr = "exited #{result.status.exitstatus}" if stderr.empty?
          raise CommandError, stderr
        end

        parse_search_output(result.output)
      end

      # Parse +recollq -F 'url abstract dbytes'+ output into hits. Each data
      # line is three base64 tokens (url, abstract, text bytes); an empty field
      # still prints a token. recollq's +"Recoll query: …"+ /
      # +"N results"+ banner lines are skipped because their first token
      # isn't valid base64 for a +file://+ URL.
      #
      # @param raw [String]
      # @return [Array<Hash>] +[{ path:, snippet:, text_size: }, …]+ de-duped
      #   by path
      def self.parse_search_output(raw)
        hits = []
        raw.each_line do |line|
          url_b64, abstract_b64, dbytes_b64 = line.chomp.split(/ /)
          url = decode_base64(url_b64)
          next unless url&.start_with?('file://')

          snippet = decode_base64(abstract_b64.to_s)&.strip
          size = decode_base64(dbytes_b64.to_s).to_i
          hits << { path: url.delete_prefix('file://'), snippet: (snippet unless snippet.to_s.empty?),
                    text_size: (size if size.positive?) }
        end
        hits.uniq { |hit| hit[:path] }
      end

      # Full stored/extracted text of an indexed file, via +recollq -d+
      # scoped to the file's own name. Works for PDFs/office docs (extracted
      # at index time). +nil+ when the path isn't in the index or has no
      # stored text — the caller turns that into an LLM-facing message.
      #
      # @param path [String]
      # @return [String, nil]
      def self.read_text(path)
        abs = File.expand_path(path)
        result = Pikuri::Subprocess.spawn(BINARY, '-d', '-n', '50', "filename:#{File.basename(abs)}",
                                          chdir: '/').wait
        return nil unless result.status.success?

        text = extract_dumped_text(result.output, abs)
        text && !text.strip.empty? ? text : nil
      end

      # Pull the dumped body of the result whose header line matches +abs+
      # out of +recollq -d+ output. Each result is a tab-delimited header
      # line (+<mime>\t[<url>]\t[<title>]\t<n>\tbytes+) followed by its text,
      # up to the next header line.
      #
      # @param raw [String]
      # @param abs [String] absolute path to match against the header URL
      # @return [String, nil]
      def self.extract_dumped_text(raw, abs)
        want = "file://#{abs}"
        body = []
        capturing = false
        raw.each_line do |line|
          url = line[%r{\t\[(file://[^\]]*)\]\t}, 1]
          if url
            break if capturing

            capturing = (url == want)
          elsif capturing
            body << line
          end
        end
        capturing || !body.empty? ? body.join.chomp : nil
      end

      # Why this index can't answer a search right now, for a human to act
      # on; +nil+ when it can. A built index holding no documents is not
      # ready either: every search would come back empty.
      #
      #   Recoll.unavailable_reason
      #   # => "no index in /home/u/.recoll yet. Build one with `recollindex`."
      #
      # @return [String, nil]
      def self.unavailable_reason
        result = Pikuri::Subprocess.spawn(BINARY, '-F', 'url', '-n', '1', ANY_DOCUMENT, chdir: '/').wait
        unless result.status.success?
          return "no index in #{confdir} yet. Build one with `recollindex`." unless File.directory?(File.join(confdir, INDEX_DIR))

          return "the index in #{confdir} doesn't answer: #{result.output.strip.lines.last&.strip}"
        end
        return nil if result.output.each_line.any? { |line| decode_base64(line.strip)&.start_with?('file://') }

        "the index in #{confdir} holds no documents. Check `topdirs` in " \
          "#{File.join(confdir, CONFIG_FILE)}, then rerun `recollindex`."
      rescue Errno::ENOENT
        "the '#{BINARY}' command is missing. Install the 'recoll' package, then build an index " \
          'with `recollindex`.'
      end

      # Join backslash-continued lines, then read the +topdirs+ value from
      # the global section (everything before the first +[section]+ header).
      # The last assignment wins (ConfSimple semantics).
      #
      # @param raw [String]
      # @return [Array<String>] raw (unexpanded) topdirs entries
      def self.parse_topdirs(raw)
        value = nil
        joined_lines(raw).each do |line|
          stripped = line.strip
          break if stripped.start_with?('[')       # first [section] ends the global scope
          next if stripped.empty? || stripped.start_with?('#')

          key, _, rest = stripped.partition('=')
          value = rest if key.strip == 'topdirs'
        end
        value ? tokenize(value) : []
      end

      # @param raw [String]
      # @return [Array<String>] logical lines with trailing-backslash
      #   continuations folded into one
      def self.joined_lines(raw)
        lines = []
        buffer = +''
        raw.each_line(chomp: true) do |line|
          if line.end_with?('\\')
            buffer << line[0..-2] << ' '
          else
            lines << (buffer + line)
            buffer = +''
          end
        end
        lines << buffer unless buffer.empty?
        lines
      end
      private_class_method :joined_lines

      # Split a topdirs value into entries, honouring +"double quotes"+
      # around paths that contain spaces.
      #
      # @param value [String]
      # @return [Array<String>]
      def self.tokenize(value)
        value.scan(/"([^"]*)"|(\S+)/).map { |quoted, bare| quoted || bare }
      end
      private_class_method :tokenize

      # Expand +$VAR+ / +${VAR}+ then +~+ to an absolute path; a relative
      # entry resolves against the home dir (recoll's own base).
      #
      # @param entry [String]
      # @return [String]
      def self.expand_entry(entry)
        env_expanded = entry.gsub(/\$\{(\w+)\}|\$(\w+)/) { ENV[::Regexp.last_match(1) || ::Regexp.last_match(2)] || '' }
        File.expand_path(env_expanded, Dir.home)
      end
      private_class_method :expand_entry

      # @param token [String, nil]
      # @return [String, nil] decoded bytes tagged UTF-8, or +nil+ if +token+
      #   is blank or not valid strict base64
      def self.decode_base64(token)
        return nil if token.nil? || token.empty?

        Base64.strict_decode64(token).force_encoding('UTF-8')
      rescue ArgumentError
        nil
      end
      private_class_method :decode_base64

      # @return [String]
      def self.generic_limitation
        'Only folders configured in recoll (topdirs) are indexed; files ' \
          "outside them are not found — search those files' text directly instead."
      end
      private_class_method :generic_limitation
    end
  end
end
