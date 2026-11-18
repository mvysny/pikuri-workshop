# frozen_string_literal: true

module Pikuri
  module VectorDb
    # The host-facing API: wire topical retrieval over a local corpus onto a
    # {Pikuri::Agent} via +c.add_extension+ in the +Agent.new+ block.
    #
    #   corpus = Pikuri::VectorDb::Corpus.new(
    #     backend:  Pikuri::VectorDb::Backend::InMemory.new,
    #     source:   '~/notes',
    #     embedder: Pikuri::VectorDb::Embedder.new(server: ..., model: ...),
    #     private:  true, trusted: true   # what this corpus is; both default off
    #   )
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::VectorDb::Extension.new(corpus: corpus)
    #   end
    #
    # The extension is one agent's view of a {Corpus}: build the corpus once
    # per folder, an extension per agent over it, and close the corpus at
    # teardown (see {Corpus}'s "One corpus per folder").
    #
    # {Tools::Search} and {Tools::Read} derive their trifecta legs from the
    # corpus's {Corpus#private?} / {Corpus#trusted?}, so every agent over
    # one folder gets the same legs.
    #
    # On +configure+ it registers three tools ({Tools::Search} +
    # {Tools::Read} + {Tools::Reindex}) and nothing else. It does *not* index:
    # when/whether to populate the corpus is host policy.
    #
    # == This is the primitive, not a retrieval system
    #
    # What ships here is *topical* retrieval: pure geometry over meaning
    # vectors, which answers "what is this document about?" and structurally
    # cannot answer completeness ("every note mentioning Acme" — top-k is a
    # sample, and cosine has no calibrated zero to cut at) or exactness
    # ("invoice #4471" — rare tokens are what embedders rank worst). Those
    # need a keyword index beside the vectors, which is +pikuri-rag+: it
    # decorates the corpus's vector backend and ships +rag_search+ /
    # +rag_search_keywords+ over the same corpus. The two extensions are **mutually
    # exclusive on one agent** — {#configure} refuses a pre-registered
    # +rag_*+ tool, and {Pikuri::Rag::Extension} refuses +vectordb_*+.
    #
    # == The host owns population
    #
    # The host holds the {Corpus} and fills the corpus however it likes — an
    # explicit +corpus.index_if_empty!+ at boot, a
    # {Watcher} around it (whose boot sweep populates an empty backend then
    # tracks edits), or nothing (the agent calls +vectordb_reindex+ when asked;
    # {Tools::Search} returns no hits and says so until then). All equally valid;
    # the same host-owned shape as the {Watcher}, keeping wiring *and* timing
    # visible in the host rather than in a constructor knob.
    #
    # == Changed your embedder or chunker? Reindex fully.
    #
    # Neither a {Watcher} nor +index_if_empty!+ reacts to a config change (the
    # signal is the byte hash), so swapping the embedder model or chunker window
    # leaves every indexed chunk silently stale — new queries embed with the new
    # model but score against old-model vectors. Run a full +vectordb_reindex+.
    #
    # == No system-prompt snippet
    #
    # Unlike the workspace and sub-agent extensions, no +<vectordb_usage>+
    # block is appended: when to search is what each tool's own description
    # is for.
    class Extension
      include Pikuri::Agent::Extension

      # @return [Corpus] the corpus this extension's tools search.
      attr_reader :corpus

      # @param corpus [Corpus] the corpus, shared with every other extension
      #   and {Watcher} over the same folder; the host closes it, not this.
      # @param reranker [#rerank, nil] optional cross-encoder
      #   reranker. +nil+ skips reranking — {Tools::Search} retrieves
      #   the final top-k from the backend directly.
      # @return [Extension]
      def initialize(corpus:, reranker: nil)
        @corpus  = corpus
        @reranker = reranker
        @legs = CorpusLegs.derive(private: corpus.private?, trusted: corpus.trusted?)
      end

      # Register {Tools::Search} + {Tools::Read} + {Tools::Reindex} onto +c+; does
      # not index.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      # @raise [RuntimeError] if any of the three names is pre-registered — the
      #   extension is their single owner, and a duplicate would point at a
      #   different Corpus / Embedder / backend — or if any +rag_*+ tool is,
      #   since +pikuri-rag+ is the alternative to this extension rather than a
      #   companion (see "This is the primitive").
      def configure(c)
        c.tools.each do |tool|
          next unless tool.name.start_with?('rag_')

          raise "#{tool.name} cannot be pre-registered when adding " \
                'Pikuri::VectorDb::Extension — the rag_* tool set (Pikuri::Rag::Extension) ' \
                'replaces this one over the same corpus; wire one or the other.'
        end

        %w[vectordb_search vectordb_read vectordb_reindex].each do |name|
          next unless c.tools.any? { |t| t.name == name }

          raise "#{name} cannot be pre-registered (in tools: or via c.add_tool) " \
                'when adding Pikuri::VectorDb::Extension — the extension auto-registers ' \
                'all three tools so they share the same Corpus / Embedder / backend.'
        end

        c.add_tool Tools::Search.new(embedder: @corpus.embedder, backend: @corpus.backend,
                                     reranker: @reranker, legs: @legs)
        c.add_tool Tools::Read.new(backend: @corpus.backend, root: @corpus.root, legs: @legs)
        c.add_tool Tools::Reindex.new(corpus: @corpus)
        nil
      end
    end
  end
end
