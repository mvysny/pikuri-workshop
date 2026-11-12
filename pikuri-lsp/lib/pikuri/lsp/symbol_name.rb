# frozen_string_literal: true

module Pikuri
  module Lsp
    # Comparing a name the model typed against a name a server's index reports,
    # which are not the same string even when they mean the same thing:
    #
    #   SymbolName.last_segment('Pikuri::Workspace::Read')   # => "Read"
    #   SymbolName.last_segment('Read#resolve_for_read')      # => "resolve_for_read"
    #   SymbolName.last_segment('greet(String)')              # => "greet"
    #   SymbolName.matches?('Pikuri::Tool', 'Tool')           # => true
    #
    # The rule is *compare the last segment*, and it is a measured requirement
    # rather than tidiness: ruby-lsp deliberately reports the **fully qualified**
    # name in +workspace/symbol+ (its source says why — so that searching for
    # +Foo::Bar+ works), servers separate a method from its owner with +#+ or +.+
    # depending on the language, and jdtls appends a Java signature. An exact-name
    # filter comparing +name+ verbatim therefore rejects every correct hit, which
    # is the silent-empty failure this gem exists to avoid producing itself.
    #
    # It is deliberately not a fuzzy match. The server has already been fuzzy —
    # one three-letter query returned 11 hits matched on scattered letters — and
    # what this filter is for is picking the hits that really are the name asked
    # for.
    module SymbolName
      # Separators a server may put between a container and its member.
      SEPARATORS = /::|#|\.|\$/

      module_function

      # @param name [String, nil] a name as a server reported it.
      # @return [String] the member half, with any signature dropped. +""+ for
      #   +nil+, so a nameless row simply matches nothing.
      def last_segment(name)
        name.to_s.split('(').first.to_s.split(SEPARATORS).last.to_s
      end

      # @param name [String, nil] the indexed name.
      # @param query [String] what the model asked for, which may itself be
      #   qualified (+"Pikuri::Workspace::Read"+).
      # @return [Boolean] whether they name the same member.
      def matches?(name, query)
        segment = last_segment(name)
        !segment.empty? && segment == last_segment(query)
      end
    end
  end
end
