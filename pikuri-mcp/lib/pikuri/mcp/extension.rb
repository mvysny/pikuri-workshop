# frozen_string_literal: true

module Pikuri
  module Mcp
    # An {Pikuri::Agent::Extension} giving one agent the servers of a {Catalog}:
    # +<available_mcps>+ in its system prompt, an +mcp_connect+ tool, and its
    # own {Connections}, closed with the agent.
    #
    #   catalog = Pikuri::Mcp::Catalog.build(registry, transport: transport)   # once per process
    #   agent = Pikuri::Agent.new(transport: transport, system_prompt: prompt, history: saved) do |c|
    #     c.add_extension Pikuri::Mcp::Extension.new(catalog: catalog)         # once per agent
    #   end
    #
    # Building an agent spawns nothing; a server starts when this agent first
    # calls one of its tools, and never serves another agent.
    #
    # Resuming from +history:+ gives back what the conversation connected: every
    # +mcp_connect+ call in it re-registers that server's tools (skipped when the
    # id is no longer in the catalog). The calls are scanned rather than the
    # +<id>__<tool>+ calls, since a server connected but not yet used was
    # promised its tools too.
    #
    # One extension per agent — +add_extension+ refuses a reused one, which
    # would share its {Connections}, the very leak this design prevents.
    # Sub-agents don't inherit extensions, so they get no MCP. Should one ever
    # get it, it takes its own {Connections}, never the parent's: a persona
    # reading untrusted pages would otherwise drive the parent's logged-in
    # browser.
    class Extension
      include Pikuri::Agent::Extension

      # @param catalog [Catalog] the verified servers; {Catalog.build} makes one.
      #   An empty catalog makes the extension a no-op.
      def initialize(catalog:)
        @catalog = catalog
        @connections = nil
      end

      # @return [Catalog]
      attr_reader :catalog

      # @return [Connections, nil] this agent's processes; +nil+ before
      #   +configure+ or when the catalog is empty.
      attr_reader :connections

      # Create this agent's {Connections}, arm their teardown, register
      # +mcp_connect+ and re-register what a resumed conversation connected.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        return if @catalog.empty?

        connections = Connections.new(@catalog)
        @connections = connections
        c.on_close { connections.close }
        c.add_raw_tool(Connect.new(catalog: @catalog, connections: connections, configurator: c).to_ruby_llm_tool)
        restore_connects(c) if c.history
        nil
      end

      # @return [Array<String>] the +<available_mcps>+ block, or +[]+.
      def system_prompt_snippets
        @catalog.empty? ? [] : [@catalog.system_prompt_snippet]
      end

      # The MCP surface's legs, attached here because MCP tools synthesize as
      # raw +RubyLLM::Tool+ subclasses with no leg surface of their own (the
      # MCP-tool bypass seam) — so nothing downstream can declare them.
      #
      # Hard +:untrusted+ and unreviewed, attacker-reachable egress, both
      # unconditionally. A server's reachable set is unknown by construction:
      # the tool list arrives at runtime from a server you didn't write, which
      # is the whole-host case rather than the scoped one, and no trust claim
      # can be honest about it. That is exactly
      # {Pikuri::Tool::TrifectaLegs::ASSUMED}, reached independently — a
      # foreign tool surface and an undeclared local tool are the same problem.
      #
      # +:private+ rides {Registry#private?}, so an open-data server next to a
      # calculator stays silent and the same wiring beside a mail server does
      # not. The registry, not the catalog: a server that failed to start today
      # is still wired.
      #
      # @param tools [Array<Pikuri::Tool>] unused; MCP contributes no children
      # @return [Pikuri::Trifecta::Contribution, nil] +nil+ when no servers are
      #   registered, so an unused extension adds nothing
      def trifecta_contribution(tools)
        return nil if @catalog.registry.empty?

        Pikuri::Trifecta::Contribution.new(
          label: '(mcp)',
          legs: Pikuri::Tool::TrifectaLegs::ASSUMED.with(private: @catalog.registry.private?)
        )
      end

      private

      def restore_connects(c)
        c.history.messages.each do |message|
          message.tool_calls.each do |call|
            next unless call.name == Connect::NAME

            id = call.arguments['id'] || call.arguments[:id]
            next unless @catalog.include?(id) && !@connections.registered?(id)

            @connections.register_tools(id, c)
          end
        end
      end
    end
  end
end
