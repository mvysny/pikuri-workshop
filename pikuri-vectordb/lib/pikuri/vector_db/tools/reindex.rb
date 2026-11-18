# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Tools
      # The administrative +vectordb_reindex+ tool: nukes the backend and
      # re-indexes every source file from scratch. Since {Extension} indexes
      # nothing at boot, this is both the *initial* population path and the
      # refresh path — until a host populates some other way (an explicit
      # +corpus.index_if_empty!+, a {Watcher}), the index is empty, {Tools::Search}
      # returns no hits, and the agent calls this when the user asks to build it.
      #
      # "User-asked-only" framing (in the description): reindex is orders of
      # magnitude more expensive than search — walks every file, embeds every
      # chunk, replaces the whole backend, minutes against a local embedder with
      # the agent blocked. Without the warning a model inclined to "refresh just
      # in case" before each search would burn the user's patience on turn one.
      # For keeping a long-running index fresh *without* a full reload, a host
      # runs a {Watcher} (incremental) rather than this tool.
      #
      # A mid-run +RuntimeError+ (network, embedder 5xx, backend down) comes back
      # as an +"Error: ..."+ observation, not an exploded turn.
      #
      # == No trifecta legs, whatever the corpus is
      #
      # {Pikuri::Tool::TrifectaLegs::NONE}, independent of {Corpus}'s
      # +private:+ / +trusted:+ declaration — the {Search} / {Read} case does
      # not apply here. The observation is a chunk count, a "no indexable
      # files" line, or an infrastructure error; per-file failures — the only
      # place a corpus-authored filename or an extractor's stderr would surface
      # — go to the logger and never reach the model. No corpus bytes, no
      # filenames, and no model-chosen query: {Pikuri::Workspace::Write}'s
      # case (the observation is an outcome), not +glob+'s.
      #
      # Residual, left as is: an embedder or backend error message could echo a
      # fragment of the chunk it choked on — an infrastructure failure the model
      # did not steer, carrying at most part of one chunk. Revisit on a concrete
      # attack vector, not a symmetry argument.
      #
      # Sharing: +P_shared_locked+ — {Backend#replace_source} is atomic per
      # source, so a concurrent {Search} never sees a zero-chunk gap and two
      # concurrent reindexes converge on the same state. They also each pay the
      # full embedding cost, so one agent's refresh blocking on another's is
      # wasted money, not a wrong answer.
      class Reindex < Pikuri::Tool
        # The description shown to the LLM, opencode-shape (summary + +Usage:+
        # bullets), naming the sibling search tool by +family+.
        #
        # @param family [String] the shared tool-name prefix, e.g. +"vectordb"+.
        # @return [String]
        def self.description(family: Read::DEFAULT_FAMILY)
          <<~DESC
            Build or rebuild the document index from the corpus on disk, from scratch.

            Usage:
            - The corpus is NOT indexed automatically. If `#{family}_search` returns nothing, the index may be empty — call this to build it.
            - Call it when the user asks to index, reindex, or refresh the corpus (e.g. after they've added or changed files). Do not call it as a reflexive "refresh just in case" before every search.
            - This is SLOW: walks every source file, embeds every chunk, replaces the entire index. Minutes against local embedders.
            - Takes no arguments. Returns a one-line summary when indexing completes; the agent is blocked for the duration.
          DESC
        end

        # @param corpus [Corpus] the corpus to call +#reindex!+
        #   on. Captured by the +execute+ closure so the tool can
        #   be registered against the same instance the
        #   {Extension} built at boot.
        # @param family [String] the tool-name prefix, as on {Read#initialize}:
        #   the tool is +"#{family}_reindex"+.
        # @return [Reindex]
        def initialize(corpus:, family: Read::DEFAULT_FAMILY)
          super(
            name: "#{family}_reindex",
            description: Reindex.description(family: family),
            parameters: Pikuri::Tool::Parameters.build { |_p| }, # zero params
            execute: lambda {
              Reindex.execute(corpus: corpus)
            },
            trifecta_legs: Pikuri::Tool::TrifectaLegs::NONE
          )
        end

        # Public so specs can drive the tool without constructing
        # a Pikuri::Tool wrapper.
        #
        # @param corpus [Corpus]
        # @return [Pikuri::Tool::Result] the observation (+"Indexed 412
        #   chunks"+), or {Pikuri::Tool::Result.error}.
        def self.execute(corpus:)
          total = corpus.reindex!
          content =
            if total.zero?
              'Reindexed: 0 chunks. No indexable files were found across the configured sources.'
            else
              "Reindexed: #{total} chunk(s) now in the index."
            end
          Pikuri::Tool::Result.new(content: content,
                                   summary: "Indexed #{Pikuri::Tool.pluralize(total, 'chunk')}")
        rescue RuntimeError => e
          Pikuri::Tool::Result.error("reindex failed: #{e.message}")
        end
      end
    end
  end
end
