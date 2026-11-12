# frozen_string_literal: true

require 'set'

module Pikuri
  module Mcp
  # Runtime side of MCP support: spawns the configured servers, holds one
  # {ClientWrapper} per live server, and orchestrates the {Verifier} /
  # {Synthesizer} passes that turn a raw MCP surface into the
  # +<available_mcps>+ snippet. The +mcp+ gem dependency lives one level down
  # in {ClientWrapper}, which also owns transport selection (stdio vs HTTP) and
  # restart-on-subprocess-death retry; {Servers} stays transport-agnostic.
  #
  # == Lifecycle: two-phase, and the cleanup gap
  #
  # {#initialize} is pure; {#start_all} spawns. The split lets the owner arm
  # {#close} *between* them, before the failure-prone startup:
  #
  #   servers = Mcp::Servers.new(registry, ...)   # pure
  #   c.on_close { servers.close }                 # cleanup armed
  #   servers.start_all                            # may raise (Cancelled, injection)
  #
  # +c.on_close+ writes to the agent's live handler list (see
  # {Pikuri::Agent::Configurator}'s +on_close_sink+), so a {#start_all} raise
  # still closes any half-spawned servers via the constructor rescue — which is
  # why {Servers} needs no {Pikuri::Finalizers} coupling of its own.
  #
  # == The +Subprocess.spawn+ carve-out (stdio only)
  #
  # +MCP::Client::Stdio+ calls +Process.spawn+ internally; routing it through
  # pikuri's {Pikuri::Subprocess.spawn} chokepoint would mean forking the gem
  # or threading custom IO pipes through its API. So stdio MCP is the documented
  # exception to the chokepoint convention (AGENTS.md): the gem spawns, we own
  # +#close+ (via {ClientWrapper#close}) — closing stdin → EOF → the server
  # self-terminates per spec. HTTP entries don't spawn (plain Faraday); +#close+
  # sends the session-termination +DELETE+.
  #
  # == Roles
  #
  # {ClientWrapper} owns the per-server transport + retry; {Servers} owns
  # two-phase startup, the +@wrappers+ hash, audit logging, the
  # +<available_mcps>+ renderer, and +register_tools_with_agent+; {View} is the
  # sub-agent facade (delegates to the root, which alone owns +#close+); and
  # {Connect} is the per-agent +mcp_connect+ tool (its own activation +Set+, so
  # activation is strictly per-agent — never inherited by a sub-agent).
  #
  # == Why MCP tools bypass +Pikuri::Tool+
  #
  # MCP tools carry JSON Schema in +input_schema+, which
  # +RubyLLM::Tool.params(schema)+ accepts directly, so we synthesize
  # +RubyLLM::Tool+ subclasses here and feed them through
  # {Pikuri::Agent::ExtensionContext#add_raw_tool} — no
  # +Pikuri::Tool::Parameters+ in the middle. The strict-validation contract for
  # native tools is deliberately not extended to MCP tools in v1; MCP-side
  # validation catches bad input, and the provenance prefix + audit log are the
  # compensating transparency.
  #
  # == Sharing
  #
  # +P_one_agent+ today, and accepted as such: one wiring, one agent. The
  # +@wrappers+ / +@tools_cache+ / +@live_ids+ hashes are unguarded, and
  # {#close} tears down child processes another agent might be mid-call on.
  # {View} is the only sanctioned second reference, and it is a read-only facade
  # onto the root that alone owns +#close+.
  #
  # Nothing about MCP itself demands this — a pool of servers behind a lock
  # would serve N agents, and each agent needs only its own {Connect} set. It
  # simply isn't built, so ten agents means ten sets of children.
  class Servers
    LOGGER = Pikuri.logger_for('Mcp::Servers')
    private_constant :LOGGER

    # Construct + start in one step — the convenience for callers that don't
    # need to slot cleanup registration into the gap. {Mcp::Extension} uses the
    # two-phase {.new} + {#start_all} directly instead (see "Lifecycle").
    #
    # @param registry [Registry]
    # @param synthesizer [Synthesizer, nil] see {#initialize}
    # @param verifier [Verifier, nil] see {#initialize}
    # @return [Servers] already started
    def self.start(registry, synthesizer: nil, verifier: nil)
      new(registry, synthesizer: synthesizer, verifier: verifier).tap(&:start_all)
    end

    # Construct *without side effects* — no spawns, no synthesizer/verifier LLM
    # calls (those happen in {#start_all}, once the caller has armed {#close}).
    # The split means a {#start_all} raise (notably +Cancelled+) can't strand
    # half-spawned servers.
    #
    # @param registry [Registry] configured servers to start.
    # @param synthesizer [Synthesizer, nil] when set, invoked from
    #   {#resolve_description} for servers whose handshake lacks a useful
    #   +instructions+ / +serverInfo.title+. Threaded by {Agent#initialize} when
    #   +synthesize_descriptions:+ is true; +nil+ skips synthesis for the static
    #   fallback chain.
    # @param verifier [Verifier, nil] when set, invoked from {#start_one} before
    #   {#resolve_description}; a {Verifier::InjectionDetected} raise aborts that
    #   server's startup. Threaded by {Agent#initialize} when +verify_mcp_servers:+
    #   is true; +nil+ trusts whatever the server emits.
    # @return [Servers] not yet started — call {#start_all}
    def initialize(registry, synthesizer: nil, verifier: nil)
      @registry     = registry
      @synthesizer  = synthesizer
      @verifier     = verifier
      @wrappers     = {} # id => ClientWrapper (only for servers that started)
      @tools_cache  = {} # id => Array<MCP::Client::Tool>
      @descriptions = {} # id => short description shown in <available_mcps>
      @live_ids     = []
      @closed       = false
    end

    # Spawn and handshake every configured server, running the
    # verifier / synthesizer passes. The failure-prone phase, split
    # out of {#initialize} so the caller can register {#close} first.
    # A +start_one+ raise (notably +Cancelled+) propagates; any
    # wrappers already opened are reachable via {#close}.
    #
    # @return [void]
    def start_all
      @registry.entries.each { |entry| start_one(entry) }
    end

    # @return [Array<String>] ids of servers that successfully started.
    #   Excludes any whose subprocess spawn or handshake failed (those
    #   are logged as warnings and dropped). Identical to {Registry#ids}
    #   when no startup failures occurred.
    attr_reader :live_ids

    # @return [Boolean] true when no servers are alive (either the
    #   registry was empty, or every configured server failed to start).
    def empty?
      @live_ids.empty?
    end

    # Build the +mcp_connect+ tool bound to +ctx+'s agent; each call returns a
    # fresh {Connect} with an empty activation set.
    #
    # @param ctx [Pikuri::Agent::ExtensionContext]
    # @return [Connect]
    def build_mcp_connect_tool(ctx)
      Connect.new(servers: self, ctx: ctx)
    end

    # System-prompt block advertising every live MCP server. Empty string when
    # none are alive, so callers concatenate unconditionally. The available-ids
    # list lives here only — deliberately not duplicated into the +mcp_connect+
    # description.
    #
    # @return [String]
    def system_prompt_snippet
      return '' if empty?

      lines = [
        '',
        '',
        'The following MCP (Model Context Protocol) servers expose tools you can pull into your toolset on demand.',
        "Call `mcp_connect` with a server's id to register its tools. Schemas only enter context after you connect.",
        '',
        '<available_mcps>'
      ]
      @live_ids.each do |id|
        lines << '  <mcp>'
        lines << "    <id>#{escape_xml(id)}</id>"
        lines << "    <description>#{escape_xml(@descriptions[id] || '(no description)')}</description>"
        lines << '  </mcp>'
      end
      lines << '</available_mcps>'
      lines.join("\n")
    end

    # Register every tool exposed by server +id+ into +ctx+'s agent chat. Public
    # so {View#register_tools_with_agent} can delegate; intended caller is
    # {Connect}, which owns activation tracking (this doesn't).
    #
    # @param id [String] server id; must be in {#live_ids}.
    # @param ctx [Pikuri::Agent::ExtensionContext]
    # @return [Integer] number of tools registered.
    # @raise [ArgumentError] if +id+ isn't live.
    def register_tools_with_agent(id, ctx)
      raise ArgumentError, "MCP server #{id.inspect} is not live" unless @live_ids.include?(id)

      wrapper = @wrappers.fetch(id)
      tools = @tools_cache.fetch(id)
      tools.each do |mcp_tool|
        rb_tool = synthesize_ruby_llm_tool(server_id: id, wrapper: wrapper, mcp_tool: mcp_tool)
        ctx.add_raw_tool(rb_tool)
      end
      tools.size
    end

    # Close every live transport, terminating the spawned subprocesses.
    # Idempotent. Armed via the agent's +on_close+ before {#start_all} (see
    # "Lifecycle"). {ClientWrapper#close} logs its own errors, so this loop
    # needs no rescue.
    #
    # @return [void]
    def close
      return if @closed

      @closed = true
      @wrappers.each_value(&:close)
    end

    private

    def start_one(entry)
      wrapper = ClientWrapper.new(entry)
      tools = wrapper.tools

      # Runs BEFORE the server enters @live_ids or gets a description, so a
      # rejected server never reaches the LLM. The InjectionDetected raise is
      # caught by the specific rescue below (not the generic StandardError one)
      # so the user sees the rejection, not a "Failed to start" warning.
      @verifier&.call(entry: entry, client: wrapper.client, tools: tools)

      @wrappers[entry.id]     = wrapper
      @tools_cache[entry.id]  = tools
      @descriptions[entry.id] = resolve_description(entry, wrapper.client, tools)
      @live_ids << entry.id

      log_audit(entry, wrapper.client, tools)
    rescue Agent::Control::Cancellable::Cancelled, Verifier::InjectionDetected
      # Abort startup and re-raise so the user sees the reason, not a "Failed to
      # start" warning. {ClientWrapper.new} cleans up its own half-opened
      # transport, so +wrapper+ is nil or fully built — close it either way.
      wrapper&.close
      raise
    rescue StandardError => e
      LOGGER.warn(
        "Failed to start MCP server #{entry.id.inspect} " \
        "(#{describe_entry(entry)}): #{e.class}: #{e.message}"
      )
      # Covers the "verifier passed but resolve_description / log_audit raised"
      # path; +wrapper+ is nil or fully built (see above).
      wrapper&.close
    end

    # Short human-readable identifier for an entry's transport, used in
    # the warning log when startup fails.
    def describe_entry(entry)
      case entry
      when Registry::StdioEntry then "command: #{entry.command.join(' ')}"
      when Registry::HttpEntry  then "url: #{entry.url}"
      else                              entry.class.to_s
      end
    end

    # Resolve the short +<available_mcps>+ description, priority chain:
    # 1. +instructions+ (the MCP spec's "what this does" field);
    # 2. +serverInfo.title+;
    # 3. +@synthesizer+ when wired — turns the common no-instructions/no-title
    #    server into a real sentence; its errors surface here as +nil+ (WARN
    #    logged in {Synthesizer#call}) and fall through to (4);
    # 4. +serverInfo.name+ (last-resort operational identifier);
    # 5. +'(no description)'+ sentinel.
    def resolve_description(entry, client, tools)
      info = client.server_info || {}
      server_info = info['serverInfo'] || {}

      return info['instructions']  if info['instructions'] && !info['instructions'].to_s.strip.empty?
      return server_info['title']  if server_info['title']  && !server_info['title'].to_s.strip.empty?

      if @synthesizer
        synthesized = @synthesizer.call(entry: entry, client: client, tools: tools)
        return synthesized if synthesized
      end

      server_info['name'] || '(no description)'
    end

    def log_audit(entry, client, tools)
      info = client.server_info || {}
      server_info = info['serverInfo'] || {}
      lines = []
      lines << "MCP server #{entry.id.inspect} started (#{describe_entry(entry)})"
      lines << "  Protocol version: #{info['protocolVersion'] || '(unset)'}"
      lines << "  Server name:     #{server_info['name'] || '(unset)'}"
      lines << "  Server version:  #{server_info['version'] || '(unset)'}"
      lines << "  Instructions:    #{info['instructions'] || '(none)'}"
      lines << "  Description:     #{@descriptions[entry.id]}"
      lines << "  Tools (#{tools.size}):"
      tools.each do |t|
        lines << "    - #{t.name}"
        lines << "        description: #{t.description}"
        lines << "        input_schema: #{(t.input_schema || {}).inspect}"
        out = t.respond_to?(:output_schema) ? t.output_schema : nil
        lines << "        output_schema: #{out ? out.inspect : '(none)'}"
      end
      LOGGER.info(lines.join("\n"))
    end

    # Build an anonymous +RubyLLM::Tool+ subclass for one MCP tool, named
    # +"<server_id>__<tool_name>"+ (collision-free across servers + native
    # tools) with a +[From MCP server "<id>"]+ provenance/injection-defense
    # prefix. Input-parameter descriptions flow through verbatim via
    # +RubyLLM::Tool.params+. The execute closure captures the {ClientWrapper},
    # not the raw +MCP::Client+ — that's what makes restart-on-subprocess-death
    # transparent (the wrapper handles respawn + retry, the call site stays a
    # plain +call_tool+).
    #
    # +mcp_tool.output_schema+ has no destination: RubyLLM has no return-schema
    # slot and providers don't accept one. We surface it in the INFO audit log
    # ({#log_audit}) so a privacy-conscious user can still see what a server
    # claims to return.
    def synthesize_ruby_llm_tool(server_id:, wrapper:, mcp_tool:)
      namespaced_name = "#{server_id}__#{mcp_tool.name}"
      prefixed_desc = %([From MCP server "#{server_id}"]\n\n#{mcp_tool.description})
      schema = normalize_schema(mcp_tool.input_schema)

      # Capture the wrapper + tool for the execute closure. The
      # closure converts the MCP::Tool::Response into the
      # +"Error: ..."+ / plain-text shape pikuri's tool-call
      # observation contract uses.
      Class.new(RubyLLM::Tool) do
        description(prefixed_desc)
        parameters(schema)

        define_singleton_method(:name) { namespaced_name }

        define_method(:execute) do |**args|
          # +ClientWrapper#call_tool+ returns the raw JSON-RPC response
          # Hash: +{"jsonrpc", "id", "result" => {"content" => [...],
          # "isError" => bool}}+ on success, or +{... "error" => {...}}+
          # on JSON-RPC-level failure. Subprocess-death retries are
          # handled inside the wrapper; we only see them here if all
          # {ClientWrapper::MAX_CALL_ATTEMPTS} attempts failed.
          begin
            response = wrapper.call_tool(tool: mcp_tool, arguments: args)
          rescue StandardError => e
            next "Error: MCP server #{server_id.inspect} call failed: #{e.class}: #{e.message}"
          end

          if response['error']
            err = response['error']
            next "Error: MCP server #{server_id.inspect} returned JSON-RPC error " \
                 "#{err['code']}: #{err['message']}"
          end

          content_arr = Array(response.dig('result', 'content'))
          text = content_arr.map { |c| c.is_a?(Hash) ? c['text'] : nil }
                            .compact.join("\n")
          is_error = response.dig('result', 'isError') == true

          is_error ? "Error: #{text.empty? ? '(no detail)' : text}" : text
        end
      end
    end

    # Normalize an MCP tool's +input_schema+ into a shape
    # +RubyLLM::Tool.params+ accepts. Returns a minimal empty-object
    # schema when the MCP tool didn't supply one.
    def normalize_schema(schema)
      return { type: 'object', properties: {}, required: [] } if schema.nil?

      h = schema.is_a?(Hash) ? schema : schema.to_h
      # Strip the +$schema+ URI declaration the MCP gem adds; RubyLLM
      # doesn't need it and some providers reject extra top-level keys.
      h = h.reject { |k, _| k.to_s == '$schema' }
      # Symbol-keyed for consistency with +Pikuri::Tool::Parameters#to_h+.
      h.transform_keys(&:to_sym)
    end

    def escape_xml(str)
      str.to_s.gsub('&', '&amp;')
         .gsub('<', '&lt;')
         .gsub('>', '&gt;')
         .gsub('"', '&quot;')
         .gsub("'", '&apos;')
    end

    # The +mcp_connect+ tool. Private inner class, built only by
    # {Servers#build_mcp_connect_tool}. Tracks its own activation +Set+ so
    # re-connecting an active server returns a recoverable +"Error: ..."+ (the
    # tools are already in the toolset). Each agent owns its own instance and
    # set — activation never propagates parent↔sub-agent (the no-inherit rule,
    # {Pikuri::SubAgent::SubAgentTool}).
    #
    # Sharing: +P_one_agent+ — the activation +Set+ answers "already connected"
    # for *one* toolset, and the {Pikuri::Agent::ExtensionContext} it registers
    # through belongs to one agent. Shared, it would tell agent B a server is
    # connected while B's toolset lacks the tools. The {Servers} behind it is
    # the shareable half.
    class Connect < Pikuri::Tool
      DESCRIPTION = <<~DESC
        Connect to an MCP (Model Context Protocol) server, adding its tools to your toolset for the rest of this conversation.

        Usage:
        - The list of available server ids and their descriptions is in your system prompt under `<available_mcps>`.
        - Call with a single `id` that matches one of those entries. The server's tools become callable immediately after, namespaced as `<id>__<tool_name>` in your toolset.
        - On `Error: server '...' is already connected`, do NOT retry — the tools are already in your toolset; call them directly.
        - On `Error: unknown MCP server id ...`, pick an id that actually appears in `<available_mcps>`.
      DESC

      # @param servers [Servers] shared runtime this tool resolves
      #   ids against and registers tools through.
      # @param ctx [Pikuri::Agent::ExtensionContext] context of the
      #   agent into whose chat the activated tools are registered.
      def initialize(servers:, ctx:)
        activated = Set.new

        super(
          name: 'mcp_connect',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :id,
                              'Id of the MCP server to connect to. ' \
                              'Must match one of the ids listed under ' \
                              '`<available_mcps>` in the system prompt, e.g. "maven-tools".'
          },
          execute: lambda { |id:|
            unless servers.live_ids.include?(id)
              available = servers.live_ids.empty? ? 'none' : servers.live_ids.join(', ')
              next Pikuri::Tool::Result.error("unknown MCP server id #{id.inspect}. " \
                                              "Available: #{available}.")
            end

            if activated.include?(id)
              next Pikuri::Tool::Result.error("server '#{id}' is already connected; its tools " \
                                              'are in your toolset, call them directly.')
            end

            count = servers.register_tools_with_agent(id, ctx)
            activated << id
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
end
