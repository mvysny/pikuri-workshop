# frozen_string_literal: true

module Pikuri
  module Lsp
    # One value of the +lsp+ tool's +operation+ enum: what the model may ask for,
    # which LSP request answers it, which capability the server must advertise
    # first, and how the answer is rendered.
    #
    #   Operation['goToDefinition'].capability   # => "definitionProvider"
    #   Operation['incomingCalls'].prepare       # => "textDocument/prepareCallHierarchy"
    #   Operation.names.size                     # => 10
    #
    # Eight names are the surface three shipped harnesses converged on, kept
    # verbatim so they match what a model has seen elsewhere; +goToTypeDefinition+
    # and +supertypes+ are measured additions.
    #
    # == Static enum, gate at dispatch
    #
    # Capabilities are per *workspace*, not per binary ({ClientWrapper#supports?}),
    # and two registered servers have different sets — so a schema computed from
    # them would have to advertise the union anyway, and would move whenever a
    # server restarted or a project gained a formatter. A moving tool description
    # is worse than a static one the model can learn.
    #
    # == Three absences that are decisions
    #
    # Each looks like an obvious addition, so each is worth a line:
    # +prepareCallHierarchy+ is out because exposing it hands the model an opaque
    # +CallHierarchyItem+ to hold and echo back — the tool runs the prepare hop
    # itself; +subtypes+ is out because +goToImplementation+ answers the same
    # question transitively in one call on the one server whose +subtypes+ is not
    # a +# TODO+ stub; and the write-side operations (rename, formatting, code
    # actions) are what this gem refuses to become.
    class Operation < Data.define(:name, :capability, :request, :prepare, :anchor, :shape, :cap, :summary)
      # @param prepare [String, nil] omitted for a one-hop operation.
      def initialize(name:, capability:, request:, anchor:, shape:, cap:, summary:, prepare: nil)
        super
      end

      # @return [Boolean] whether results get the source/tests split. True for the
      #   two operations whose volume is dominated by test files — 40 references
      #   to one method were 4 call sites, 2 declarations and 34 spec hits, and the
      #   4 are what the model asked for.
      def grouped?
        %w[findReferences incomingCalls].include?(name)
      end

      # Every operation, in the order the tool description lists them.
      #
      # @return [Array<Operation>]
      ALL = [
        new(name: 'goToDefinition', capability: 'definitionProvider',
            request: 'textDocument/definition', anchor: :position, shape: :locations, cap: 20,
            summary: 'where a name is defined. Several answers are normal — a reopened Ruby ' \
                     'namespace and a dynamically dispatched method both have more than one.'),
        new(name: 'findReferences', capability: 'referencesProvider',
            request: 'textDocument/references', anchor: :position, shape: :locations, cap: 40,
            summary: 'every use of a name, declarations included — textual uses of the ' \
                     'name, not only calls of it.'),
        new(name: 'hover', capability: 'hoverProvider', request: 'textDocument/hover',
            anchor: :position, shape: :hover, cap: 1,
            summary: 'the documentation and signature a server holds for a name — often the ' \
                     'whole class comment, and the one operation that answers for a library ' \
                     'symbol whose source is not on disk.'),
        new(name: 'documentSymbol', capability: 'documentSymbolProvider',
            request: 'textDocument/documentSymbol', anchor: :document, shape: :symbols, cap: 200,
            summary: 'the outline of one file, filtered to `symbol` when it matches a row — ' \
                     'the way to find a method the project-wide index does not hold.'),
        new(name: 'workspaceSymbol', capability: 'workspaceSymbolProvider',
            request: 'workspace/symbol', anchor: :query, shape: :symbols, cap: 25,
            summary: 'search the server\'s whole index by name, which reaches inside ' \
                     'dependencies; matching is fuzzy.'),
        new(name: 'goToImplementation', capability: 'implementationProvider',
            request: 'textDocument/implementation', anchor: :position, shape: :locations, cap: 25,
            summary: 'what implements or overrides this — an interface to its implementors, a ' \
                     'method to its overriders, and on some servers a class to every subclass ' \
                     'below it.'),
        new(name: 'goToTypeDefinition', capability: 'typeDefinitionProvider',
            request: 'textDocument/typeDefinition', anchor: :position, shape: :locations, cap: 10,
            summary: 'the *type* of an expression rather than its declaration — the only way ' \
                     'to recover a type written nowhere in the source, as with an inferred local.'),
        new(name: 'incomingCalls', capability: 'callHierarchyProvider',
            prepare: 'textDocument/prepareCallHierarchy', request: 'callHierarchy/incomingCalls',
            anchor: :position, shape: :calls, cap: 40,
            summary: 'which functions call this one, resolved through the call graph rather ' \
                     'than by name — narrower and more exact than findReferences.'),
        new(name: 'outgoingCalls', capability: 'callHierarchyProvider',
            prepare: 'textDocument/prepareCallHierarchy', request: 'callHierarchy/outgoingCalls',
            anchor: :position, shape: :calls, cap: 40,
            summary: 'what this calls, without reading the body.'),
        new(name: 'supertypes', capability: 'typeHierarchyProvider',
            prepare: 'textDocument/prepareTypeHierarchy', request: 'typeHierarchy/supertypes',
            anchor: :position, shape: :supertypes, cap: 8,
            summary: 'the ancestor chain of a class, walked level by level to the root — not ' \
                     'the one level a definition hop on the superclass name would give.')
      ].freeze

      # @return [Hash{String => Operation}] {ALL} keyed by {#name}.
      BY_NAME = ALL.to_h { |operation| [operation.name, operation] }.freeze

      # @param name [String] an enum value.
      # @return [Operation, nil] +nil+ for a name outside the enum, which
      #   +Tool::Parameters+ refuses before this is reached.
      def self.[](name)
        BY_NAME[name]
      end

      # @return [Array<String>] every enum value, in {ALL}'s order — what the
      #   tool's +operation+ parameter advertises.
      def self.names
        BY_NAME.keys
      end
    end
  end
end
