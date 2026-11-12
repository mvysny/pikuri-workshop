# frozen_string_literal: true

module Pikuri
  module Lsp
    # Turns a server's reply into the observation the model reads: one row per
    # result, a path it can act on where there is one, a line of code where there is
    # one, and a cap on all of it. One instance per tool call, because the notes it
    # collects belong to that call.
    #
    #   renderer = Renderer.new(sources: Sources.new(filesystem: filesystem))
    #   renderer.note('2 matches are outside the workspace.')
    #   renderer.finish(renderer.locations(hits, operation: operation, symbol: 'read', client: client))
    #
    # == Why this caps and groups when no shipped harness does
    #
    # Because the volumes were measured and they have no ceiling: **80,609**
    # locations from one +findReferences+; 40 references to one Ruby method that
    # were 4 call sites, 2 declarations and **34 spec hits**; 45 +goToDefinition+
    # locations for a constant, one per file reopening the namespace; 14
    # +supertypes+ rows all named +Pikuri::Tool+ with the real declaration ordered
    # *last*. A naive cap would cut the one row that mattered, which is why
    # {#supertypes} groups instead of trimming.
    #
    # == Three answers, three sentences
    #
    # *The server does not support this* is a {Refusal}, *the server answered
    # nothing* is {#nothing}, *the server could not be asked* is a death report.
    # Merging them into "No definition found. This may occur if…" is what teaches a
    # model that a symbol has no definition when the index was merely still
    # building. Everything else the server said is passed through as it came,
    # glitches included: pikuri cannot pre-empt thirty servers' failure modes, and
    # a capable model handles "that looks stale, let me ask another way" routinely.
    #
    # == The one edit made to a server's prose
    #
    # Hover answers prose rather than rows, so its paths reach none of the
    # {Sources} passes every other result goes through — a +**Definitions**+ link
    # into a denied root prints exactly what the walked-path denylist exists to
    # stop. Each +file:+ URI is rewritten to the citation the other nine
    # operations print, keeping its markdown link only where +resolve_for_read+
    # would open the file:
    #
    #   in:  [version.rb](file:///home/m/proj/lib/version.rb#L9,3-9,20)
    #   out: [version.rb](lib/version.rb:9)            — a path +read+ opens
    #        outside the workspace: version.rb         — a read here is refused
    #        [a path this workspace will not read]     — denied
    #
    # That is a denylist obligation, not a style preference: the
    # passed-through-as-it-came rule above is about not pre-empting a server's
    # *failure modes*, and holds for every byte that is not a +file:+ URI.
    class Renderer
      # Bytes one observation may reach before it is head-truncated with a
      # marker. Half of what a grep answer is allowed, because these rows carry
      # both a path and a line of code.
      MAX_BYTES = 24 * 1024

      # Rows from test files shown in a grouped answer. The 34 spec hits are real
      # information — that a method is well covered — but the 4 source call sites
      # are what was asked for, so the tests group states its size and shows a
      # handful.
      MAX_TEST_ROWS = 5

      # Bytes of hover text kept. Hover on a constant returns the whole class
      # comment, which in this codebase is the declared source of truth and is
      # therefore worth having — up to a point that is not "45 documentation links
      # ahead of the docstring".
      MAX_HOVER_BYTES = 3 * 1024

      # A +file:+ URI as it appears inside hover prose, bounded by whitespace and
      # by the delimiters markdown puts around a URI. That such a bound exists is
      # why the scan is +file:+-only: a +jdt:+ URI carries a whole classpath entry
      # in its query and has no reliable end inside a sentence.
      FILE_URI = %r{file://[^\s)\]<>"']+}

      # The markdown link ruby-lsp builds its +**Definitions**+ line from.
      LINKED_FILE_URI = /\[([^\]\n]*)\]\((#{FILE_URI})\)/

      # What a citation this workspace will not read collapses to. A denied result
      # is dropped outright in a row; hover is prose, so something has to stand
      # where the path was.
      DENIED_CITATION = '[a path this workspace will not read]'

      # LSP's +SymbolKind+, so a row says +class+ rather than +5+.
      SYMBOL_KINDS = {
        1 => 'file', 2 => 'module', 3 => 'namespace', 4 => 'package', 5 => 'class',
        6 => 'method', 7 => 'property', 8 => 'field', 9 => 'constructor', 10 => 'enum',
        11 => 'interface', 12 => 'function', 13 => 'variable', 14 => 'constant',
        15 => 'string', 16 => 'number', 17 => 'boolean', 18 => 'array', 19 => 'object',
        20 => 'key', 21 => 'null', 22 => 'enum member', 23 => 'struct', 24 => 'event',
        25 => 'operator', 26 => 'type parameter'
      }.freeze

      # Directory names that make a file a test file, plus the filename suffixes
      # Ruby and Java conventions use — a +lib/spec_helper.rb+ is source and a
      # +spec/foo_spec.rb+ is not.
      TEST_DIRS = %w[spec test tests features].freeze

      # @param sources [Sources] URI identity, the denylist pass and snippet text,
      #   memoized per call.
      def initialize(sources:)
        @sources = sources
        @notes = []
        @counted = {}
      end

      # Record something the model should know about *how* the answer was reached
      # — a match dropped for being outside the workspace, a server that could not
      # be asked, an anchor found by scanning rather than by the index.
      #
      # @param message [String] one sentence, already phrased for the model.
      # @return [void]
      def note(message)
        @notes << message
        nil
      end

      # Location-shaped answers: definition, references, implementation,
      # typeDefinition.
      #
      # Deduplicated on the rendered row rather than on the +Location+: pikuri
      # prints no column, so two results differing only in column are one row —
      # and each copy would spend a slot of the cap {#body} hands out.
      #
      # @param list [Array<Location>] parsed results, in the server's order.
      # @param operation [Operation]
      # @param symbol [String] what was asked about, for the header.
      # @param client [ClientWrapper] the server that answered — the only one that
      #   can read its own private URI schemes.
      # @return [String] the body, without the notes footer.
      def locations(list, operation:, symbol:, client:)
        rows = list.reject { |location| @sources.denied?(location.uri) }
                   .map { |location| location_row(location, client) }
                   .uniq
        return nothing(operation: operation, symbol: symbol) if rows.empty?

        compose(operation, symbol, rows, 'result')
      end

      # @param reply [Hash, nil] the +textDocument/hover+ result.
      # @param operation [Operation]
      # @param symbol [String]
      # @return [String]
      def hover(reply, operation:, symbol:)
        text = hover_text(reply.is_a?(Hash) ? reply['contents'] : reply).strip
        return nothing(operation: operation, symbol: symbol) if text.empty?

        # Before the truncation, so {MAX_HOVER_BYTES} is spent on documentation
        # rather than on absolute paths.
        text = rewrite_file_uris(text)

        kept, marker = Pikuri::Workspace::Search::Utils.head_truncate(
          text, max_bytes: MAX_HOVER_BYTES, hint: 'the rest is documentation the server holds'
        )
        ["hover #{symbol.inspect}", '', kept + marker].join("\n")
      end

      # Symbol-shaped answers: +documentSymbol+ (one file's outline) and
      # +workspaceSymbol+ (the whole index). Rows whose name matches +symbol+
      # exactly win outright; when none does, the full list follows under a note,
      # because a fuzzy index answer is still the fastest way to see what *is*
      # there.
      #
      # @param rows [Array<Hash>] +SymbolInformation+ or +DocumentSymbol+ objects;
      #   both shapes are accepted because a server may send either.
      # @param operation [Operation]
      # @param symbol [String]
      # @param client [ClientWrapper]
      # @param uri [String, nil] the document the outline came from, for the rows
      #   that carry no URI of their own (+DocumentSymbol+ does not).
      # @return [String]
      def symbols(rows, operation:, symbol:, client:, uri: nil)
        flat = flatten_symbols(rows, uri).reject { |row| @sources.denied?(row[:uri].to_s) }
        return nothing(operation: operation, symbol: symbol) if flat.empty?

        exact = flat.select { |row| SymbolName.matches?(row[:name], symbol) }
        note_filtered(operation, symbol, flat.length, exact.length)
        matched = exact.empty? ? flat : exact
        compose(operation, symbol, matched.map { |row| symbol_row(row, client) }, 'symbol')
      end

      # Call-hierarchy answers, both directions.
      #
      # @param rows [Array<Hash>] +CallHierarchyIncomingCall+ (+from+) or
      #   +CallHierarchyOutgoingCall+ (+to+).
      # @param operation [Operation]
      # @param symbol [String]
      # @param client [ClientWrapper]
      # @return [String]
      def calls(rows, operation:, symbol:, client:)
        items = Array(rows).filter_map { |row| row.is_a?(Hash) ? row['from'] || row['to'] : nil }
                           .reject { |item| @sources.denied?(item['uri'].to_s) }
        return nothing(operation: operation, symbol: symbol) if items.empty?

        noun = operation.name == 'incomingCalls' ? 'caller' : 'callee'
        compose(operation, symbol, items.map { |item| item_row(item) }, noun)
      end

      # The ancestor chain, one line per level.
      #
      # Grouped by name rather than capped, because the noise here is a *Ruby
      # namespace reopening*: 14 rows for one class, every one named
      # +Pikuri::Tool+, one per file that reopens the namespace as a wrapper — and
      # the real declaration was last in the list, so a cap would cut precisely the
      # row a reader wants.
      #
      # @param levels [Array<Array<Hash>>] +TypeHierarchyItem+ lists, nearest
      #   ancestor first.
      # @param operation [Operation]
      # @param symbol [String]
      # @return [String]
      def supertypes(levels, operation:, symbol:)
        shown = 0
        lines = levels.filter_map do |items|
          kept = Array(items).reject { |item| @sources.denied?(item['uri'].to_s) }
          next if kept.empty?

          shown += 1
          "  #{shown}. #{level_row(kept)}"
        end
        return nothing(operation: operation, symbol: symbol) if lines.empty?

        counting([header(operation, symbol, lines.length, 'level'), '', *lines].join("\n"),
                 lines.length, 'level')
      end

      # The *server answered nothing* string, which is not the same claim as "this
      # symbol has none" and must not be written as though it were.
      #
      # @param operation [Operation]
      # @param symbol [String]
      # @return [String]
      def nothing(operation:, symbol:)
        counting("The server answered no results for #{operation.name} on #{symbol.inspect}. " \
                 'That is what it said, not proof that none exist.', 0, 'result')
      end

      # Append the notes footer and cap the whole thing.
      #
      # @param text [String] a body from one of the methods above.
      # @return [Pikuri::Tool::Result] the observation, carrying the display line
      #   the shapers tallied (+"3 results"+; the answer's size for +hover+,
      #   which has no rows to count).
      def finish(text)
        # The notes are appended *after* the cut, not truncated with the body: they
        # are what says a match was dropped or a server could not answer, and a
        # long answer is exactly when that must not be the first thing to go.
        kept, marker = Pikuri::Workspace::Search::Utils.head_truncate(
          text, max_bytes: MAX_BYTES, hint: 'narrow the query with file: and line:'
        )
        Pikuri::Tool::Result.new(content: [kept + marker, *footer].join("\n"),
                                 summary: summary_for(text))
      end

      private

      # Remember what a rendered block counted, keyed by the block itself.
      #
      # Keyed rather than summed because the caller may render more blocks than
      # it keeps: two anchors on one line produce two answers, and identical
      # ones collapse into a single block, which must count once. A fan-out
      # across two servers keeps both, and sums.
      #
      # @param block [String] the composed block, as returned to the caller
      # @param number [Integer] rows in it
      # @param noun [String] what was counted, as the header words it
      # @return [String] +block+, so a shaper can return it in place
      def counting(block, number, noun)
        @counted[block] = [number, noun]
        block
      end

      # @param text [String] the assembled answer, *before* truncation — so
      #   nothing the cap removed changes the count.
      # @return [String] the counts of the blocks this answer kept, or the size
      #   for an answer with no rows in it (+hover+)
      def summary_for(text)
        kept = @counted.select { |block, _| text.include?(block) }.values
        return "Returned #{Pikuri::Tool.format_bytes(text.bytesize)}" if kept.empty?

        totals = kept.each_with_object(Hash.new(0)) { |(number, noun), acc| acc[noun] += number }
        totals.map { |noun, number| Pikuri::Tool.pluralize(number, noun) }.join(', ')
      end

      # A row is a path (for the source/tests split) plus the line to print.
      Row = Data.define(:path, :text)
      private_constant :Row

      # What the exact-name filter dropped, said in the terms of the operation
      # that produced the rows: an outline holds a file's other symbols, an index
      # search holds the server's own fuzzy near-misses.
      def note_filtered(operation, symbol, total, exact)
        return note("no symbol is named #{symbol.inspect} here; the full list follows.") if exact.zero?
        return if total == exact

        dropped = total - exact
        if operation.name == 'documentSymbol'
          note("#{dropped} other #{dropped == 1 ? 'symbol' : 'symbols'} in this file " \
               "#{dropped == 1 ? 'is' : 'are'} not shown.")
        else
          note("#{dropped} further near-#{dropped == 1 ? 'match' : 'matches'} the server's fuzzy " \
               "search returned #{dropped == 1 ? 'is' : 'are'} not shown.")
        end
      end

      def compose(operation, symbol, rows, noun)
        counting([header(operation, symbol, rows.length, noun), '', *body(rows, operation)].join("\n"),
                 rows.length, noun)
      end

      def header(operation, symbol, count, noun)
        "#{operation.name} #{symbol.inspect} — #{count} #{noun}#{'s' if count != 1}"
      end

      def footer
        return [] if @notes.empty?

        ['', 'Notes:', *@notes.uniq.map { |note| "- #{note}" }]
      end

      # One flat list, or the source/tests split for the two operations whose
      # volume is dominated by test files.
      def body(rows, operation)
        return capped(rows, operation.cap) unless operation.grouped?

        source, tests = rows.partition { |row| !test?(row.path) }
        [*group('In source', source, operation.cap), *group('In tests', tests, MAX_TEST_ROWS)]
      end

      def capped(rows, cap)
        shown = rows.first(cap).map(&:text)
        return shown if rows.length == shown.length

        shown + ["  ... #{rows.length - shown.length} more, not shown"]
      end

      def group(title, rows, cap)
        return [] if rows.empty?

        shown = rows.first(cap)
        count = rows.length == shown.length ? rows.length.to_s : "#{rows.length}, showing #{shown.length}"
        ["#{title} (#{count}):", *shown.map(&:text), '']
      end

      def test?(path)
        return false if path.nil?

        segments = path.split('/')
        segments[0..-2].any? { |segment| TEST_DIRS.include?(segment) } ||
          segments.last.match?(/(?:_spec|_test|Test|Tests)\.[A-Za-z0-9]+\z/)
      end

      def location_row(location, client)
        make_row(location.uri, location.anchor.start.line,
                 @sources.snippet_for(location, client: client))
      end

      def symbol_row(symbol_row, client)
        location = Location.new(uri: symbol_row[:uri], range: symbol_row[:range])
        kind = SYMBOL_KINDS[symbol_row[:kind]] || 'symbol'
        container = symbol_row[:container].to_s.empty? ? '' : " in #{symbol_row[:container]}"
        make_row(symbol_row[:uri], symbol_row[:range].start.line,
                 "#{kind} #{symbol_row[:name]}#{container}  " \
                 "#{@sources.snippet_for(location, client: client)}")
      end

      # A +CallHierarchyItem+ and a +TypeHierarchyItem+ carry the same four fields,
      # which is why one row shape serves the call pair and the hierarchy.
      def item_row(item)
        detail = item['detail'].to_s.empty? ? '' : " (#{item['detail']})"
        kind = SYMBOL_KINDS[item['kind']] || 'symbol'
        make_row(item['uri'].to_s, item_line(item), "#{kind} #{item['name']}#{detail}")
      end

      def make_row(uri, line, text)
        path = @sources.in_root_file?(uri) ? @sources.label_for(uri) : nil
        Row.new(path: path, text: "  #{@sources.label_for(uri)}:#{line}  #{text}")
      end

      # One ancestry level, collapsed. Rows in a level that share a name are the
      # same ancestor seen through a different file, so the group states how many
      # files and shows the one most likely to be the declaration.
      def level_row(items)
        groups = items.group_by { |item| item['name'].to_s }
        name, rows = groups.max_by { |_name, group| group.length }
        best = declaration_of(name, rows)
        reopened = rows.length > 1 ? "  (+#{rows.length - 1} more files declare this name)" : ''
        others = groups.length > 1 ? "  (and #{groups.length - 1} other ancestors at this level)" : ''
        "#{name}  #{@sources.label_for(best['uri'].to_s)}:#{item_line(best)}#{reopened}#{others}"
      end

      # The file whose basename matches the name's last segment is the declaration;
      # failing that the *last* row, which is where the real one was measured to
      # sit among a namespace's reopenings.
      def declaration_of(name, rows)
        wanted = SymbolName.last_segment(name)
        candidates = ["#{snake(wanted)}.rb", "#{wanted}.java", "#{wanted}.rbs"]
        rows.find { |item| candidates.include?(File.basename(Uris.to_path(item['uri'].to_s).to_s)) } ||
          rows.last
      end

      # A row whose range is missing or malformed still names a symbol worth
      # showing, so it points at line 1 rather than failing the answer.
      def item_line(item)
        wire = item['selectionRange'] || item['range']
        line = wire.is_a?(Hash) ? wire.dig('start', 'line') : nil
        line.is_a?(Integer) ? line + 1 : 1
      end

      def snake(name)
        name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      # +SymbolInformation+ carries a +location+; +DocumentSymbol+ carries a
      # +range+ plus +children+ and belongs to the document that was asked for.
      def flatten_symbols(rows, uri, container = nil)
        Array(rows).flat_map do |row|
          next [] unless row.is_a?(Hash)

          location = row['location']
          if location.is_a?(Hash)
            [{ uri: location['uri'], range: parse_range(location['range']), name: row['name'],
               kind: row['kind'], container: row['containerName'] }].reject { |built| built[:range].nil? }
          else
            [{ uri: uri, range: parse_range(row['selectionRange'] || row['range']), name: row['name'],
               kind: row['kind'], container: container },
             *flatten_symbols(row['children'], uri, row['name'])].reject { |built| built[:range].nil? }
          end
        end
      end

      # A hit with no range at all is a row nothing can point at, so it is dropped
      # rather than rendered at line 1.
      def parse_range(wire)
        wire.is_a?(Hash) ? Range.from_wire(wire) : nil
      rescue KeyError, TypeError
        nil
      end

      # +MarkupContent+, a bare String, a +MarkedString+, or an array of any of
      # those — servers use all four shapes for the same field.
      def hover_text(contents)
        case contents
        when String then contents
        when Array then contents.map { |part| hover_text(part) }.join("\n\n")
        when Hash then contents['value'].to_s
        else ''
        end
      end

      # Links first, so the bare pass only ever sees a URI that arrived naked.
      def rewrite_file_uris(text)
        text.gsub(LINKED_FILE_URI) { linked_citation(Regexp.last_match(1), Regexp.last_match(2)) }
            .gsub(FILE_URI) { bare_citation(Regexp.last_match(0)) }
      end

      def linked_citation(text, uri)
        label, linkable = citation(uri)
        linkable ? "[#{text}](#{label})" : label
      end

      # A URI the server wrote into a sentence rather than a link, so it may carry
      # the sentence's punctuation — which is not part of the path.
      def bare_citation(uri)
        trailing = uri[/[.,;:]+\z/].to_s
        citation(uri.delete_suffix(trailing)).first + trailing
      end

      # Never invent a link that was not there, and never keep one whose target
      # +read+ would refuse — a citation the model cannot act on is the dead end
      # {Sources} exists to avoid.
      #
      # @param uri [String] a +file:+ URI, fragment and all.
      # @return [Array(String, Boolean)] what to print, and whether it may be a
      #   link target.
      def citation(uri)
        path_uri, _, fragment = uri.partition('#')
        return [DENIED_CITATION, false] if @sources.denied?(path_uri)

        label = @sources.label_for(path_uri)
        return [label, false] unless @sources.actionable?(path_uri)

        line = fragment[/\AL?(\d+)/, 1]
        [line ? "#{label}:#{line}" : label, true]
      end
    end
  end
end
