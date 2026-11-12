# frozen_string_literal: true

require 'json'

module Pikuri
  module Os
    # Backend wrapper over GNOME's +localsearch+ CLI (the desktop file
    # index, 2024 rename of tracker3 / tracker-miners). Not a
    # {Pikuri::Tool} — the shared, stateless seam behind
    # +fileindex_search+ / +fileindex_read+, so localsearch-specific
    # knowledge (argv, parsing, json-ld extraction, binary probe) lives in
    # one place.
    #
    # +localsearch search+ returns at most *one* match snippet per file
    # from a possibly-stale index. {.search} returns exactly those
    # one-per-file hits and the tools tell the LLM to read the file for the
    # rest — enumerating every per-file hit would need a stemmer (the index
    # is stemmed, "mouse" matches "mice"), deliberately out of scope.
    #
    # PDFs and office docs come for free: the index extracted their text at
    # index time, so {.read_text} returns it via +info -c+ with no
    # extractor dependency here.
    module LocalSearch
      # @return [String] the localsearch CLI.
      BINARY = 'localsearch'

      # @return [String] short human name for this backend, used by the
      #   fileindex tools when prefixing an +"Error: ..."+ observation.
      def self.label = 'localsearch'

      # Uniform accessor mirroring {Recoll.limitations}. A constant here
      # (unlike recoll's runtime method) because this backend's blind spots
      # are the same on every host.
      #
      # @return [String]
      def self.limitations = LIMITATIONS

      # Plain-English note of this backend's *structural* blind spots,
      # appended to the fileindex tools' LLM description so the model knows
      # when to fall back to a filesystem text/regex search. Lives on the
      # backend (a different index ships its own). All three are confirmed
      # against GNOME localsearch (measured; see +pikuri-os/design/architecture.md+).
      #
      # @return [String]
      LIMITATIONS = <<~LIMITS.chomp
        Not covered by this index (fall back to a text/regex search over the files for these):
        - Source code and other developer files are not content-indexed — only their names are. Search their text directly.
        - Nothing inside a git checkout is indexed (any folder containing a .git). Search those files directly.
        - No folder scoping: it ranks across your whole home at once, so a common word confined to one project may stay buried below the results shown. Prefer distinctive words, or search that folder's text directly.
      LIMITS

      # Raised when a localsearch invocation exits non-zero — a
      # recoverable failure the calling tool renders as +"Error: ..."+.
      class CommandError < StandardError; end

      # @return [Regexp] one ANSI SGR escape (color/bold), stripped from
      #   snippets before they reach the LLM.
      ANSI_SGR = /\e\[[0-9;]*m/

      # Run +localsearch search -d --limit <limit> <query>+ and parse the
      # results. +-d+ adds the (ignored) URN and, on the line after each
      # path, a short snippet with the matched word highlighted; we strip
      # the ANSI and keep the text.
      #
      # @param query [String]
      # @param limit [Integer]
      # @return [Array<Hash>] +[{ path: String, snippet: String|nil }, …]+,
      #   de-duplicated by path
      # @raise [CommandError] if localsearch exits non-zero
      def self.search(query:, limit:)
        result = Pikuri::Subprocess.spawn(BINARY, 'search', '-d', '--limit', limit.to_s, query,
                                          chdir: '/').wait
        unless result.status.success?
          stderr = result.output.strip
          stderr = "exited #{result.status.exitstatus}" if stderr.empty?
          raise CommandError, stderr
        end

        parse_search_output(result.output)
      end

      # Parse +localsearch search -d+ output into hits. Each result is a
      # +file://<uri> (urn:…)+ line followed by an indented snippet line;
      # the path is percent-decoded and the snippet ANSI-stripped.
      #
      # @param raw [String]
      # @return [Array<Hash>] +[{ path:, snippet: }, …]+ de-duped by path
      def self.parse_search_output(raw)
        hits = []
        current = nil
        raw.each_line do |line|
          encoded = line[%r{\Afile://(\S+)}, 1]
          if encoded
            current = { path: decode_file_uri(encoded), snippet: nil }
            hits << current
          elsif current && current[:snippet].nil? && !line.strip.empty?
            current[:snippet] = line.gsub(ANSI_SGR, '').strip
          end
        end
        hits.uniq { |hit| hit[:path] }
      end

      # Full stored plain text of an indexed file, via +localsearch info
      # -c -o json-ld <path>+. Works for PDFs/office docs (extracted at
      # index time). +nil+ when the path isn't in the index or has no
      # stored text — the caller turns that into an LLM-facing message.
      #
      # @param path [String]
      # @return [String, nil]
      def self.read_text(path)
        result = Pikuri::Subprocess.spawn(BINARY, 'info', '-c', '-o', 'json-ld', path,
                                          chdir: '/').wait
        return nil unless result.status.success?

        text = extract_plain_text(result.output)
        text && !text.strip.empty? ? text : nil
      end

      # Find +nie:plainTextContent+ anywhere in the json-ld document (it
      # nests under +@graph+, a named graph). Lenient: if the raw bytes
      # don't parse as JSON (a stray diagnostic prefix), retry from the
      # first +{+.
      #
      # @param raw [String]
      # @return [String, nil]
      def self.extract_plain_text(raw)
        data = parse_json_lenient(raw)
        data && find_plain_text(data)
      end

      # Verify localsearch is reachable; raise loudly otherwise.
      #
      # @raise [RuntimeError] if the binary is missing or unusable
      def self.check_binaries!
        result = Pikuri::Subprocess.spawn(BINARY, '--version', chdir: '/').wait
        return if result.status.success?

        raise install_hint
      rescue Errno::ENOENT
        raise install_hint
      end

      # Non-raising presence probe — lets a caller wire the file-index
      # tools only when localsearch is installed and degrade gracefully
      # otherwise, rather than failing the whole agent.
      #
      # @return [Boolean]
      def self.available?
        Pikuri::Subprocess.spawn(BINARY, '--version', chdir: '/').wait.status.success?
      rescue Errno::ENOENT
        false
      end

      # @param encoded [String] the tail of a +file://+ URI
      # @return [String] percent-decoded path (+%XX+ only, UTF-8 tagged)
      def self.decode_file_uri(encoded)
        encoded.gsub(/%([0-9A-Fa-f]{2})/) { ::Regexp.last_match(1).hex.chr }
               .force_encoding('UTF-8')
      end
      private_class_method :decode_file_uri

      # @return [Object, nil]
      def self.parse_json_lenient(raw)
        JSON.parse(raw)
      rescue JSON::ParserError
        brace = raw.index('{')
        return nil unless brace

        begin
          JSON.parse(raw[brace..])
        rescue JSON::ParserError
          nil
        end
      end
      private_class_method :parse_json_lenient

      # @param node [Object]
      # @return [String, nil] first String under a +nie:plainTextContent+
      #   key, depth-first
      def self.find_plain_text(node)
        case node
        when Hash
          node.each do |key, value|
            return value if key == 'nie:plainTextContent' && value.is_a?(String)

            found = find_plain_text(value)
            return found if found
          end
          nil
        when Array
          node.each do |element|
            found = find_plain_text(element)
            return found if found
          end
          nil
        end
      end
      private_class_method :find_plain_text

      # @return [String]
      def self.install_hint
        "fileindex_search / fileindex_read require '#{BINARY}' on PATH — GNOME's " \
          "desktop file indexer (package 'localsearch', formerly 'tracker-miners'), " \
          'which ships with the GNOME desktop on Ubuntu 26.04+. Install it, or wire ' \
          'these tools only on hosts that have it.'
      end
      private_class_method :install_hint
    end
  end
end
