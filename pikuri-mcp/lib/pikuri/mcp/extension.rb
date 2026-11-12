# frozen_string_literal: true

module Pikuri
  module Mcp
    # An {Pikuri::Agent::Extension} wiring MCP support onto an agent: builds an
    # {Mcp::Servers} runtime from a {Registry}, appends +<available_mcps>+ to the
    # system prompt, arms an +on_close+ teardown, and (in +bind+) installs a
    # per-agent +mcp_connect+ tool so the LLM pulls MCP tools in on demand.
    #
    #   registry = Pikuri::Mcp::Registry.new(entries: [
    #     Pikuri::Mcp::Registry::StdioEntry.new(id: 'gmail', command: %w[gmail-mcp])
    #   ])
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Mcp::Extension.new(registry: registry)
    #   end
    #
    # +configure+ (once, on the parent's Configurator) builds the *shared*
    # {Mcp::Servers} — the owned resource; +bind+ (once, on the parent agent)
    # installs the +Connect+ tool keyed to it. Sub-agents don't inherit
    # extensions, so they get neither — personas own their toolset. On a
    # {Registry#empty?} registry the whole extension is a no-op (same semantics
    # as the +mcp_registry:+ kwarg on {Pikuri::Agent#initialize}, which routes
    # through here).
    class Extension
      include Pikuri::Agent::Extension

      # @param registry [Mcp::Registry] configured MCP servers.
      #   Defaults to {Registry::EMPTY} — extension is a no-op then.
      # @param synthesize_descriptions [Boolean] threads a
      #   {Synthesizer} into {Servers} so servers without an
      #   +instructions+ / +serverInfo.title+ field get an
      #   LLM-synthesized description for the +<available_mcps>+
      #   block. On by default — see the +synthesize_descriptions:+
      #   kwarg on +Agent#initialize+ for the full rationale.
      # @param verify_mcp_servers [Boolean] threads a {Verifier}
      #   into {Servers} so every server's handshake + tool surface
      #   is checked for prompt-injection patterns before tools can
      #   register. On by default — see the +verify_mcp_servers:+
      #   kwarg on +Agent#initialize+.
      def initialize(registry: Registry::EMPTY,
                     synthesize_descriptions: true,
                     verify_mcp_servers: true)
        @registry = registry
        @synthesize_descriptions = synthesize_descriptions
        @verify_mcp_servers = verify_mcp_servers
        @servers = nil
      end

      # @return [Mcp::Servers, nil] the runtime built in +configure+,
      #   or +nil+ when the registry was empty (extension is a
      #   no-op).
      attr_reader :servers

      # Build the shared {Servers} runtime and arm its teardown. The
      # {Synthesizer} / {Verifier} get the Configurator's transport + cancellable
      # (building their own {Thinker} + {Cache}), so the boot passes run against
      # the agent's own model and honor the same cancel flag.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        return if @registry.empty?

        if @synthesize_descriptions
          synthesizer = Mcp::Synthesizer.new(transport: c.transport, cancellable: c.cancellable)
        end
        if @verify_mcp_servers
          verifier = Mcp::Verifier.new(transport: c.transport, cancellable: c.cancellable)
        end

        # Two-phase: construct (pure), arm cleanup, then start. Arming
        # +on_close+ *before* the failure-prone +start_all+ is what makes a start
        # failure non-leaking — see {Mcp::Servers}' "Lifecycle: two-phase, and
        # the cleanup gap".
        @servers = Mcp::Servers.new(@registry, synthesizer: synthesizer, verifier: verifier)
        c.on_close { @servers.close }
        @servers.start_all
        nil
      end

      # The +<available_mcps>+ block for the started servers, from
      # already-probed state (no re-probe), so it's cheap to re-pull on a
      # conversation clear. +[]+ when no registry / no live servers.
      #
      # @return [Array<String>]
      def system_prompt_snippets
        return [] if @servers.nil? || @servers.empty?

        [@servers.system_prompt_snippet.lstrip]
      end

      # Register the per-agent +mcp_connect+ tool; its closure captures +ctx+ so
      # activations register on the correct chat (see
      # {Pikuri::Agent::ExtensionContext#add_raw_tool}).
      #
      # @param ctx [Pikuri::Agent::ExtensionContext]
      # @return [void]
      def bind(ctx)
        return if @servers.nil? || @servers.empty?

        if ctx.agent.tools.any?(Mcp::Servers::Connect)
          raise 'Mcp::Servers::Connect cannot be passed in tools: when an MCP runtime is wired; ' \
                'Agent auto-registers it.'
        end

        connect = @servers.build_mcp_connect_tool(ctx)
        ctx.add_raw_tool(connect.to_ruby_llm_tool)
        nil
      end

      # The MCP surface's legs, attached here because MCP tools synthesize as
      # raw +RubyLLM::Tool+ subclasses with no leg surface of their own (the
      # MCP-tool bypass seam) — so nothing downstream can declare them.
      #
      # Hard +:untrusted+ and unreviewed, attacker-reachable egress, both
      # unconditionally. A server's
      # reachable set is unknown by construction: the tool list arrives at
      # runtime from a server you didn't write, which is the whole-host case
      # rather than the scoped one, and no trust claim can be honest about it.
      # That is exactly {Pikuri::Tool::TrifectaLegs::ASSUMED}, reached
      # independently — a foreign tool surface and an undeclared local tool are
      # the same problem.
      #
      # +:private+ rides {Registry#private?}, so an open-data server next to a
      # calculator stays silent and the same wiring beside a mail server does
      # not.
      #
      # @param tools [Array<Pikuri::Tool>] unused; MCP contributes no children
      # @return [Pikuri::Trifecta::Contribution, nil] +nil+ when no servers are
      #   registered, so an unused extension adds nothing
      def trifecta_contribution(tools)
        return nil if @registry.empty?

        Pikuri::Trifecta::Contribution.new(
          label: '(mcp)',
          legs: Pikuri::Tool::TrifectaLegs::ASSUMED.with(private: @registry.private?)
        )
      end

    end
  end
end
