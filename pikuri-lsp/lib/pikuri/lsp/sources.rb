# frozen_string_literal: true

module Pikuri
  module Lsp
    # Where the bytes behind a result come from, and what a result is *called*.
    # One instance per tool call, so the memo and the fetch budget are per call.
    #
    #   sources = Sources.new(filesystem: filesystem)
    #   sources.label_for(location.uri)
    #   # => "pikuri-workspace/lib/pikuri/workspace/filesystem.rb"
    #   # => "org.slf4j.LoggerFactory (slf4j-api-2.0.18.jar)"
    #   sources.snippet_for(location, client: client)   # => "def resolve_for_read(path)"
    #
    # == Three tiers, keyed on the URI's scheme
    #
    # There is no standard "read this URI" request in the LSP that ships today and
    # no way to discover a server's non-standard one, so this is policy, not a
    # lookup:
    #
    # 1. **+file:+ — the only scheme pikuri reads itself.** In-root results carry
    #    the workspace-relative path, and the read goes through the +Workspace+
    #    seam. Out-of-root results (the 45 gem hits one +goToDefinition+ on a
    #    constant returned) always carry the line of code — "what does this library
    #    method do" is a top reason to want LSP at all — and carry a **path only
    #    when this workspace would read that file**, which is a per-wiring answer:
    #    +AllowAll+ (the +--yolo+ and OS-agent wirings) opens a gem checkout
    #    happily, a root-confined one refuses it, and quoting a path the +read+
    #    tool will reject is a dead-end citation. Every +file:+ URI takes a
    #    {#denied?} pass first — a result is a *walked* path, so nothing else stops
    #    an index hit under +~/.ssh+ from being quoted.
    # 2. **A server-private scheme — standard first, one hardcoded row behind
    #    it.** LSP 3.18's +workspace/textDocumentContent+ is real discovery (the
    #    server lists the +schemes+ it will read) and wins where advertised.
    #    Nothing implements it yet, and a standard-only stance made the Java arm
    #    untestable, so {SCHEME_REQUESTS} carries exactly one row with a written
    #    deletion condition: **delete the +jdt:+ row the day jdtls advertises
    #    +textDocumentContent+**, and the standard path above it takes over with no
    #    other edit. The bar for adding a row is a server someone wired and can
    #    test.
    # 3. **+http(s):+ and any scheme with no row — printed, never dereferenced.**
    #    The load-bearing refusal: fetching a URI the *server* chose is egress with
    #    the payload in the URL, and no network row may ever enter the table. A
    #    scheme with no row still gets the inline reason, never a bare count.
    #
    # One reply of attached Java source measured 22,639 bytes in 10 ms — cheap to
    # fetch, ruinous to inline — so content is sliced to the line the result points
    # at, memoized per URI (a 45-hit answer repeats URIs) and capped at
    # {MAX_FETCHES} documents per call.
    class Sources
      # Documents one tool call may fetch over the wire. A cap rather than a
      # budget because the failure it prevents is one call inlining a jar.
      MAX_FETCHES = 5

      # Characters of a source line a snippet keeps. A row is one line — not the
      # result's whole +range+, which for a reopened namespace is the whole file.
      MAX_SNIPPET_CHARS = 160

      # LSP 3.18's client→server content request: +{uri}+ → +{text}+.
      STANDARD_REQUEST = 'workspace/textDocumentContent'

      # The scheme→request table. One row, and the deletion condition is in the
      # class header. +java/classFileContents+ answers with a **bare String**
      # where the standard request answers +{text:}+; {#fetch_from_server} accepts
      # either, which is the whole reason both paths can share a call site.
      SCHEME_REQUESTS = { 'jdt' => 'java/classFileContents' }.freeze

      # @param filesystem [Pikuri::Workspace::Filesystem] the root confinement,
      #   the +denied?+ pass, and the seam every in-root read routes through.
      def initialize(filesystem:)
        @filesystem = filesystem
        @root = filesystem.project_root.to_s
        @memo = {}
        @readable = {}
        @fetches = 0
      end

      # What to call this URI in a rendered row.
      #
      # @param uri [String] as the server sent it.
      # @return [String] a workspace-relative path in-root; the absolute path for a
      #   file outside the root this workspace would still read, or a bare basename
      #   for one it would refuse; +"org.slf4j.LoggerFactory
      #   (slf4j-api-2.0.18.jar)"+ for a +jdt:+ handle; else the URI itself,
      #   truncated — a real +jdt:+ URI runs to ~300 characters of encoded
      #   classpath and must never be shown raw.
      def label_for(uri)
        path = Uris.to_path(uri)
        return relative(path) if path && in_root?(path)
        return out_of_root_label(path) if path

        scheme = Uris.scheme(uri)
        return jdt_label(uri) if scheme == 'jdt'

        truncate(uri, 200)
      end

      # @param uri [String]
      # @return [Boolean] whether this names a file under the workspace root —
      #   which is what decides whether a row carries a path the model can act
      #   on.
      def in_root_file?(uri)
        path = Uris.to_path(uri)
        !path.nil? && in_root?(path)
      end

      # Whether this workspace would actually open the document behind a +file:+
      # URI — what decides whether a citation may carry a *link*, since a link to
      # a path the +read+ tool refuses is the dead-end citation this class exists
      # to avoid. Includes the {#denied?} pass, so it is safe to ask on its own.
      #
      # @param uri [String]
      # @return [Boolean] +false+ for any non-+file:+ URI: a jar entry is not a
      #   path, so nothing here can open one.
      def actionable?(uri)
        path = Uris.to_path(uri)
        !path.nil? && !@filesystem.denied?(path) && readable?(path)
      end

      # Whether this URI must be dropped rather than rendered.
      #
      # A result is a path the *server* walked to, so it reaches no
      # +resolve_for_read+ and this check is the only thing standing between an
      # index hit under a credential root and the model's context. It fails
      # closed, never raises, and is exact — the file tools run as the real user.
      #
      # @param uri [String]
      # @return [Boolean] +false+ for a non-+file:+ URI, which cannot be
      #   denylist-checked at all: a jar's contents are not a path.
      def denied?(uri)
        path = Uris.to_path(uri)
        !path.nil? && @filesystem.denied?(path)
      end

      # One line of code for a result, or the reason there is none.
      #
      # @param location [Location] what the server pointed at.
      # @param client [ClientWrapper, nil] the server that issued the URI — the
      #   only one that can read its private schemes.
      # @return [String] the source line, stripped and truncated, or a bracketed
      #   reason. Never +nil+: a row with no snippet still has to say why.
      def snippet_for(location, client: nil)
        lines, reason = lines_for(location.uri, client: client)
        return "[#{reason}]" if lines.nil?

        line = lines[location.anchor.start.line - 1]
        return '[the server pointed past the end of this document]' if line.nil?

        truncate(line.strip, MAX_SNIPPET_CHARS)
      end

      # The document behind a URI, memoized for this call.
      #
      # @param uri [String]
      # @param client [ClientWrapper, nil]
      # @return [Array(Array<String>, nil), Array(nil, String)] its lines, or
      #   +nil+ and the reason.
      def lines_for(uri, client: nil)
        @memo[uri] ||= fetch(uri, client)
      end

      private

      def fetch(uri, client)
        path = Uris.to_path(uri)
        return [nil, 'this path is on the workspace denylist'] if path && @filesystem.denied?(path)
        return read_file(path) if path

        scheme = Uris.scheme(uri)
        if %w[http https].include?(scheme)
          # The refusal, and it is the whole no-network claim: the URI was chosen
          # by the server, so fetching it would be egress with the payload in the
          # URL.
          return [nil, 'pikuri-lsp never fetches a remote URI; this one is printed as text only']
        end

        fetch_from_server(uri, scheme, client)
      end

      # In-root reads route through the seam; an out-of-root result is read
      # directly, because +resolve_for_read+ exists to refuse exactly that path
      # and the result is a citation rather than a file the model asked for.
      def read_file(path)
        text = in_root?(path) ? @filesystem.resolve_for_read(path).read : File.read(path)
        [text.lines, nil]
      rescue Pikuri::Workspace::Filesystem::Error, SystemCallError, IOError => e
        [nil, "could not be read (#{e.class}: #{e.message})"]
      end

      def fetch_from_server(uri, scheme, client)
        return [nil, "only the server that issued this #{scheme}: URI can read it"] if client.nil?

        request = content_request(client, scheme)
        if request.nil?
          return [nil, "this server's #{scheme}: URIs need LSP 3.18 content support, " \
                       'which it does not advertise']
        end
        if @fetches >= MAX_FETCHES
          return [nil, "not fetched: one call reads at most #{MAX_FETCHES} documents from a server"]
        end

        @fetches += 1
        parse_content(client.request(request, { uri: uri }), scheme)
      rescue Connection::ServerError, ClientWrapper::ServerDied => e
        # Try-then-degrade: a wrongly-matched scheme, or a server that refuses
        # the request it advertised, costs one round trip and an honest row.
        [nil, "the server would not read this #{scheme}: URI (#{e.message})"]
      end

      # 3.18 answers +{text:}+; +java/classFileContents+ answers a bare String.
      def parse_content(reply, scheme)
        text = reply.is_a?(Hash) ? reply['text'] : reply
        return [nil, "the server answered no text for this #{scheme}: URI"] unless text.is_a?(String)

        [text.lines, nil]
      end

      # Standard first: the server lists the schemes it will read, which is real
      # discovery. Only if it advertises nothing does the one-row table apply —
      # and keying on the scheme is exact rather than a guess, because only the
      # server that issued a +jdt:+ URI can read one.
      def content_request(client, scheme)
        declared = client.capabilities.dig('workspace', 'textDocumentContent')
        schemes = declared.is_a?(Hash) ? declared['schemes'] : nil
        return STANDARD_REQUEST if declared && (schemes.nil? || schemes.include?(scheme))

        SCHEME_REQUESTS[scheme]
      end

      def in_root?(path)
        path == @root || path.start_with?("#{@root}/")
      end

      # Outside the root the label is the *actionable* form: the path where this
      # workspace would open the file, its basename where it would not. Suppressing
      # a readable path would delete a capability the wiring granted; printing an
      # unreadable one invites a refused read.
      def out_of_root_label(path)
        readable?(path) ? path : "outside the workspace: #{File.basename(path)}"
      end

      def readable?(path)
        @readable.fetch(path) do
          @readable[path] = begin
            @filesystem.resolve_for_read(path)
            true
          rescue Pikuri::Workspace::Filesystem::Error
            false
          end
        end
      end

      def relative(path)
        path == @root ? File.basename(path) : path[(@root.length + 1)..]
      end

      # +jdt://contents/<jar>/<package>/<Type>.class?=<the whole classpath entry>+
      # → +"<package>.<Type> (<jar>)"+, which is the only readable thing in it.
      def jdt_label(uri)
        segments = uri.split('?').first.to_s.split('/')
        index = segments.index('contents')
        return truncate(uri, 120) if index.nil? || segments.length < index + 4

        jar, package, file = segments[(index + 1)..(index + 3)]
        "#{package}.#{File.basename(file, '.*')} (#{jar})"
      end

      def truncate(text, limit)
        text.length > limit ? "#{text[0, limit - 4]} ..." : text
      end
    end
  end
end
