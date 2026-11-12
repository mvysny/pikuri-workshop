# frozen_string_literal: true

module Pikuri
  module Memory
    # The +recall+ {Pikuri::Tool}: explicit, topic-driven deepening beyond
    # the automatic per-turn prefetch ({Extension#on_user_message}) — the
    # model calls it when the prefetch slice hints there is more on a
    # topic. The dig half of the same two-step agentic-RAG shape as
    # +pikuri-vectordb+'s +vectordb_search+/+vectordb_read+.
    #
    # +recall(topic:)+ is a deliberately minimal surface — no +top_k+, no
    # +user_id+ (retrieval depth is host policy in {Extension}, the
    # namespace is fixed at construction; the model shouldn't tune
    # retrieval mid-conversation).
    #
    # mem0 ranks by similarity, *not* recency, and keeps a stale fact
    # alongside its correction — so the observation carries each memory's
    # +created_at+ and the description tells the model to treat
    # newer-about-the-same-thing as current. Resolution lives in the
    # model's reasoning, not the store (design/architecture.md §"Supersede recall:
    # resolution is the consumer's job").
    #
    # Sharing: +P_stateless+ in pikuri's own state — the topic is an argument
    # and the namespace is fixed at construction. Two agents sharing a
    # +user_id+ *should* see each other's memories: durable cross-conversation
    # recall is the gem's whole point. The caveat sits one level down —
    # {Mem0Client} memoizes a Faraday connection and concurrent requests
    # through one are untested here, so give each agent its own client if you
    # fan out; they still share the store.
    class Recall < Pikuri::Tool
      LOGGER = Pikuri.logger_for('Memory::Recall')

      # @return [Integer] memories returned per recall. A handful —
      #   enough to surface a topic's facts plus any correction, few
      #   enough to stay cheap in the turn.
      TOP_K = 7

      # @return [String] static description shown to the LLM,
      #   opencode-shape (summary + +Usage:+ bullets).
      DESCRIPTION = <<~DESC
        Search your durable memory of the user for facts relevant to a topic.

        Usage:
        - Use to recall what you know about the user or their work beyond what was automatically surfaced this turn — preferences, ongoing projects, people, decisions.
        - Phrase `topic` as a natural-language statement or question, e.g. "the user's current main project" or "how the user likes test output".
        - Each result carries a timestamp. Memory is append-only: if two results conflict, the more recent one is current truth — the older one is kept as history, not a contradiction to flag.
        - Returns up to #{TOP_K} memories. If nothing relevant comes back, say you don't have a memory of it rather than guessing.
      DESC

      # @param client [Mem0Client] the mem0 client recall queries go to.
      # @param user_id [String] the fixed mem0 namespace to search.
      # @return [Recall]
      def initialize(client:, user_id:)
        super(
          name: 'recall',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :topic,
                              'Natural-language topic or question to recall about the user, e.g. ' \
                              '"the user\'s dietary preferences" or "what project are we working on?".'
          },
          execute: lambda { |topic:|
            Recall.execute(client: client, user_id: user_id, topic: topic)
          },
          # Private by domain, like a mailbox: durable memories about the user are
          # sensitive by what they are, not by how anything was configured.
          #
          # Hard untrusted too, which is the less obvious half. Memories are captured
          # from earlier turns, so anything an injection got the agent to believe
          # *last week* comes back as trusted-looking recall today — a stored
          # injection with a delay fuse.
          trifecta_legs: Pikuri::Tool::TrifectaLegs.new(private: true, untrusted: :hard, egress_payload_review: :no_egress)
        )
      end

      # Search and format the observation. Catches {Mem0Client} failures
      # and renders them as an +"Error: ..."+ observation the LLM can react
      # to (a transient mem0 blip shouldn't crash the loop); bugs in
      # pikuri's own code still raise.
      #
      # @param client [Mem0Client]
      # @param user_id [String]
      # @param topic [String]
      # @return [Pikuri::Tool::Result] the formatted observation (+"Recalled 3
      #   memories"+), or {Pikuri::Tool::Result.error}.
      def self.execute(client:, user_id:, topic:)
        return Pikuri::Tool::Result.error('topic is empty') if topic.nil? || topic.strip.empty?

        records = client.search(query: topic, user_id: user_id, top_k: TOP_K)
        if records.empty?
          return Pikuri::Tool::Result.new(content: 'No relevant memories found.',
                                          summary: 'Recalled 0 memories')
        end

        format_observation(records)
      rescue RuntimeError => e
        LOGGER.warn("recall failed: #{e.message}")
        Pikuri::Tool::Result.error("memory recall failed: #{e.message}")
      end

      # Format the recalled memories as a header + one line per memory,
      # each prefixed with its +created_at+ date so the model can apply
      # recency when two memories about the same thing conflict.
      #
      # @param records [Array<Record>]
      # @return [Pikuri::Tool::Result] the observation, carrying +"Recalled 3
      #   memories"+ — the count only: a memory's text is exactly the
      #   attacker-authorable content a status line must not echo.
      def self.format_observation(records)
        header = "Recalled #{records.length} " \
                 "memor#{records.length == 1 ? 'y' : 'ies'}:\n"
        body = records.map do |r|
          when_ = r.created_label ? "(#{r.created_label}) " : ''
          "- #{when_}#{r.text}"
        end.join("\n")
        Pikuri::Tool::Result.new(
          content: header + body,
          summary: "Recalled #{Pikuri::Tool.pluralize(records.length, 'memory', 'memories')}"
        )
      end
      private_class_method :format_observation
    end
  end
end
