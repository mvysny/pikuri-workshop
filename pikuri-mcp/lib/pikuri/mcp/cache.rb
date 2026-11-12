# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

module Pikuri
  module Mcp
    # On-disk cache for the per-server descriptions {Synthesizer} pays an LLM
    # round-trip to produce, one +<sha256 of the key>.txt+ file per entry. Most of
    # the work is the *key calculation*: the fingerprint of every input that could
    # change the output, so an unchanged surface short-circuits and a changed
    # one auto-invalidates. The key hashes canonical JSON over: +model_id+
    # (quality varies by model), +prompt_version+, the transport descriptor
    # (argv or URL), server name+version, and the full tools surface (name,
    # description, +input_schema+ including nested properties), canonicalised by
    # recursive sort so a reordered tools array / schema keys don't blow the
    # cache. The server's registry *id* is deliberately excluded — a rename
    # doesn't change what the server does.
    #
    # No time expiry: an entry is valid until the keyed surface changes; force a
    # full rebuild by +rm+-ing {DIR} or bumping the prompt version. Callers rescue
    # around {#fetch} for corrupt-file robustness.
    class Cache
      # On-disk root, under {Paths.cache} with pikuri's other persistent caches.
      DIR = Paths.cache.join('mcp_descriptions').to_path.freeze

      # @param model_id [String, nil] model id; folded into the key so a model
      #   swap doesn't serve stale output.
      # @param prompt_version [Integer] the caller's +PROMPT_VERSION+; folded in
      #   so a prompt edit invalidates the world.
      # @param dir [String] storage directory; defaults to {DIR}.
      def initialize(model_id:, prompt_version:, dir: DIR)
        @model_id = model_id
        @prompt_version = prompt_version
        @dir = dir
      end

      # Return the cached description for the +(entry, client, tools)+ triple, or
      # yield to compute + persist + return it on a miss. A raising block
      # persists nothing, so a failed computation is retried next time.
      #
      # @param entry [Registry::StdioEntry, Registry::HttpEntry]
      # @param client [MCP::Client] for +server_info+ (name + version)
      # @param tools [Array<MCP::Client::Tool>] the server's tool list
      # @yieldreturn [String] freshly-computed description
      # @return [String] cached or freshly-computed description
      def fetch(entry:, client:, tools:, &block)
        path = File.join(@dir, "#{Digest::SHA256.hexdigest(key_for(entry, client, tools))}.txt")
        return File.read(path) if File.exist?(path)

        value = block.call
        FileUtils.mkdir_p(@dir)
        File.write(path, value)
        value
      end

      # The canonical fingerprint for a +(entry, client, tools)+ triple —
      # {#fetch} SHA-256s it into the filename; this returns the raw JSON (not a
      # hash) so it's inspectable in tests.
      #
      # @return [String] canonical JSON over the keyed inputs
      def key_for(entry, client, tools)
        info = (client.server_info || {})['serverInfo'] || {}
        fingerprint = {
          'model_id' => @model_id,
          'prompt_version' => @prompt_version,
          'transport' => transport_descriptor(entry),
          'server_name' => info['name'],
          'server_version' => info['version'],
          'tools' => tools_descriptor(tools)
        }
        JSON.generate(canonicalize(fingerprint))
      end

      private

      def transport_descriptor(entry)
        case entry
        when Registry::StdioEntry then { 'kind' => 'stdio', 'command' => entry.command }
        when Registry::HttpEntry  then { 'kind' => 'http',  'url' => entry.url }
        else                           { 'kind' => 'unknown', 'class' => entry.class.to_s }
        end
      end

      def tools_descriptor(tools)
        tools.map do |t|
          {
            'name' => t.name,
            'description' => t.description,
            'input_schema' => t.input_schema || {}
          }
        end
      end

      # Recursively normalize so semantically-equal inputs produce
      # byte-identical JSON: Hash keys stringified + sorted, Arrays left in
      # order (order is meaningful in JSON Schema's +required+).
      def canonicalize(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), out| out[k.to_s] = canonicalize(v) }
             .sort.to_h
        when Array
          obj.map { |v| canonicalize(v) }
        else
          obj
        end
      end

      # Null cache: always misses, never persists — the default when no real
      # cache is provided, so callers +@cache.fetch(...)+ unconditionally
      # instead of branching on +nil+.
      NULL = Object.new
      def NULL.fetch(entry:, client:, tools:)
        yield
      end
      NULL.freeze
    end
  end
end
