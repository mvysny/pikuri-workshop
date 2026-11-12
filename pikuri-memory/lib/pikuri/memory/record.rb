# frozen_string_literal: true

require 'time'

module Pikuri
  module Memory
    # One memory row as returned by a mem0 server, normalized into a
    # plain value object. The same shape backs all three read/write
    # surfaces — +add+ (carries +event+, no +score+), +search+
    # (carries +score+, no +event+), and +get_all+ (neither) — with
    # the absent fields left +nil+, so callers can pattern-match on
    # what's present rather than juggling three near-identical types.
    #
    # == Field provenance (mem0 v3 JSON → this)
    #
    # * +id+ ← +"id"+ — the memory's UUID; the handle for +delete+.
    # * +text+ ← +"memory"+ — the fact string. Named +text+ so it doesn't
    #   shadow the enclosing module (+record.memory+ reads oddly).
    # * +score+ ← +"score"+ — Qdrant similarity (higher = more relevant);
    #   +nil+ outside +search+ results.
    # * +created_at+ ← +"created_at"+ — ISO-8601 String. Load-bearing for
    #   recall: recency is the consuming LLM's tiebreaker when resolving a
    #   stale fact against its correction, so it must travel with the text.
    # * +metadata+ ← +"metadata"+ — arbitrary Hash; +{}+ when absent.
    # * +event+ ← +"event"+ — +"ADD"+ / +"UPDATE"+ / +"DELETE"+ / +"NONE"+
    #   on an +add+ response; +nil+ on reads.
    Record = Data.define(:id, :text, :score, :created_at, :metadata, :event) do
      # Build a {Record} from one mem0 result Hash (String keys, as
      # Faraday's JSON middleware deserializes them). Tolerant of
      # missing keys — every field but +metadata+ defaults to +nil+,
      # and +metadata+ to +{}+ — so the one factory serves +add+ /
      # +search+ / +get_all+ rows alike.
      #
      # @param hash [Hash] one element of a mem0 +"results"+ array
      # @return [Record]
      def self.from(hash)
        new(
          id: hash['id'],
          text: hash['memory'],
          score: hash['score'],
          created_at: hash['created_at'],
          metadata: hash['metadata'] || {},
          event: hash['event']
        )
      end

      # +created_at+ trimmed to whole-second wall-clock for the prompt:
      # +"2026-06-01T17:04:11.884889+00:00"+ → +"2026-06-01 17:04:11"+
      # (sub-second precision and offset machinery are token noise when the
      # timestamp is only a recency tiebreaker). +nil+ when +created_at+ is
      # absent; falls back to the raw String on an unparseable value.
      #
      # @return [String, nil]
      def created_label
        return nil unless created_at

        Time.parse(created_at).strftime('%Y-%m-%d %H:%M:%S')
      rescue ArgumentError
        created_at
      end
    end
  end
end
