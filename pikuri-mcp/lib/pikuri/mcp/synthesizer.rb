# frozen_string_literal: true

module Pikuri
  module Mcp
    # One-shot LLM synthesis of a short "what does this MCP server do"
    # description for the +<available_mcps>+ block, paired with the on-disk
    # {Cache}. {Servers} just calls {#call} and treats +nil+ as "fall back".
    # Follows the boot-pass cancel/degrade policy: +Cancellable::Cancelled+ from
    # the {Thinker} pre-call check propagates (not caught by the +StandardError+
    # rescue) to abort startup; any other +StandardError+ (flaky LLM, cache
    # write failure) is WARN-logged and returns +nil+, so a transient blip
    # doesn't drop a server from the listing. See +pikuri-mcp/design/architecture.md+.
    class Synthesizer
      LOGGER = Pikuri.logger_for('Mcp::Synthesizer')
      private_constant :LOGGER

      # Bump when {#build_prompt} changes meaningfully. {Cache} folds it into the
      # key fingerprint so a bump invalidates the previous prompt's entries
      # without anyone +rm+-ing the cache.
      PROMPT_VERSION = 2

      # The easy path is +Synthesizer.new(transport: ...)+ — the {Thinker} and
      # the production on-disk {Cache} are built here; +thinker:+ is the explicit
      # override, mutually exclusive with +transport:+.
      #
      # @param transport [Pikuri::Agent::ChatTransport, nil] builds a {Thinker}
      #   (with +cancellable:+); the passes run against this model.
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] forwarded
      #   to the {Thinker} so a boot-time Ctrl+C aborts. Transport path only.
      # @param thinker [#call, nil] +thinker.call(prompt)+, replacing the
      #   built-in {Thinker}.
      # @param cache [Cache, Cache::NULL, nil] +nil+ builds the on-disk {Cache}
      #   on the +transport:+ path, {Cache::NULL} on the +thinker:+ path.
      # @raise [ArgumentError] when neither or both of +transport:+/+thinker:+
      #   are given, or +cancellable:+ is combined with +thinker:+.
      def initialize(transport: nil, cancellable: nil, thinker: nil, cache: nil)
        raise ArgumentError, 'pass exactly one of transport: or thinker:' if transport.nil? == thinker.nil?
        raise ArgumentError, 'cancellable: only applies to the transport: path' if thinker && cancellable

        @thinker = thinker || Thinker.new(transport: transport, cancellable: cancellable)
        @cache = cache ||
                 (transport ? Cache.new(model_id: transport.model, prompt_version: PROMPT_VERSION) : Cache::NULL)
      end

      # Produce the description for one server. Returns the cleaned
      # description String, or +nil+ when the thinker raised
      # +StandardError+, returned blank, or otherwise failed to
      # produce anything usable. {Servers#resolve_description}
      # treats +nil+ as "fall back to +serverInfo.name+."
      #
      # @param entry [Registry::StdioEntry, Registry::HttpEntry]
      # @param client [MCP::Client]
      # @param tools [Array<MCP::Client::Tool>]
      # @return [String, nil]
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] when
      #   the underlying thinker raises Cancelled — propagated so
      #   boot-time Ctrl+C aborts startup.
      def call(entry:, client:, tools:)
        raw = @cache.fetch(entry: entry, client: client, tools: tools) do
          # Only fires on cache miss — synthesis is the slow path (LLM
          # round-trip, easily 30+ s on a local model); a heads-up is
          # warranted so the user doesn't wonder if pikuri is hung.
          # Cache hits skip this and the thinker.call entirely.
          LOGGER.info("Synthesizing description for MCP server #{entry.id.inspect}, please wait...")
          @thinker.call(build_prompt(entry, tools))
        end
        cleaned = raw.to_s.strip.gsub(/\s+/, ' ')
        return nil if cleaned.empty?

        cleaned
      rescue Agent::Control::Cancellable::Cancelled
        raise
      rescue StandardError => e
        LOGGER.warn(
          "MCP description synthesis failed for #{entry.id.inspect} " \
          "(#{e.class}: #{e.message}); falling back to serverInfo.name."
        )
        nil
      end

      private

      def build_prompt(entry, tools)
        lines = []
        lines << 'You are summarizing an MCP (Model Context Protocol) server for an AI agent that decides which servers to connect to.'
        lines << ''
        lines << 'Given the server id and the names + descriptions of the tools it exposes, write ONE short sentence (under 30 words) describing what the server does and when an agent would call its tools. Do not list the tools. Do not echo the server id. No preamble, no quotes, no markdown — just the sentence.'
        lines << ''
        lines << "Server id: #{entry.id}"
        lines << 'Tools:'
        tools.each do |t|
          lines << "- #{t.name}: #{t.description}"
        end
        lines.join("\n")
      end
    end
  end
end
