# frozen_string_literal: true

module Pikuri
  module Lsp
    # One +lsp+ call, end to end: route to a server, wait for its index, re-open
    # the document, ask, render. {LspTool} holds the schema and the legs; this holds
    # the behaviour, so a spec can drive it with no tool in sight.
    #
    #   navigator = Navigator.new(servers: servers, filesystem: filesystem,
    #                             on_progress: ->(progress) { ctx.emit_event(progress) })
    #   navigator.navigate(operation: 'goToDefinition', symbol: 'resolve_for_read',
    #                      file: 'read.rb', line: 165)
    #
    # == The order of the five steps is the design
    #
    # 1. **Route on the file**, or fan out when there is none — the model names no
    #    server, and a registry keyed by language would fail in exactly the
    #    mixed-language repo that makes a registry worth having.
    # 2. **Gate on what that server advertised**, per workspace and at dispatch.
    #    Extension routing without this is how a shipped client leaks
    #    +Method not found: textDocument/implementation+ at the model.
    # 3. **Wait for the index** — the one place waiting beats relaying, because a
    #    mid-index server answers +[]+ with a success code and there is nothing in
    #    +[]+ to reason about. No timeout: a cold Java import measured 78 seconds,
    #    no number separates that from a hang, and progress events plus
    #    +cancellable+ make the human the timeout.
    # 4. **Re-open the document** ({ClientWrapper#open_document}), and hand it
    #    back once every reply is in ({#release_documents}) — the pair is per
    #    *call*, because one call can ask several questions about one document.
    # 5. **Ask and render**, running the +prepare+ hop and the per-level walk here
    #    so the model issues one call and never holds an opaque protocol item.
    #
    # == Errors are relayed, never worked around
    #
    # Every server is broken in its own way and the ways do not generalize — one
    # advertises a type hierarchy whose downward half is a +# TODO+, another indexes
    # no methods, a third crashes on a notification the spec allows. So there is no
    # per-server workaround and no known-stub list here: what the server said and
    # what it was asked go back, and the model decides. That includes a reply pikuri
    # cannot parse ({#relaying}) — the server's bug, and dying on it would be the
    # one failure mode this stance exists to prevent.
    class Navigator
      # Items a +prepare+ hop may produce before the rest are dropped with a note.
      # +prepare+ can legitimately answer several — Java overloads, one name
      # declared in several classes — and the model has no more idea which is meant
      # than this does, so each is queried and the results are labelled.
      MAX_PREPARED = 3

      # @param servers [Servers] the live clients.
      # @param filesystem [Pikuri::Workspace::Filesystem] path resolution, root
      #   confinement, the denylist pass and the seam every read routes through.
      # @param on_progress [Proc, nil] called with a {ServerProgress} while a wait
      #   blocks — on *this* thread, which is what makes it safe to emit as an
      #   agent event.
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] polled by
      #   every wait and every request.
      def initialize(servers:, filesystem:, on_progress: nil, cancellable: nil)
        @servers = servers
        @filesystem = filesystem
        @on_progress = on_progress || ->(_progress) {}
        @cancellable = cancellable
        @ready = []
        @texts = {}
        @opened = []
      end

      # Answer one call.
      #
      # @param operation [String] an {Operation} name; +Tool::Parameters+ has
      #   already refused anything outside the enum.
      # @param symbol [String] the name to ask about.
      # @param file [String, nil] workspace-relative or absolute; the server
      #   selector, and the document an anchor is located in.
      # @param line [Integer, nil] 1-based, as +read+ and +grep+ print it.
      # @return [String] the observation, including +"Error: …"+ for everything
      #   the model can react to.
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] on cancellation —
      #   deliberately *not* an observation.
      def navigate(operation:, symbol:, file: nil, line: nil)
        op = Operation[operation]
        raise ArgumentError, "unknown lsp operation #{operation.inspect}" if op.nil?

        renderer = Renderer.new(sources: Sources.new(filesystem: @filesystem))
        @ready = []
        @texts = {}
        @opened = []
        raise Refusal, 'no language server is configured' if @servers.empty?

        dispatch(op, symbol, file, line, renderer)
      rescue Refusal, Pikuri::Workspace::Filesystem::Error, ClientWrapper::ServerDied => e
        Pikuri::Tool::Result.error("#{e.message}")
      rescue Connection::ServerError => e
        Pikuri::Tool::Result.error("the language server refused #{operation}: #{e.message}")
      ensure
        release_documents
      end

      private

      def dispatch(operation, symbol, file, line, renderer)
        case operation.anchor
        when :query then fan_out(operation, symbol, renderer)
        when :document then outline(operation, symbol, file, renderer)
        else positional(operation, symbol, file, line, renderer)
        end
      end

      # +workspaceSymbol+ takes no position at all, so every server that can search
      # is asked. Fanning out starts each of them and costs the *first* call their
      # remaining index time — the accepted price of a question that names no file,
      # and why {Servers#active} narrows the set to servers the project has files
      # for.
      def fan_out(operation, symbol, renderer)
        clients = @servers.active
        raise Refusal, no_relevant_server_message if clients.empty?

        usable, refusing = clients.partition { |client| client.supports?(operation.capability) }
        raise Refusal, unsupported_message(operation, clients) if usable.empty?

        refusing.each { |client| renderer.note(cannot_answer(operation, client)) }
        blocks = usable.map do |client|
          ensure_ready(client)
          rows = client.request(operation.request, { query: symbol }, cancellable: @cancellable)
          block = relaying(operation, client) do
            renderer.symbols(Array(rows), operation: operation, symbol: symbol, client: client)
          end
          usable.length > 1 ? "From the #{client.entry.id} server:\n#{block}" : block
        end
        renderer.finish(blocks.join("\n\n"))
      end

      # +documentSymbol+: the only file-keyed operation, and the one route from a
      # method *name* to a position where a server's project-wide index holds
      # types only.
      def outline(operation, symbol, file, renderer)
        raise Refusal, "#{operation.name} outlines one file, so it needs file:" if file.nil?

        resolved = readable(file)
        client = @servers.client_for(resolved)
        raise Refusal, Anchor.no_server_message(resolved) if client.nil?
        raise Refusal, unsupported_message(operation, [client]) unless client.supports?(operation.capability)

        ensure_ready(client)
        uri = open_document(client, resolved)
        rows = client.request(operation.request, { textDocument: { uri: uri } }, cancellable: @cancellable)
        renderer.finish(relaying(operation, client) do
          renderer.symbols(Array(rows), operation: operation, symbol: symbol, client: client, uri: uri)
        end)
      end

      # Everything with a cursor. The capability check is per *anchor*, not per
      # call: a bare name fans out, so two anchors can sit on two servers with
      # different capability sets.
      def positional(operation, symbol, file, line, renderer)
        resolution = Anchor.resolve(servers: @servers, filesystem: @filesystem, symbol: symbol,
                                    file: file, line: line, ready: method(:ensure_ready))
        resolution.notes.each { |note| renderer.note(note) }
        anchors = resolution.anchors.select { |anchor| anchor.client.supports?(operation.capability) }
        if anchors.empty?
          raise Refusal, unsupported_message(operation, resolution.anchors.map(&:client).uniq)
        end

        answers = anchors.map { |anchor| [anchor, answer(operation, anchor, symbol, renderer)] }
        renderer.finish(merge(answers))
      end

      # One anchor, one answer. Identical answers from several anchors collapse in
      # {#merge}; different ones are labelled by column, which is what replaces the
      # +character+ parameter for +names = names.trim()+.
      def answer(operation, anchor, symbol, renderer)
        client = anchor.client
        ensure_ready(client)
        open_document(client, Pathname.new(anchor.path))

        relaying(operation, client) do
          case operation.shape
          when :hover
            renderer.hover(request(client, operation.request, anchor.params),
                           operation: operation, symbol: symbol)
          when :calls
            renderer.calls(hierarchy(operation, anchor, symbol, renderer),
                           operation: operation, symbol: symbol, client: client)
          when :supertypes
            renderer.supertypes(ancestry(operation, anchor, symbol, renderer),
                                operation: operation, symbol: symbol)
          else
            result = request(client, operation.request, location_params(operation, anchor))
            renderer.locations(Location.list_from_wire(result, encoding: client.position_encoding),
                               operation: operation, symbol: symbol, client: client)
          end
        end
      end

      # A reply whose *shape* pikuri cannot read is the server's bug, not
      # pikuri's, so it is relayed like everything else the server said. Without
      # this the wire types raise +KeyError+ for a location missing its +range+ and
      # +ArgumentError+ for a +definition+ that answered a bare String, and the
      # turn dies on a message nobody sees — which is the one thing the relay
      # stance is supposed to prevent.
      def relaying(operation, client)
        yield
      rescue KeyError, TypeError, ArgumentError => e
        raise Refusal, "the #{client.entry.id} server's #{operation.name} reply could not be " \
                       "read (#{e.class}: #{e.message})"
      end

      # The declaration is a reference too — a caller asking "who uses this" wants
      # it in the list, and every shipped harness includes it.
      def location_params(operation, anchor)
        params = anchor.params
        params = params.merge(context: { includeDeclaration: true }) if operation.name == 'findReferences'
        params
      end

      # The +prepare+ hop, collapsed. LSP makes both hierarchies a two-step chain
      # and both harnesses that ship the call family hand the model the
      # intermediate item to echo back; running it here costs one round trip the
      # model never sees.
      def prepared(operation, anchor, symbol, renderer)
        items = Array(request(anchor.client, operation.prepare, anchor.params))
        exact = items.select { |item| SymbolName.matches?(item['name'], symbol) }
        chosen = exact.empty? ? items : exact
        if exact.empty? && !items.empty?
          renderer.note("nothing the server prepared here is named #{symbol.inspect}; it offered " \
                        "#{items.map { |item| item['name'] }.uniq.join(', ')}.")
        end
        if chosen.length > MAX_PREPARED
          renderer.note("#{chosen.length} declarations were prepared for #{symbol.inspect}; the " \
                        "first #{MAX_PREPARED} were queried.")
        end
        chosen.first(MAX_PREPARED)
      end

      def hierarchy(operation, anchor, symbol, renderer)
        prepared(operation, anchor, symbol, renderer).flat_map do |item|
          Array(request(anchor.client, operation.request, { item: item }))
        end
      end

      # The ancestor *chain*, walked level by level — which is the whole value of
      # the operation, since a definition hop on the name after +extends+ answers
      # one level and the chain costs one round trip per level.
      #
      # Each level is deduplicated by name before the next query, or a Ruby
      # namespace reopened in 14 files would fan out into 14 queries for the level
      # above it.
      def ancestry(operation, anchor, symbol, renderer)
        current = prepared(operation, anchor, symbol, renderer)
        levels = []
        operation.cap.times do
          parents = current.flat_map { |item| Array(request(anchor.client, operation.request, { item: item })) }
          break if parents.empty?

          levels << parents
          current = parents.group_by { |item| item['name'].to_s }.values.map(&:last).first(2)
        end
        if levels.length == operation.cap
          renderer.note("the chain was walked #{operation.cap} levels deep and did not end there.")
        end
        levels
      end

      def request(client, method, params)
        client.request(method, params, cancellable: @cancellable)
      end

      # Identical bodies collapse — the overwhelmingly common case, since a
      # repeated identifier on one line usually denotes the same entity.
      def merge(answers)
        grouped = answers.group_by(&:last)
        return grouped.keys.first if grouped.length == 1

        grouped.map do |text, pairs|
          "At #{pairs.map { |anchor, _| anchor.to_s }.join(', ')}:\n#{text}"
        end.join("\n\n")
      end

      # Blocks until the index is built, emitting progress on this thread. Memoized
      # per call, so a fan-out over three anchors on one server costs one wait.
      def ensure_ready(client)
        return if @ready.include?(client.entry.id)

        client.wait_until_ready(cancellable: @cancellable) { |progress| @on_progress.call(progress) }
        @ready << client.entry.id
      rescue ClientWrapper::ServerDied => e
        raise Refusal, "the #{client.entry.id} server died while its index was building: #{e.message}"
      end

      # The re-open, once per document per call, with the text on disk *now*.
      def open_document(client, resolved)
        uri = Uris.for_path(resolved)
        unless @texts.key?(resolved.to_s)
          client.open_document(resolved.to_s, text_of(resolved))
          @opened << [client, resolved.to_s]
        end
        uri
      end

      # Give back every document this call opened, once every reply is in.
      #
      # Per *call*, not per request: +supertypes+ and the call-hierarchy operations
      # ask several questions about one document, and a close after the first would
      # drop it under the rest.
      def release_documents
        opened = @opened
        @opened = []
        opened.each { |client, path| client.close_document(path) }
      end

      # Through the seam, always: the text a +didOpen+ carries is a read of a
      # workspace file like any other.
      def text_of(resolved)
        @texts[resolved.to_s] ||= @filesystem.resolve_for_read(resolved).read
      end

      def readable(file)
        resolved = @filesystem.resolve_for_read(file)
        raise Refusal, "#{file}: no such file in the workspace" unless resolved.file?

        resolved
      end

      def unsupported_message(operation, clients)
        ids = clients.map { |client| client.entry.id }
        "the #{ids.join(' and ')} server does not support #{operation.name} in this workspace — " \
          "it advertises no #{operation.capability}"
      end

      def cannot_answer(operation, client)
        "the #{client.entry.id} server does not support #{operation.name}, so its files were not searched."
      end

      def no_relevant_server_message
        ids = @servers.registry.entries.map(&:id)
        "no configured language server has files in this project (configured: #{ids.join(', ')}) — " \
          'name a file to ask a specific one'
      end
    end
  end
end
