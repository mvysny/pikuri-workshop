# frozen_string_literal: true

module Pikuri
  module Lsp
    # Wires the +lsp+ tool onto an agent: builds the {Servers} runtime from a
    # {Registry}, arms its teardown, and hands the tool an event emitter so a host
    # can draw a bar while a cold index runs.
    #
    #   registry = Pikuri::Lsp::Registry.from_h(config['lsp_servers'])
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Lsp::Extension.new(registry: registry, filesystem: filesystem)
    #   end
    #
    # An empty {Registry} makes the whole extension a no-op — no tool, no
    # teardown — so a host that ships the gem without config costs the model
    # nothing.
    #
    # == Implementation details
    #
    # There is deliberately no +trifecta_contribution+: the legs belong to the
    # tool, which holds the filesystem that answers them, and a second declaration
    # here would only put the extension's name on the report row.
    class Extension
      include Pikuri::Agent::Extension

      # @param registry [Registry] configured language servers. Defaults to
      #   {Registry::EMPTY}, which makes this extension a no-op.
      # @param filesystem [Pikuri::Workspace::Filesystem] the project: the
      #   servers' root, path resolution, the denylist pass every walked result
      #   owes, and the +private?+ answer the tool's legs inherit.
      def initialize(filesystem:, registry: Registry::EMPTY)
        @registry = registry
        @filesystem = filesystem
        @servers = nil
        @tool = nil
      end

      # @return [Servers, nil] the runtime built in +configure+, or +nil+ when the
      #   registry was empty.
      attr_reader :servers

      # Build the {Servers} runtime, arm its teardown, register the tool — in that
      # order, so +close+ is armed before any call can spawn a child.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        return if @registry.empty?

        @servers = Servers.new(registry: @registry, root: @filesystem.project_root,
                               cancellable: c.cancellable)
        c.on_close { @servers.close }
        @tool = LspTool.new(servers: @servers, filesystem: @filesystem,
                            cancellable: c.cancellable)
        c.add_tool @tool
        nil
      end

      # Point the tool's progress callback at the agent's event stream.
      #
      # The tool emits on the thread that is blocked waiting for an index — the
      # agent's own — which is what makes {Pikuri::Agent::ExtensionContext#emit_event}
      # legal from there.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext]
      # @return [void]
      def bind(ctx)
        return if @tool.nil?

        @tool.on_progress = ->(progress) { ctx.emit_event(progress) }
        nil
      end
    end
  end
end
