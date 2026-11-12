# frozen_string_literal: true

module Pikuri
  module Mcp
  # Pure configuration for MCP servers — id → transport descriptor pairs, no
  # I/O, no live state. Split from {Servers} so the +mcp+ gem and
  # subprocess/network lifecycle stay on the runtime side (registry-value tests
  # never load the gem). Two sibling value classes, picked per server:
  # {StdioEntry} (local subprocess) and {HttpEntry} (remote endpoint);
  # {Servers#start_one} dispatches on type.
  #
  # The {EMPTY} singleton is the {Agent#initialize} +mcp_registry:+ default; on
  # an empty registry {Agent} short-circuits (no {Servers}, no +mcp_connect+, no
  # +<available_mcps>+), so +pikuri-chat+ can omit the kwarg. Same shape as
  # {Pikuri::Skill::Catalog::EMPTY}.
  class Registry
    # One local-subprocess MCP server's config: a unique id (the LLM's
    # +mcp_connect+ handle) and the argv to spawn it. +command+ is an argv array
    # (not a shell string) per {Pikuri::Subprocess.spawn} convention, even though
    # the +mcp+ gem owns the actual spawn (the "Subprocess seam" carve-out).
    #
    # +env+ is the stdio counterpart of {HttpEntry}'s +headers:+ — the right
    # place for a server's auth token (+{"GITHUB_TOKEN" => "..."}+) rather than
    # baking secrets into argv; the +mcp+ gem merges it over what
    # {Pikuri::BundlerEnv} hands it (this is the *legitimate* per-child
    # credential channel of the "Environment is not a secret store" seam).
    # Excluded from the cache fingerprint ({Cache#transport_descriptor}) so
    # secrets never hit disk.
    #
    # @!attribute [r] id
    #   @return [String] short identifier the LLM uses to refer to this
    #     server, e.g. +"gmail"+ or +"maven-tools"+.
    # @!attribute [r] command
    #   @return [Array<String>] argv to spawn the server,
    #     e.g. +["npx", "mcp-maven-deps"]+.
    # @!attribute [r] env
    #   @return [Hash{String => String}] extra environment variables for
    #     the spawned process, merged over the de-bundlerized environment
    #     ({Pikuri::BundlerEnv}). Frozen. Defaults to an empty hash.
    # @!attribute [r] private
    #   @return [Boolean] this server reaches data worth exfiltrating — a Notion
    #     workspace, a mail account, an internal wiki. Declared per entry
    #     because sensitivity is as unknowable to the framework here as it is
    #     for a filesystem: the person registering the server knows, and the one
    #     registering an open-data server knows too. Defaults to +false+, and
    #     feeds {Registry#private?}.
    StdioEntry = Data.define(:id, :command, :env, :private) do
      def initialize(id:, command:, env: {}, private: false)
        super(id: id, command: command, env: env.freeze, private: private)
      end
    end

    # One remote-HTTP MCP server's config: a unique id, endpoint URL, and
    # optional headers (typically auth) sent on every request. No OAuth in v1 —
    # pass a bearer token via +headers:+ (+{"Authorization" => "Bearer ..."}+);
    # the gem's +oauth:+ provider (browser flow + token persistence) is deferred.
    # Not under the subprocess-seam carve-out (nothing spawned).
    #
    # @!attribute [r] id
    #   @return [String] short identifier the LLM uses to refer to this
    #     server, e.g. +"hubspot"+.
    # @!attribute [r] url
    #   @return [String] full MCP endpoint URL, e.g.
    #     +"https://mcp.example.com/v1"+.
    # @!attribute [r] headers
    #   @return [Hash{String => String}] headers sent on every request.
    #     Frozen. Defaults to an empty hash.
    # @!attribute [r] private
    #   @return [Boolean] as in {StdioEntry}; defaults to +false+.
    HttpEntry = Data.define(:id, :url, :headers, :private) do
      def initialize(id:, url:, headers: {}, private: false)
        super(id: id, url: url, headers: headers.freeze, private: private)
      end
    end

    # @param entries [Array<StdioEntry, HttpEntry>] zero or more server
    #   definitions. Order is preserved; duplicate ids raise.
    # @return [Registry]
    # @raise [ArgumentError] if two entries share an id.
    def initialize(entries: [])
      seen = {}
      entries.each do |e|
        raise ArgumentError, "Duplicate MCP id #{e.id.inspect}" if seen.key?(e.id)

        seen[e.id] = true
      end
      @entries = entries.dup.freeze
      freeze
    end

    # @return [Array<StdioEntry, HttpEntry>] all configured entries, in
    #   declaration order.
    attr_reader :entries

    # @return [Boolean] true when no servers are configured. {Agent}
    #   keys its MCP auto-wiring off this — empty registry ⇒ no surface
    #   change, same pattern as {Pikuri::Skill::Catalog#empty?}.
    def empty?
      @entries.empty?
    end

    # Whether the MCP surface reaches private data — true if *any* registered
    # entry declares it.
    #
    # The union is over **registered** servers, not connected ones, and that is
    # the non-obvious part: an agent holding the MCP surface can reach every
    # entry here, because +mcp_connect+ activates any of them at will.
    # Registration is the capability boundary; activation is merely when the
    # tools show up. So one private server makes the whole surface private.
    #
    # Knowable at boot, which is what lets the trifecta advisory fire once per
    # process: this registry is frozen at construction, so the *tools* may
    # arrive after the Configurator block but the *legs* cannot.
    #
    # @return [Boolean]
    def private?
      @entries.any?(&:private)
    end

    # @param id [String]
    # @return [StdioEntry, HttpEntry, nil] the entry with this id, or
    #   +nil+.
    def get(id)
      @entries.find { |e| e.id == id }
    end

    # @return [Array<String>] all configured ids, in declaration order.
    def ids
      @entries.map(&:id)
    end

    # Frozen empty registry. Used as the default for
    # {Agent#initialize}'s +mcp_registry:+ kwarg.
    EMPTY = new.freeze
  end
  end
end
