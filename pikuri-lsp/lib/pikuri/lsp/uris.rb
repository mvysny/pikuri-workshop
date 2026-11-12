# frozen_string_literal: true

require 'uri'

module Pikuri
  module Lsp
    # +file:+ URI ↔ local path, plus the scheme sniff that decides whether a
    # result is a path at all:
    #
    #   Uris.for_path('/home/m/my repo/a.rb')   # => "file:///home/m/my%20repo/a.rb"
    #   Uris.to_path('file:///home/m/a%23b.rb') # => "/home/m/a#b.rb"
    #   Uris.scheme('jdt://contents/rt.jar/java.lang/String.class?=…')  # => "jdt"
    #   Uris.to_path('jdt://contents/…')        # => nil
    #
    # {.to_path} answering +nil+ is the load-bearing half: a server's answer is
    # routinely *not* a file (jdtls hands back +jdt:+ URIs for anything inside a
    # jar), and a client that assumes otherwise ends up denylist-checking a path
    # that never existed.
    module Uris
      # Characters left unescaped in a path segment: RFC 3986 unreserved, plus
      # +/+ and +:+ which are legal in a path. Everything else — space, +#+,
      # +?+, non-ASCII — is percent-encoded, because +#+ and +?+ would
      # otherwise silently truncate the URI into a fragment or a query.
      PATH_SAFE = %r{[^A-Za-z0-9\-_.!~*'()/:]}
      private_constant :PATH_SAFE

      module_function

      # @param path [String, Pathname] an absolute local path.
      # @return [String] the +file:+ URI a +didOpen+ carries.
      # @raise [ArgumentError] if +path+ is relative — a server resolves URIs
      #   against nothing, so a relative one is a silently wrong document.
      def for_path(path)
        str = path.to_s
        raise ArgumentError, "path must be absolute, got #{str.inspect}" unless str.start_with?('/')

        "file://#{URI::DEFAULT_PARSER.escape(str, PATH_SAFE)}"
      end

      # Local path behind a +file:+ URI.
      #
      # @param uri [String] any URI a server answered with.
      # @return [String, nil] the percent-decoded path, or +nil+ when +uri+ is
      #   not a +file:+ URI or names a remote host (+file://host/p+ is a UNC
      #   path; pikuri is Linux-first and has no way to read one).
      def to_path(uri)
        match = %r{\Afile://([^/]*)(/.*)\z}.match(uri)
        return nil unless match && ['', 'localhost'].include?(match[1].downcase)

        URI::DEFAULT_PARSER.unescape(match[2]).force_encoding(Encoding::UTF_8)
      end

      # @param uri [String]
      # @return [String, nil] the lowercased scheme, or +nil+ if +uri+ carries
      #   none.
      def scheme(uri)
        uri[/\A([A-Za-z][A-Za-z0-9+.\-]*):/, 1]&.downcase
      end
    end
  end
end
