# frozen_string_literal: true

module Pikuri
  module Mcp
    # What the configured MCP servers offer, learned once per process: each
    # server's verified tool list and its +<available_mcps>+ description. Build
    # it once at boot, hand it to every agent's {Extension}:
    #
    #   catalog = Pikuri::Mcp::Catalog.build(registry, transport: transport, cancellable: cancel_flag)
    #   agent = Pikuri::Agent.new(...) do |c|
    #     c.add_extension Pikuri::Mcp::Extension.new(catalog: catalog)   # a fresh extension per agent
    #   end
    #
    # Building spawns each server, runs the {Verifier} and {Synthesizer}
    # passes, records what it saw, and *closes the server again*. No process
    # outlives {.build}: an agent spawns its own on first use ({Connections}),
    # because a server may hold state — a logged-in browser — that one
    # conversation must never hand to another. The catalog is what is safe to
    # share: the surface and the verdict, never a process.
    #
    # Immutable.
    #
    # == Implementation details
    #
    # One rule governs {.probe}: +Cancellable::Cancelled+ and
    # {Verifier::InjectionDetected} propagate and abort the whole build (the
    # user must see why); any other +StandardError+ is WARN-logged and drops
    # just that server.
    class Catalog
      LOGGER = Pikuri.logger_for('Mcp::Catalog')
      private_constant :LOGGER

      # One verified server: its registry entry, the tools it listed, and the
      # description +<available_mcps>+ shows for it.
      Server = Data.define(:entry, :tools, :description) do
        # @return [String] the server's registry id
        def id = entry.id
      end

      # The boot path: builds the {Synthesizer} and {Verifier} on +transport+
      # and {.probe}s every server.
      #
      # @param registry [Registry] the configured servers.
      # @param transport [Pikuri::Agent::ChatTransport] the model the boot
      #   passes run on.
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] checked
      #   before each boot-pass LLM call, so a Ctrl+C aborts the build.
      # @param around_request [#call, nil] the host's request throttle, for the
      #   boot passes' one-shot agents.
      # @param synthesize_descriptions [Boolean] write a description for a
      #   server whose handshake carries no +instructions+ / +serverInfo.title+;
      #   off, +<available_mcps>+ falls back to +serverInfo.name+.
      # @param verify_mcp_servers [Boolean] check each surface for prompt
      #   injection before it may enter the catalog; off trusts every server.
      # @return [Catalog]
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] on a cancel
      #   mid-build.
      # @raise [Verifier::InjectionDetected] when a server is flagged.
      def self.build(registry, transport:, cancellable: nil, around_request: nil,
                     synthesize_descriptions: true, verify_mcp_servers: true)
        return new(registry: registry) if registry.empty?

        pass_kwargs = { transport: transport, cancellable: cancellable, around_request: around_request }
        probe(registry,
              synthesizer: synthesize_descriptions ? Synthesizer.new(**pass_kwargs) : nil,
              verifier: verify_mcp_servers ? Verifier.new(**pass_kwargs) : nil)
      end

      # Spawn, verify, describe and close each server in turn.
      #
      # @param registry [Registry]
      # @param synthesizer [Synthesizer, nil] +nil+ skips synthesis.
      # @param verifier [Verifier, nil] +nil+ trusts every server.
      # @return [Catalog] holding the servers that started and passed.
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled]
      # @raise [Verifier::InjectionDetected]
      def self.probe(registry, synthesizer: nil, verifier: nil)
        servers = registry.entries.filter_map do |entry|
          probe_one(entry, synthesizer: synthesizer, verifier: verifier)
        end
        new(registry: registry, servers: servers)
      end

      # Pure: no process, no LLM call. {.build} is the usual way in; this one
      # suits a spec that wants a catalog without spawning anything.
      #
      # @param registry [Registry] the configuration the servers came from;
      #   {Extension} reads its {Registry#private?} for the trifecta.
      # @param servers [Array<Server>] the verified servers, in registry order.
      def initialize(registry:, servers: [])
        @registry = registry
        @servers = servers.to_h { |s| [s.id, s] }.freeze
        freeze
      end

      # @return [Registry]
      attr_reader :registry

      # @return [Array<String>] ids of the servers that started and passed
      #   verification, in registry order — a subset of {Registry#ids}.
      def ids = @servers.keys

      # @return [Boolean] true when no server made it in.
      def empty? = @servers.empty?

      # @param id [String]
      # @return [Boolean]
      def include?(id) = @servers.key?(id)

      # @param id [String]
      # @return [Server]
      # @raise [KeyError] when +id+ is not in the catalog.
      def fetch(id) = @servers.fetch(id)

      # The +<available_mcps>+ block, ready to append to a system prompt:
      #
      #   <available_mcps>
      #     <mcp>
      #       <id>openlibrary</id>
      #       <description>Searches the Open Library book catalogue.</description>
      #     </mcp>
      #   </available_mcps>
      #
      # The ids are listed here only, not in +mcp_connect+'s description.
      #
      # @return [String] +""+ when the catalog is empty.
      def system_prompt_snippet
        return '' if empty?

        lines = [
          'The following MCP (Model Context Protocol) servers expose tools you can pull into your toolset on demand.',
          "Call `mcp_connect` with a server's id to register its tools. Schemas only enter context after you connect.",
          '',
          '<available_mcps>'
        ]
        @servers.each_value do |server|
          lines << '  <mcp>'
          lines << "    <id>#{escape_xml(server.id)}</id>"
          lines << "    <description>#{escape_xml(server.description)}</description>"
          lines << '  </mcp>'
        end
        lines << '</available_mcps>'
        lines.join("\n")
      end

      class << self
        private

        def probe_one(entry, synthesizer:, verifier:)
          wrapper = ClientWrapper.new(entry)
          tools = wrapper.tools
          # Before the description: a rejected server never reaches the LLM.
          verifier&.call(entry: entry, client: wrapper.client, tools: tools)
          description = resolve_description(entry, wrapper.client, tools, synthesizer)
          log_audit(entry, wrapper.client, tools, description)
          Server.new(entry: entry, tools: tools.freeze, description: description)
        rescue Agent::Control::Cancellable::Cancelled, Verifier::InjectionDetected
          raise
        rescue StandardError => e
          LOGGER.warn("Failed to start MCP server #{entry.id.inspect} " \
                      "(#{describe_entry(entry)}): #{e.class}: #{e.message}")
          nil
        ensure
          # Nil or fully built — ClientWrapper.new closes its own half-open state.
          wrapper&.close
        end

        # +instructions+, then +serverInfo.title+, then the synthesizer (nil on
        # its failure), then +serverInfo.name+.
        def resolve_description(entry, client, tools, synthesizer)
          info = client.server_info || {}
          server_info = info['serverInfo'] || {}

          return info['instructions'] unless info['instructions'].to_s.strip.empty?
          return server_info['title'] unless server_info['title'].to_s.strip.empty?

          synthesized = synthesizer&.call(entry: entry, client: client, tools: tools)
          return synthesized if synthesized

          server_info['name'] || '(no description)'
        end

        def describe_entry(entry)
          case entry
          when Registry::StdioEntry then "command: #{entry.command.join(' ')}"
          when Registry::HttpEntry  then "url: #{entry.url}"
          else                           entry.class.to_s
          end
        end

        def log_audit(entry, client, tools, description)
          info = client.server_info || {}
          server_info = info['serverInfo'] || {}
          lines = []
          lines << "MCP server #{entry.id.inspect} started (#{describe_entry(entry)})"
          lines << "  Protocol version: #{info['protocolVersion'] || '(unset)'}"
          lines << "  Server name:     #{server_info['name'] || '(unset)'}"
          lines << "  Server version:  #{server_info['version'] || '(unset)'}"
          lines << "  Instructions:    #{info['instructions'] || '(none)'}"
          lines << "  Description:     #{description}"
          lines << "  Tools (#{tools.size}):"
          tools.each do |t|
            lines << "    - #{t.name}"
            lines << "        description: #{t.description}"
            lines << "        input_schema: #{(t.input_schema || {}).inspect}"
            # No destination downstream (RubyLLM has no return-schema slot), so
            # this log is the one place a user can see what a server claims to return.
            lines << "        output_schema: #{t.output_schema ? t.output_schema.inspect : '(none)'}"
          end
          LOGGER.info(lines.join("\n"))
        end
      end

      private

      def escape_xml(str)
        str.to_s.gsub('&', '&amp;')
           .gsub('<', '&lt;')
           .gsub('>', '&gt;')
           .gsub('"', '&quot;')
           .gsub("'", '&apos;')
      end
    end
  end
end
