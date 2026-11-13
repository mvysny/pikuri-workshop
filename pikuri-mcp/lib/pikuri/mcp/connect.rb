# frozen_string_literal: true

module Pikuri
  module Mcp
    # The +mcp_connect+ tool: the model names a server from +<available_mcps>+
    # and that server's tools join its toolset for the rest of the
    # conversation. Spawns nothing — the process starts on the first tool call
    # (see {Connections}).
    #
    #   mcp_connect(id: "openlibrary")   # => "Connected to MCP server 'openlibrary'. Added 3 tools to your toolset."
    #
    # Sharing: +P_one_agent+ — it answers "already connected" from its agent's
    # {Connections}, and registers into that agent's
    # {Pikuri::Agent::ExtensionContext}.
    class Connect < Pikuri::Tool
      # The tool name, which {Extension} also looks for in a restored history.
      NAME = 'mcp_connect'

      DESCRIPTION = <<~DESC
        Connect to an MCP (Model Context Protocol) server, adding its tools to your toolset for the rest of this conversation.

        Usage:
        - The list of available server ids and their descriptions is in your system prompt under `<available_mcps>`.
        - Call with a single `id` that matches one of those entries. The server's tools become callable immediately after, namespaced as `<id>__<tool_name>` in your toolset.
        - On `Error: server '...' is already connected`, do NOT retry — the tools are already in your toolset; call them directly.
        - On `Error: unknown MCP server id ...`, pick an id that actually appears in `<available_mcps>`.
      DESC

      # @param catalog [Catalog] the ids the model may name.
      # @param connections [Connections] the agent's own; registers the tools.
      # @param ctx [Pikuri::Agent::ExtensionContext] the agent's context.
      def initialize(catalog:, connections:, ctx:)
        super(
          name: NAME,
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :id,
                              'Id of the MCP server to connect to. ' \
                              'Must match one of the ids listed under ' \
                              '`<available_mcps>` in the system prompt, e.g. "maven-tools".'
          },
          execute: lambda { |id:|
            unless catalog.include?(id)
              available = catalog.empty? ? 'none' : catalog.ids.join(', ')
              next Pikuri::Tool::Result.error("unknown MCP server id #{id.inspect}. Available: #{available}.")
            end

            if connections.registered?(id)
              next Pikuri::Tool::Result.error("server '#{id}' is already connected; its tools " \
                                              'are in your toolset, call them directly.')
            end

            count = connections.register_tools(id, ctx)
            Pikuri::Tool::Result.new(
              content: "Connected to MCP server '#{id}'. Added #{count} tool#{'s' if count != 1} " \
                       'to your toolset.',
              summary: "Connected, #{Pikuri::Tool.pluralize(count, 'tool')}"
            )
          }
        )
      end
    end
  end
end
