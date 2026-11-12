# frozen_string_literal: true

module Pikuri
  module Lsp
    # A resolved query point: the server to ask, the document, and the exact
    # position inside it. Every position-based operation needs one, and **the model
    # is never asked for a column** — {.resolve} derives it.
    #
    #   resolution = Anchor.resolve(servers: servers, filesystem: filesystem,
    #                               symbol: 'resolve_for_read', file: 'read.rb', line: 165)
    #   resolution.anchors.first.params
    #   # => {textDocument: {uri: "file:///…/read.rb"}, position: {line: 164, character: 14}}
    #
    # == Why there is no +character+ parameter
    #
    # Not because the arithmetic is hard, but because **nothing in the model's
    # input contains a column**: +read+ prints line→text and +grep+ prints
    # +file:line:text+. A column could only be *invented*, and being wrong is not
    # an error — one measured run had +definition+ answering 0 locations from a
    # keyword column, another had +references+ seven columns off returning
    # **80,609** locations instead of 2.
    #
    # == The two ways in, and only one is reliable
    #
    # * +symbol+ + +file+ + +line+ → one line read, one string search, no index and
    #   no server involvement. Works on every server that will ever be wired.
    # * +symbol+ alone → +workspace/symbol+, which fails in opposite directions per
    #   server: ruby-lsp scores the query against the *fully qualified* name with a
    #   0.7 Jaro-Winkler threshold, so a bare +Confirmer+ scores 0.455 and is never
    #   returned, while jdtls indexes no methods at all. Best effort, reported
    #   honestly when it resolves nothing.
    #
    # == The keyword trap, which is why {.locate} runs at both ends
    #
    # A symbol's range routinely begins at the *keyword* — +class Foo+ starts at
    # +class+ — so feeding an index hit's +range.start+ back in is the failure, not
    # the shortcut: +prepareTypeHierarchy+ at the keyword column returned zero
    # items in 6 of 6 cases on ruby-lsp and one item every time at the symbol's own
    # column. jdtls disagrees about the details in both directions and needs the
    # same helper. So the column always comes from the line's *text*.
    #
    # An anchor that resolves outside the root is dropped with its own note: every
    # position-based operation would otherwise need a document outside what the
    # servers index. What is lost is following a hop *into* a dependency, which
    # +hover+ and the +jdt:+ content path still answer.
    class Anchor < Data.define(:client, :path, :position, :line_text)
      # Anchors one call may fire. A name matching 14 declarations must not mean
      # 14 fan-out queries, and a line mentioning the same identifier twice is
      # queried at both columns on purpose (see {.locate}).
      MAX = 5

      # What {.resolve} produces: the anchors, plus what happened to the
      # candidates that did not become one.
      #
      # @!attribute [r] anchors
      #   @return [Array<Anchor>] at least one — {.resolve} raises rather than
      #     answering none.
      # @!attribute [r] notes
      #   @return [Array<String>] lines the tool appends under +Notes:+, e.g. a
      #     match that resolved outside the workspace, or a symbol found by
      #     scanning the file because the index had no entry for it.
      Resolution = Data.define(:anchors, :notes)

      # @return [String] the anchor document's +file:+ URI.
      def uri
        Uris.for_path(path)
      end

      # @return [Hash] the +{textDocument:, position:}+ every position-based
      #   request carries, encoded in *this* server's negotiated
      #   +positionEncoding+.
      def params
        { textDocument: { uri: uri },
          position: position.to_wire(line_text: line_text, encoding: client.position_encoding) }
      end

      # @return [String] +"read.rb:165:15"+ — how a result block is labelled when
      #   one line held the symbol twice and the two columns disagreed.
      def to_s
        "#{File.basename(path)}:#{position}"
      end

      # 1-based columns where +symbol+ occurs in +line_text+.
      #
      #   locate('    names = names.trim()', 'names')   # => [5, 13]
      #
      # Only occurrences bounded by non-identifier characters count, so +greet+
      # does not match inside +greeting+. There is deliberately no
      # any-occurrence fallback: a substring hit would anchor the query on a
      # *different* name and the server would answer confidently about it, which
      # is the one failure mode worth more than an empty answer. Columns are
      # character columns — the encoding conversion happens later, once, in
      # {Position#to_wire}.
      #
      # @param line_text [String]
      # @param symbol [String]
      # @return [Array<Integer>] empty when the symbol is not on the line, which
      #   is a clean error rather than a silently wrong answer.
      def self.locate(line_text, symbol)
        found = []
        offset = 0
        while (index = line_text.index(symbol, offset))
          found << index + 1 if bounded?(line_text, index, symbol.length)
          offset = index + 1
        end
        found
      end

      # @return [Boolean] whether neither neighbour of the match is an identifier
      #   character.
      def self.bounded?(line_text, index, length)
        before = index.zero? ? nil : line_text[index - 1]
        after = line_text[index + length]
        [before, after].none? { |char| char&.match?(/[A-Za-z0-9_]/) }
      end
      private_class_method :bounded?

      # Resolve the anchors for one call.
      #
      # @param servers [Servers] the live clients, for routing and fan-out.
      # @param filesystem [Pikuri::Workspace::Filesystem] path resolution, the
      #   root confinement, and the seam every read routes through.
      # @param symbol [String] the name the model gave.
      # @param file [String, nil] narrows to one server and one document.
      # @param line [Integer, nil] 1-based, as +read+ and +grep+ print it.
      # @param ready [Proc] called with a client before it is asked anything —
      #   the readiness gate, injected so this class needs no progress emitter.
      # @return [Resolution]
      # @raise [Refusal] when no anchor can be produced, with the reason: no
      #   server claims the file, the symbol is not on the named line, or the
      #   index has no entry for the name.
      # @raise [Pikuri::Workspace::Filesystem::Error] when +file+ is outside the
      #   workspace — the seam's own refusal, relayed by the tool.
      def self.resolve(servers:, filesystem:, symbol:, file: nil, line: nil, ready: ->(_client) {})
        return in_file(servers, filesystem, symbol, file, line, ready) if file

        in_index(servers, filesystem, symbol, ready)
      end

      # The reliable route: one named document, and the column derived from its
      # text.
      def self.in_file(servers, filesystem, symbol, file, line, ready)
        resolved = filesystem.resolve_for_read(file)
        raise Refusal, "#{file}: no such file in the workspace" unless resolved.file?
        raise Refusal, out_of_root_message(file) unless in_root?(resolved, filesystem)

        client = servers.client_for(resolved)
        raise Refusal, no_server_message(resolved) if client.nil?

        ready.call(client)
        text = resolved.read
        return on_line(client, resolved.to_s, text, symbol, line) if line

        in_one_file(client, filesystem, resolved, text, symbol)
      end
      private_class_method :in_file

      # Querying every occurrence on the line — both columns of
      # +names = names.trim()+ — and merging is what replaces the +character+
      # parameter: identical answers collapse, genuinely different ones are
      # labelled.
      def self.on_line(client, path, text, symbol, line)
        lines = text.lines
        # +Tool::Parameters+ coerces types and validates enums; it has no range
        # check, so a 0 arrives here and +lines[-1]+ would silently consult the
        # *last* line of the file.
        raise Refusal, "line must be 1-based, got #{line}" if line < 1
        if line > lines.length
          raise Refusal, "#{File.basename(path)} has #{lines.length} lines; line #{line} was asked for"
        end

        line_text = lines[line - 1].chomp
        columns = locate(line_text, symbol)
        if columns.empty?
          raise Refusal, "#{symbol.inspect} is not on line #{line} of #{File.basename(path)}, " \
                         "which reads: #{line_text.strip.inspect}"
        end

        anchors = columns.first(MAX).map do |column|
          new(client: client, path: path, position: Position.new(line: line, column: column),
              line_text: line_text)
        end
        Resolution.new(anchors: anchors, notes: extra_columns_note(columns, symbol, line))
      end
      private_class_method :on_line

      def self.extra_columns_note(columns, symbol, line)
        return [] if columns.length <= MAX

        ["#{symbol.inspect} occurs #{columns.length} times on line #{line}; the first #{MAX} " \
         'columns were queried.']
      end
      private_class_method :extra_columns_note

      # +file+ without +line+. The scan is not a shortcut but the fallback the index
      # route needs: a Java method is not in that index at all, and a short Ruby
      # name scores below the server's own similarity threshold.
      def self.in_one_file(client, filesystem, resolved, text, symbol)
        hits = if client.supports?('workspaceSymbolProvider')
                 index_hits(client, symbol).select { |hit| Uris.to_path(hit[:uri]) == resolved.to_s }
               else
                 []
               end
        return build(filesystem, client, hits.first(MAX), notes: []) unless hits.empty?

        columns = first_occurrence(text, symbol)
        if columns.nil?
          raise Refusal, "#{symbol.inspect} does not occur in #{resolved.basename} and the " \
                         "server's index has no entry for it"
        end

        line, column = columns
        line_text = text.lines[line - 1].chomp
        anchor = new(client: client, path: resolved.to_s,
                     position: Position.new(line: line, column: column), line_text: line_text)
        Resolution.new(anchors: [anchor],
                       notes: ["anchored on line #{line}, the first occurrence of #{symbol.inspect} " \
                               'in the file; the server\'s index has no entry for that name.'])
      end
      private_class_method :in_one_file

      # No file: fan out to every server's index and merge. A name may live in
      # either language, and this is the only route that does not need one.
      def self.in_index(servers, filesystem, symbol, ready)
        notes = []
        hits = servers.active.flat_map do |client|
          unless client.supports?('workspaceSymbolProvider')
            notes << "the #{client.entry.id} server cannot search by name (no workspaceSymbolProvider), " \
                     'so its files were not considered.'
            next []
          end

          ready.call(client)
          index_hits(client, symbol)
        end

        raise Refusal, unresolved_message(symbol, notes) if hits.empty?

        build(filesystem, nil, hits.first(MAX), notes: notes, total: hits.length)
      end
      private_class_method :in_index

      # +workspace/symbol+, exact-name filtered through {SymbolName} — never on
      # +name+ verbatim, which every server spells differently and which would
      # reject every correct hit.
      def self.index_hits(client, symbol)
        rows = client.request('workspace/symbol', { query: symbol })
        Array(rows).filter_map do |row|
          next unless row.is_a?(Hash)
          next unless SymbolName.matches?(row['name'], symbol)

          location = row['location']
          next unless location.is_a?(Hash) && location['uri']

          { uri: location['uri'], range: location['range'], client: client, name: row['name'] }
        end
      end
      private_class_method :index_hits

      # Index hits → anchors, dropping what cannot anchor a query and saying so.
      def self.build(filesystem, client, hits, notes:, total: nil)
        notes = notes.dup
        anchors = hits.filter_map { |hit| from_hit(filesystem, hit[:client] || client, hit, notes) }
        raise Refusal, dropped_message(notes) if anchors.empty?

        # Counts what was *queried*, not what the index returned: a hit that could
        # not anchor anything already has its own note.
        notes << "#{total} index matches; #{anchors.length} were queried." if total && total > anchors.length
        Resolution.new(anchors: anchors, notes: notes)
      end
      private_class_method :build

      def self.from_hit(filesystem, client, hit, notes)
        path = Uris.to_path(hit[:uri])
        if path.nil?
          notes << "#{hit[:name]} is inside a dependency archive and cannot anchor a query."
          return nil
        end

        # Lexical, not "does +resolve_for_read+ raise": an +AllowAll+ filesystem
        # (the container wiring) resolves any path happily, and the boundary that
        # matters here is the server's own +rootUri+ — outside it a server answers
        # about a non-project file, which is a different lie.
        resolved = begin
          filesystem.resolve_for_read(path)
        rescue Pikuri::Workspace::Filesystem::Error
          nil
        end
        if resolved.nil? || !in_root?(resolved, filesystem)
          notes << "#{hit[:name]} is outside the workspace (#{File.basename(path)}) and cannot " \
                   'anchor a query.'
          return nil
        end

        anchor_in(client, resolved, hit, notes)
      end

      # @param resolved [Pathname] an already-resolved absolute path.
      # @param filesystem [Pikuri::Workspace::Filesystem]
      # @return [Boolean] whether it sits under the root the servers index.
      def self.in_root?(resolved, filesystem)
        root = filesystem.project_root.to_s
        path = resolved.to_s
        path == root || path.start_with?("#{root}/")
      end
      private_class_method :in_root?
      private_class_method :from_hit

      def self.anchor_in(client, resolved, hit, notes)
        text = resolved.read
        wanted = SymbolName.last_segment(hit[:name])
        line = wire_line(hit[:range])
        columns = line && text.lines[line - 1] && locate(text.lines[line - 1].chomp, wanted)
        if columns.nil? || columns.empty?
          # Either the reply carried no range at all (newer servers may send a
          # bare {uri}), or the range's line does not contain the name.
          found = first_occurrence(text, wanted)
          if found.nil?
            notes << "#{hit[:name]} is indexed in #{resolved.basename} but the name is not in the file."
            return nil
          end
          line, column = found
        else
          column = columns.first
        end

        new(client: client, path: resolved.to_s, position: Position.new(line: line, column: column),
            line_text: text.lines[line - 1].chomp)
      rescue SystemCallError, IOError => e
        notes << "#{resolved.basename} could not be read (#{e.class})."
        nil
      end
      private_class_method :anchor_in

      # 1-based line a wire range starts on, or +nil+ when the reply carried no
      # usable one — a newer server may answer +workspace/symbol+ with a bare
      # +{uri}+, and a malformed range is the server's bug rather than a reason to
      # fail the call.
      #
      # @param wire [Hash, nil] an LSP +Range+ object.
      # @return [Integer, nil]
      def self.wire_line(wire)
        line = wire.is_a?(Hash) ? wire.dig('start', 'line') : nil
        line.is_a?(Integer) ? line + 1 : nil
      end
      private_class_method :wire_line

      # @return [Array(Integer, Integer), nil] 1-based line and column of the
      #   first occurrence of +symbol+ in +text+.
      def self.first_occurrence(text, symbol)
        text.lines.each_with_index do |line_text, index|
          columns = locate(line_text.chomp, symbol)
          return [index + 1, columns.first] unless columns.empty?
        end
        nil
      end
      private_class_method :first_occurrence

      # The degrade string, naming the extension rather than the servers: which
      # servers are installed is machine state the model cannot act on, and the
      # file type is what the call got wrong.
      #
      # @param path [String, Pathname] the file nothing claimed.
      # @return [String]
      def self.no_server_message(path)
        extension = File.extname(path.to_s)
        subject = extension.empty? ? File.basename(path.to_s) : "#{extension} files"
        "no language server is configured for #{subject}"
      end

      def self.unresolved_message(symbol, notes)
        message = "#{symbol.inspect} is not in any server's index. Pass file: (and line:) to anchor " \
                  'the query on a line you have read — a bare name is matched against fully ' \
                  'qualified names, and some servers index no methods at all'
        notes.empty? ? message : "#{message}. #{notes.join(' ')}"
      end
      private_class_method :unresolved_message

      # The reasons live in +notes+ — one per dropped hit — so the headline stays
      # true whether they were in a jar, outside the root, or indexed under a name
      # the file no longer contains.
      def self.dropped_message(notes)
        "no index match can anchor a query. #{notes.join(' ')}".strip
      end
      private_class_method :dropped_message

      # Out-of-root, and the reason is the *server's* boundary rather than
      # pikuri's: it indexes one root, and outside it answers about a file it does
      # not consider part of the project — which shipped clients report as "no
      # definition found", the false premise this gem exists not to produce.
      def self.out_of_root_message(file)
        "#{file} is outside the workspace root the language servers index"
      end
      private_class_method :out_of_root_message
    end
  end
end
