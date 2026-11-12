# frozen_string_literal: true

module Pikuri
  module Lsp
    # A place a server pointed at, parsed from *either* wire shape a
    # navigation request can answer with. Servers pick between +Location+
    # (+uri+/+range+) and +LocationLink+
    # (+targetUri+/+targetRange+/+targetSelectionRange+) based on the
    # +linkSupport+ the client declared, and ruby-lsp picks the second — so
    # both go in one door and nothing downstream learns there were two:
    #
    #   locations = Location.list_from_wire(connection.request('textDocument/definition', params))
    #   locations.map { |loc| "#{loc.path}:#{loc.anchor.start.line}" }
    #   # => ["/home/m/pikuri/pikuri-workspace/lib/pikuri/workspace/filesystem.rb:218"]
    #
    # A result is a *walked* path — the model never supplied it — so it reaches
    # no +resolve_for_read+, and every consumer owes it a
    # +Filesystem#denied?+ pass plus root confinement (+pikuri:D_walked_path_denylist+).
    # {#path} returning +nil+ is the other half of that: a +jdt:+ URI inside a
    # jar can be neither denylist-checked nor read, and has to be rendered from
    # content the server hands over.
    #
    # @!attribute [r] uri
    #   @return [String] the URI verbatim, e.g.
    #     +"file:///home/m/pikuri/read.rb"+ — or a ~300-character
    #     +"jdt://contents/…"+ whose query string is a whole classpath entry,
    #     which is why a Java target is never rendered raw.
    # @!attribute [r] range
    #   @return [Range] the whole target — a definition's entire body, or every
    #     line of a reopened namespace.
    # @!attribute [r] selection_range
    #   @return [Range, nil] just the identifier inside {#range} when the server
    #     sent a +LocationLink+, +nil+ for a plain +Location+. The one thing the
    #     link shape buys, and what a one-line snippet points at.
    Location = Data.define(:uri, :range, :selection_range) do
      # Parse one +Location+ or +LocationLink+.
      #
      # @param hash [Hash{String => Object}] either wire shape.
      # @param text [String, nil] the target document's text, when to hand —
      #   what makes the columns exact, see {Range.from_wire}.
      # @param encoding [String] the server's negotiated +positionEncoding+.
      # @return [Location]
      # @raise [KeyError] if the hash is neither shape.
      def self.from_wire(hash, text: nil, encoding: PositionEncoding::DEFAULT)
        uri = hash['uri'] || hash.fetch('targetUri')
        range = hash['range'] || hash.fetch('targetRange')
        selection = hash['targetSelectionRange']
        new(uri: uri,
            range: Range.from_wire(range, text: text, encoding: encoding),
            selection_range: selection && Range.from_wire(selection, text: text, encoding: encoding))
      end

      # Parse whatever a navigation request answered with: LSP allows a single
      # object, an array, or +null+ for the same method, and servers use all
      # three.
      #
      # @param result [Hash, Array<Hash>, nil] the +result+ member.
      # @param text [String, nil] as in {.from_wire}; only useful for a
      #   single-document answer.
      # @param encoding [String] the server's negotiated +positionEncoding+.
      # @return [Array<Location>] empty for +null+ or +[]+ — which means *the
      #   server answered nothing*, and must never be rendered as "no
      #   definition exists".
      def self.list_from_wire(result, text: nil, encoding: PositionEncoding::DEFAULT)
        case result
        when nil then []
        when Hash then [from_wire(result, text: text, encoding: encoding)]
        when Array then result.map { |item| from_wire(item, text: text, encoding: encoding) }
        else raise ArgumentError, "not a location result: #{result.inspect}"
        end
      end

      def initialize(uri:, range:, selection_range: nil)
        super
      end

      # @return [String, nil] local path, or +nil+ for a non-+file:+ URI. See
      #   {Uris.to_path}.
      def path
        Uris.to_path(uri)
      end

      # @return [String, nil] the URI's scheme, e.g. +"file"+ or +"jdt"+.
      def scheme
        Uris.scheme(uri)
      end

      # @return [Boolean] whether this names a readable local file.
      def file?
        !path.nil?
      end

      # @return [Range] the tightest range the server gave: the identifier when
      #   it sent a link, the whole target otherwise.
      def anchor
        selection_range || range
      end
    end
  end
end
