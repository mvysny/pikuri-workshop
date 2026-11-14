# frozen_string_literal: true

require 'set'

module Pikuri
  module Mcp
    # One agent's own MCP processes, spawned lazily from a {Catalog}:
    #
    #   connections = Connections.new(catalog)
    #   connections.register_tools('openlibrary', c)     # tools in the toolset, nothing spawned yet
    #   # ... the model calls openlibrary__search: the process starts now
    #   connections.close                                # on the agent's close
    #
    # An agent never shares a process with another: a server may hold state —
    # a logged-in browser, an open file — that one conversation produced and
    # another must not see. Registering spawns nothing, so a restored
    # conversation gets its tools back for free and most conversations never
    # start a server at all.
    #
    # Each spawn must list exactly the tools the catalog verified, or it is
    # refused ({ClientWrapper::SurfaceChanged}) — and stays refused for this
    # agent, so a changed server is not respawned on every call.
    #
    # Sharing: +P_one_agent+ — the registered set answers "already connected"
    # for one toolset, and {#close} kills processes only that agent may be
    # calling.
    #
    # == Why MCP tools bypass +Pikuri::Tool+
    #
    # MCP tools carry JSON Schema in +input_schema+, which
    # +RubyLLM::Tool.params(schema)+ accepts directly, so {#register_tools}
    # synthesizes +RubyLLM::Tool+ subclasses and feeds them through
    # {Pikuri::Agent::Configurator#add_raw_tool} — no
    # +Pikuri::Tool::Parameters+ in the middle. Strict argument validation is
    # therefore not extended to MCP tools; the server validates, and the
    # provenance prefix plus {Catalog}'s audit log are the compensating
    # transparency. +output_schema+ has no destination: RubyLLM has no
    # return-schema slot.
    class Connections
      LOGGER = Pikuri.logger_for('Mcp::Connections')
      private_constant :LOGGER

      # @param catalog [Catalog] the verified servers this agent may reach.
      def initialize(catalog)
        @catalog = catalog
        @registered = Set.new
        @wrappers = {} # id => ClientWrapper, once spawned
        @refused = {}  # id => SurfaceChanged message
        @closed = false
      end

      # @param id [String]
      # @return [Boolean] whether {#register_tools} already ran for +id+.
      def registered?(id) = @registered.include?(id)

      # Add every tool of server +id+ to +c+'s agent, named
      # +<id>__<tool>+ and prefixed +[From MCP server "<id>"]+. Spawns nothing.
      #
      # @param id [String] a {Catalog#ids} member.
      # @param c [Pikuri::Agent::Configurator] the agent's.
      # @return [Integer] how many tools were registered.
      # @raise [KeyError] when +id+ is not in the catalog.
      # @raise [ArgumentError] when +id+ is already registered — tools would
      #   double up.
      def register_tools(id, c)
        tools = @catalog.fetch(id).tools
        raise ArgumentError, "MCP server #{id.inspect} is already registered" if registered?(id)

        tools.each { |mcp_tool| c.add_raw_tool(synthesize(id, mcp_tool)) }
        @registered << id
        tools.size
      end

      # Call +tool+ on this agent's process for +id+, spawning it on first use.
      #
      # @param id [String] a registered server.
      # @param tool [MCP::Client::Tool] from the catalog.
      # @param arguments [Hash] as the model sent them.
      # @return [Hash] the raw JSON-RPC response.
      # @raise [ClientWrapper::SurfaceChanged] when the spawned process lists
      #   different tools than the catalog verified.
      # @raise [StandardError] whatever spawning or the call raises.
      def call_tool(id, tool:, arguments:)
        wrapper(id).call_tool(tool: tool, arguments: arguments)
      end

      # Close every spawned process. Idempotent.
      #
      # @return [void]
      def close
        return if @closed

        @closed = true
        @wrappers.each_value(&:close)
      end

      private

      def wrapper(id)
        raise "MCP connections already closed; cannot reach #{id.inspect}" if @closed
        raise ClientWrapper::SurfaceChanged, @refused[id] if @refused.key?(id)

        @wrappers[id] ||= begin
          server = @catalog.fetch(id)
          ClientWrapper.new(server.entry, expected_tools: server.tools)
        rescue ClientWrapper::SurfaceChanged => e
          LOGGER.warn(e.message)
          @refused[id] = e.message
          raise
        end
      end

      # An anonymous +RubyLLM::Tool+ subclass whose +execute+ answers an
      # +"Error: ..."+ observation on any failure, so the model can react.
      def synthesize(server_id, mcp_tool)
        connections = self
        namespaced_name = "#{server_id}__#{mcp_tool.name}"
        prefixed_desc = %([From MCP server "#{server_id}"]\n\n#{mcp_tool.description})
        schema = normalize_schema(mcp_tool.input_schema)

        Class.new(RubyLLM::Tool) do
          description(prefixed_desc)
          parameters(schema)

          define_singleton_method(:name) { namespaced_name }

          define_method(:execute) do |**args|
            begin
              response = connections.call_tool(server_id, tool: mcp_tool, arguments: args)
            rescue StandardError => e
              next "Error: MCP server #{server_id.inspect} call failed: #{e.class}: #{e.message}"
            end

            if response['error']
              err = response['error']
              next "Error: MCP server #{server_id.inspect} returned JSON-RPC error " \
                   "#{err['code']}: #{err['message']}"
            end

            text = Array(response.dig('result', 'content'))
                   .map { |c| c.is_a?(Hash) ? c['text'] : nil }.compact.join("\n")
            if response.dig('result', 'isError') == true
              "Error: #{text.empty? ? '(no detail)' : text}"
            else
              text
            end
          end
        end
      end

      # Symbol-keyed, +$schema+ stripped (some providers reject extra top-level
      # keys), an empty object schema when the tool declared none.
      def normalize_schema(schema)
        return { type: 'object', properties: {}, required: [] } if schema.nil?

        h = schema.is_a?(Hash) ? schema : schema.to_h
        h.reject { |k, _| k.to_s == '$schema' }.transform_keys(&:to_sym)
      end
    end
  end
end
