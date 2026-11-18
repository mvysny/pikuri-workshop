# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Tools
      # The LLM-facing +vectordb_read+ tool — companion to {Tools::Search}:
      # where search returns ranked *chunks* (lossy, capped at
      # {Search::SNIPPET_LENGTH}), read pulls one full document into context by
      # the +source+ path search printed. The loop is *search to locate → read
      # the one or two clean hits in full → distil*, so the agent stops
      # re-querying to reconstruct a document it already found.
      #
      # == Does not widen the trifecta
      #
      # Reading is *inbound only*. The lethal trifecta's load-bearing leg is
      # egress; this pours more (already-private, already-possibly-poisoned)
      # corpus content in but adds no way out: the egress-free
      # +bin/pikuri-corpus+ agent stays egress-free.
      #
      # == The read domain is exactly the search domain
      #
      # +source+ must be a key the {Corpus} actually produced — checked against
      # {Backend#source_indexed?} before any disk access — so the only legal
      # inputs are the citations search handed the model, and a poisoned chunk
      # saying "read ../../.ssh/id_rsa" fails the membership gate (not an indexed
      # source). That's what keeps this from being a general file reader under a
      # friendly name. A lexical containment check (resolved path under the
      # corpus {Corpus#root}) backs the gate as defense-in-depth.
      #
      # Reads are line-windowed by {Pikuri::FileType.read_as_text_paged} — the
      # same windower and caps as {Pikuri::Workspace::Read}, returning a
      # {Pikuri::Extractor::Page} rendered by {Pikuri::Tool::Result.page},
      # +cat -n+ numbered like every paged reader. Extraction routes through
      # the same {Pikuri::Extractor} registry the {Corpus} uses, so a read
      # matches what was indexed exactly (modulo later edits),
      # +"--- Page N ---"+ markers included — and the line numbers in a page
      # are the ones a search hit's +lines a-b+ cites. Images / binaries /
      # vanished file / malformed PDF come back as +"Error: ..."+, not raises.
      #
      # Sharing: +P_shared_locked+, as {Search} — a locked {Backend} plus an
      # immutable root, and no read record to keep (unlike
      # {Pikuri::Workspace::Read}, nothing here gates an edit).
      class Read < Pikuri::Tool
        # @return [Integer] default value of the +limit+ parameter
        #   (number of lines returned per call). Aliases the shared
        #   {Pikuri::Extractor::PAGE_DEFAULT_LIMIT}.
        DEFAULT_LIMIT = Pikuri::Extractor::PAGE_DEFAULT_LIMIT

        # @return [String] the tool-name prefix the default tool set shares.
        DEFAULT_FAMILY = 'vectordb'

        # The description shown to the LLM, opencode-shape (summary + +Usage:+
        # bullets), naming the sibling tools by +family+ — every one of them
        # derived from it, so a second family's read tool cannot end up
        # pointing the model at this one's search.
        #
        # @param family [String] the shared tool-name prefix, e.g. +"vectordb"+.
        # @return [String]
        def self.description(family: DEFAULT_FAMILY)
          <<~DESC
            Read a full indexed document by its `source` path (the citation from #{family}_search).

            Usage:
            - Use after #{family}_search surfaces a clean hit you want in full, instead of re-querying for more fragments of the same document.
            - `source` must be a path a #{family}_search result returned; you cannot read arbitrary files, only indexed documents.
            - A path from any other #{family}_ result — a listing, say — works just as well: the check is whether the document is indexed, not which tool printed it.
            - Output is line-numbered `cat -n` style, numbered as #{family}_search's line ranges are: pass a hit's first line as `offset` to start reading at it.
            - Large documents are paged: when the output ends in `Use offset=N to continue`, call again with that offset.
            - Reading a whole document spends context — read the one or two best hits in full, not every result.
          DESC
        end

        # @param backend [#source_indexed?] any {Backend}
        #   implementation; consulted for the membership gate.
        # @param root [Pathname] the corpus root — {Corpus#root}.
        #   Relative +source+ paths resolve against it.
        # @param legs [Pikuri::Tool::TrifectaLegs] the corpus's
        #   declaration, derived by {Extension} from its
        #   corpus's +private:+ / +trusted:+ flags — the same value
        #   {Search} carries (see its "Who declares the legs").
        #   Required, for the same reason.
        # @param family [String] the tool-name prefix: the tool is
        #   +"#{family}_read"+ and its description and error strings
        #   name +"#{family}_search"+ / +"#{family}_reindex"+ as its
        #   siblings. Another gem's tool set over the same corpus
        #   plumbing reuses this class under its own prefix.
        # @return [Read]
        def initialize(backend:, root:, legs:, family: DEFAULT_FAMILY)
          super(
            name: "#{family}_read",
            description: Read.description(family: family),
            parameters: Pikuri::Tool::Parameters.build { |p|
              p.required_string :source,
                                "Source path from a #{family}_search result, " \
                                'e.g. "notes/cooking.md".'
              p.optional_integer :offset,
                                 'Line to start reading from (1-indexed). ' \
                                 'Defaults to 1, e.g. 200.'
              p.optional_integer :limit,
                                 'Maximum number of lines to read. Defaults to ' \
                                 "#{DEFAULT_LIMIT}, e.g. 500."
            },
            execute: lambda { |source:, offset: 1, limit: DEFAULT_LIMIT|
              Read.read(backend: backend, root: root, source: source, offset: offset, limit: limit,
                        family: family)
            },
            # As {Search}: corpus bytes into the context, nothing outbound.
            trifecta_legs: legs
          )
        end

        # Resolve +source+ against the corpus root, enforce the
        # membership gate + containment, extract text, and window it.
        # Public so specs can exercise the read path without a Tool
        # wrapper.
        #
        # @param backend [#source_indexed?]
        # @param root [Pathname]
        # @param source [String] the source path as supplied by the LLM
        # @param offset [Integer] 1-indexed line to start at
        # @param limit [Integer] maximum lines to return
        # @param family [String] the tool-name prefix the error strings use
        #   to name the sibling search / reindex tools.
        # @return [Pikuri::Tool::Result] the windowed text (+"Read 214
        #   lines"+), or {Pikuri::Tool::Result.error}.
        def self.read(backend:, root:, source:, offset:, limit:, family: DEFAULT_FAMILY)
          return Pikuri::Tool::Result.error("offset must be >= 1, got #{offset}") if offset < 1
          return Pikuri::Tool::Result.error("limit must be >= 1, got #{limit}") if limit < 1

          unless backend.source_indexed?(source)
            return Pikuri::Tool::Result.error("\"#{source}\" is not in the indexed corpus. " \
                                              "Use #{family}_search to find a source path, then read that.")
          end

          resolved = root.join(source).expand_path
          unless contained?(resolved, root)
            return Pikuri::Tool::Result.error("\"#{source}\" resolves outside the corpus root.")
          end

          Pikuri::Tool::Result.page(Pikuri::FileType.read_as_text_paged(resolved, offset: offset, limit: limit),
                                    name: 'document', empty_note: "(#{source} is empty)")
        rescue Errno::ENOENT
          Pikuri::Tool::Result.error("indexed document \"#{source}\" is no longer on disk; the index may be stale " \
                                     "(run #{family}_reindex to refresh).")
        rescue ArgumentError => e
          # read_as_text refusing an image / binary / directory.
          Pikuri::Tool::Result.error("cannot read \"#{source}\" as text: #{e.message}")
        rescue RuntimeError => e
          # read_as_text on a malformed / unsupported PDF.
          Pikuri::Tool::Result.error("#{e.message}")
        end

        # Lexical containment: +resolved+ must be the root or sit beneath it.
        # Lexical, not +realpath+, on purpose — the membership gate already
        # restricts +source+ to corpus keys, and resolving symlinks here would
        # wrongly reject a symlinked document the {Corpus} chose to index. Only
        # catches a +..+ / absolute escape that somehow passed the gate.
        #
        # @param resolved [Pathname]
        # @param root [Pathname]
        # @return [Boolean]
        def self.contained?(resolved, root)
          base = root.expand_path.to_s
          resolved.to_s == base || resolved.to_s.start_with?(base + File::SEPARATOR)
        end
        private_class_method :contained?
      end
    end
  end
end
