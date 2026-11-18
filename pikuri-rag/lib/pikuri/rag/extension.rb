# frozen_string_literal: true

module Pikuri
  module Rag
    # The host-facing API: wire hybrid retrieval over a local corpus onto a
    # {Pikuri::Agent} via +c.add_extension+ in the +Agent.new+ block.
    #
    #   corpus = Pikuri::VectorDb::Corpus.new(
    #     backend:  Pikuri::Rag::Backend::Hybrid.new(
    #       vectors:  Pikuri::VectorDb::Backend::InMemory.new,
    #       keywords: Pikuri::Rag::Backend::Fts5.new
    #     ),
    #     source:   '~/notes',
    #     embedder: Pikuri::VectorDb::Embedder.new(server: ..., model: ...),
    #     private:  true, trusted: true   # what this corpus is; both default off
    #   )
    #   agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Rag::Extension.new(corpus: corpus)
    #   end
    #   watcher = Pikuri::VectorDb::Watcher.new(corpus: corpus).start
    #
    # It registers four tools — +rag_search+, +rag_search_keywords+, +rag_read+,
    # +rag_reindex+ — and nothing else. This extension is one agent's view of
    # a {Pikuri::VectorDb::Corpus}: the host builds the corpus once per folder,
    # an extension per agent over it, populates it (+index_if_empty!+, a
    # {Pikuri::VectorDb::Watcher}, or nothing — the agent then calls
    # +rag_reindex+ when asked) and closes it at teardown. See the corpus's
    # "One corpus per folder".
    #
    # Same shape as {Pikuri::VectorDb::Extension}, so a host moves a corpus
    # from the vector primitive to hybrid retrieval by wrapping its vector
    # backend in a {Backend::Hybrid} and swapping the extension class.
    # {Backend::Hybrid} says which keyword store to pair with which vector
    # store, {Backend::Fts5} how to stem another language.
    #
    # The tools' trifecta legs come from the corpus's
    # {Pikuri::VectorDb::Corpus#private?} / {Pikuri::VectorDb::Corpus#trusted?};
    # nothing about the hybrid index changes what those claim.
    #
    # == Exclusive with Pikuri::VectorDb::Extension
    #
    # {#configure} raises on any pre-registered +rag_*+ *or* +vectordb_*+ tool,
    # and {Pikuri::VectorDb::Extension#configure} does the mirror image — so
    # wiring both on one agent fails loudly whichever goes second, instead of
    # handing the model two search tools with different promises.
    #
    # == Changed your embedder or chunker? Reindex fully.
    #
    # Same as {Pikuri::VectorDb::Extension}: the change signal is the file's
    # byte hash, so swapping the embedder model or chunker window leaves every
    # indexed chunk silently stale. Run +rag_reindex+.
    #
    # == No system-prompt snippet
    #
    # No +<rag_usage>+ block is appended: the split between "relevance" and
    # "completeness" is what each tool's own description is for.
    class Extension
      include Pikuri::Agent::Extension

      # The four tool names this extension owns, in registration order.
      #
      # @return [Array<String>]
      TOOL_NAMES = %w[rag_search rag_search_keywords rag_read rag_reindex].freeze

      # @return [String] the tool-name prefix handed to
      #   {Pikuri::VectorDb::Tools::Read} / {Pikuri::VectorDb::Tools::Reindex},
      #   which is the whole of what +rag_read+ / +rag_reindex+ needed.
      FAMILY = 'rag'

      # @return [Pikuri::VectorDb::Corpus] the corpus this extension's tools
      #   search.
      attr_reader :corpus

      # @param corpus [Pikuri::VectorDb::Corpus] the corpus, over a
      #   {Backend::Hybrid}; shared with every other extension and watcher over
      #   the same folder, and closed by the host, not by this.
      # @param reranker [#rerank, nil] optional cross-encoder reranker over
      #   the fused candidates; +nil+ returns the fused top-k directly.
      # @return [Extension]
      # @raise [ArgumentError] if the corpus's backend is not a
      #   {Backend::Hybrid}: the keyword tools would have no keyword store.
      def initialize(corpus:, reranker: nil)
        unless corpus.backend.is_a?(Backend::Hybrid)
          raise ArgumentError, "Pikuri::Rag::Extension needs a corpus over a Pikuri::Rag::Backend::Hybrid, " \
                               "got #{corpus.backend.class}"
        end

        @corpus  = corpus
        @reranker = reranker
        @legs = Pikuri::VectorDb::CorpusLegs.derive(private: corpus.private?, trusted: corpus.trusted?)
      end

      # Register the four tools onto +c+; does not index.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      # @raise [RuntimeError] if any +rag_*+ or +vectordb_*+ tool is already
      #   registered — see "Exclusive with Pikuri::VectorDb::Extension".
      def configure(c)
        c.tools.each do |tool|
          next unless tool.name.start_with?('rag_', 'vectordb_')

          raise "#{tool.name} cannot be pre-registered (in tools: or via c.add_tool / " \
                'Pikuri::VectorDb::Extension) when adding Pikuri::Rag::Extension — it ' \
                'auto-registers all four rag_* tools so they share one Corpus / ' \
                'Embedder / backend, and the vectordb_* tool set is the alternative to ' \
                'this one, not a companion.'
        end

        backend = @corpus.backend
        c.add_tool Tools::Search.new(embedder: @corpus.embedder, backend: backend,
                                     reranker: @reranker, legs: @legs)
        c.add_tool Tools::SearchKeywords.new(backend: backend, root: @corpus.root, legs: @legs)
        c.add_tool Pikuri::VectorDb::Tools::Read.new(backend: backend, root: @corpus.root,
                                                     legs: @legs, family: FAMILY)
        c.add_tool Pikuri::VectorDb::Tools::Reindex.new(corpus: @corpus, family: FAMILY)
        nil
      end
    end
  end
end
