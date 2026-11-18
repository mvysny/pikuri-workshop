# pikuri-rag and pikuri-vectordb move here, with their chapters

Status: the gems are here (2026-11-18, copied from pikuri `43ecf1e`); the book is next. This
is the workshop's half of decision **B** in pikuri's `design/ideas/fileindex-replaces-rag.md`,
which the owner agreed on 2026-11-17. That file says why; this one lists the steps on this side.
In short: pikuri's secretary and briefing search through the desktop's file index
(`pikuri-fileindex`), so nothing in pikuri needs vectors any more, and rag's future is more
features (`pikuri:D_gem_placement` test 1), so it belongs here.

## Order across the two repos

1. pikuri: commit **X**. Done: `43ecf1e`, the secretary and briefing on the file index,
   briefing moved to `pikuri-fileindex/bin/`.
2. Here: `PIKURI_REF` at X and the gems copied in from it. Done, with the five `D_` entries,
   vectordb's seam clauses (its own `AGENTS.md`), the corpus line in `SECURITY.md` and the two
   idea files.
3. Here: both chapters, copied whole and rewritten until this book reads well cover to cover,
   and `pikuri-corpus` moved to pikuri-rag (`Q_rag_demo`). Their headings are settled by the
   end of this step. The gems' READMEs already link `../book/vectordb.md` and
   `../book/rag.md`, which dangle until this step lands them.
4. pikuri: delete the gems, both chapters and the D_ entries in commit **Y**, rewrite its
   recall chapter around the file index, and point its links here. This has to come after 3,
   because that chapter links into this book's.
5. Here: set `PIKURI_REF` to Y.

From 2 on, this copy is the live one; pikuri's stays frozen until Y deletes it. Neither repo
releases either gem until the move settles (owner, 2026-11-18). The first workshop release that
ships them must be numbered above the last version pikuri published.

## a) The gems: what's left

- **`bin/pikuri-corpus`'s default corpus is this repo's `book/` now**, not pikuri's, so the
  questions vectordb.md asks it change too ("Measure, don't port" below).
- **rag's README sends its threat model to `pikuri-vectordb/design/architecture.md`**, which
  holds only the engine survey; the model itself is in `Corpus#trusted?` and
  `D_corpus_trust_declaration`. Here a gem's `design/architecture.md` owns its threat model,
  so it belongs there. It was the same in pikuri.

## b) The book

### What moves, and what stays in pikuri

- `book/vectordb.md` (706 lines) and `book/rag.md` (488 lines) move.
- **rag.md loses its demo.** Its demo is `pikuri-briefing`, which stays in pikuri on the file
  index. pikuri's idea merges its two recall chapters into one with briefing as the demo, so
  these rag.md sections stay there: "The demo: a briefing from your own notes", "Name your
  notes…", "The one-legged agent", "Local inference is this agent's first invariant" and
  "Which gem *not* to wire". See `Q_rag_demo`.
- **Each book reads whole; some overlap is fine** (`Q_chapter_split`). This book takes both
  chapters whole, "Two questions the vector DB cannot answer" included, and rewrites them to
  flow here. pikuri then drops them and writes its book around the file index. Whatever both
  books still say twice is accepted, and revisited later.

### Running order and links in this book

- **Before Memories.** `memories.md` builds on the vector-DB chapter (lines 11, 69 and 100:
  "the two-step shape", "on top of the vector-DB chapter's setup"). The order: … OS
  assistant → containers → vectordb → rag → Memories → MCP … (`Q_running_order`).
- **`book/README.md`'s intro** says most of the book needs a cage and that hosting needs none.
  Retrieval needs none either: no egress, and Qdrant is a container for persistence, not a
  cage. Add that sentence, plus the hand-off from book 1's recall chapter.
- **`os-assistant.md:284,606`** cite pikuri's vectordb.md as something already read. Here
  that chapter comes after the OS assistant. :284 compares `pikuri-fileindex`'s
  search → read pair with `vectordb_search` → `vectordb_read`, so point it at book 1's
  briefing instead. :606 says "the vector-DB chapter met that registry"; point it at wherever
  pikuri's rewrite introduces the `Extractor` registry. Thunderbird reads PDF attachments
  through it, so book 1 keeps explaining it.
- `memories.md:11,69,100,321` and `mcp.md:208` become local links.

### Rewriting the moved chapters for their new reader

- **vectordb.md gets a new opening: what vectors add over the file index, and what they
  cost.** It assumes only that the reader searched their files through `pikuri-fileindex` in
  book 1. It's written before pikuri's rewrite, so it doesn't lean on that chapter's argument
  (the three causes) or its headings, and links it by file. The evidence is pikuri's numbers:
  - The Finnish question: the file index found the English lease by search in 1 run of 10,
    while rag ranked it first every time it searched, twice from an all-Finnish query.
  - The GPU bill (`pikuri:D_secretary_wiring`): 11,685 files and hours of the GPU at 100%.

  Then who the trade is worth it for: someone whose product is search quality. Keep it honest
  both ways: the file index wins on cost, completeness and setup.

  Those eval numbers live only in pikuri's idea file. Give them a durable home here (this
  chapter or a D_ entry) before that idea graduates.
- **"Plugging in PDF support — your first extractor"** (vectordb.md:298) was book 1's first
  meeting with the `Extractor` registry. This book's reader already knows the registry from
  book 1, so keep only the vectordb part: line ranges over `--- Page N ---`.
- **"Prerequisites: three models, one server"** (vectordb.md:74) leans on pikuri's
  `chat.md#3-start-llama-server-in-multi-model-mode`. If pikuri drops the embedder and reranker
  presets from that chapter, this one owns them whole.
- **Links:** relative links to `chat.md`, `prerequisites.md`, `secretary.md`, `security.md`
  and `trifecta-detector.md` (`#who-declares-each-leg` included) become absolute links
  into pikuri's GitHub repo; check that the anchors still exist after pikuri's rewrite. The links into
  `../design/ideas/vectordb-deferrals.md` and `../pikuri-vectordb/design/architecture.md` keep
  working because both move. vectordb.md:341's link to book 2's README becomes local.
- **Measure, don't port.** Re-run every claim from the workshop checkout: boot `pikuri-corpus`,
  run `--qdrant --watch` and `--hybrid`, and wire the PDF extractor. Commands keep their shape
  from this root, as `./pikuri-rag/bin/pikuri-corpus` once the bin moves.
- **Headings become link targets.** pikuri's rewritten recall chapter will link into these
  chapters, and renaming a heading then needs a pikuri-side fix. Settle the headings before
  pikuri links them.

### The container primer

Once Qdrant leaves pikuri, its prerequisites chapter loses "Containers: Podman, or rootless
Docker" ("Meet containers", "Podman: the short path", "Docker, if you already have it"). Our
chapters link it for the rootless setup: `mcp.md:66` and `memories.md:176,194`. The primer
moves here as `containers.md`, just before vectordb, and those links become local
(`Q_container_primer`). `mcp.md`'s "Podman, or rootless Docker" argues why the `docker` group
is root, which is the primer's job, so that argument moves there too. mcp.md keeps its own
point: a server that breaks out lands in your account, not root.

## Other

- **One container-runtime picker in three places**, all here now:
  `VectorDb::Server::Container.runtime`, `Memory::Mem0Server` and `Extractors::Documents`, each
  "by convention" after the others (`Q_one_runtime_picker`).
- **Not ours, listed so nothing falls between the repos.** pikuri still has to fix its own
  references, as its idea lists: the `AGENTS.md` seam clauses, `pikuri-pdf`'s gemspec text, and
  `D_gem_placement`'s two rag cites. Y also deletes `pikuri-pdf`'s
  `vector_db_line_ranges_spec.rb` (here it is vectordb's `pdf_line_ranges_spec.rb`, with a copy
  of pikuri-pdf's `build_pdf` helper) and `SECURITY.md`'s two corpus lines (the embedder
  shipping the corpus, podman or docker for the vector store), now in ours. Its book also has to introduce the `Extractor` registry
  somewhere new, since `vectordb.md` did it until now (the secretary's PDF attachments are
  the natural place). Also the comments in pikuri-core that use `VectorDb` as an
  example: `finalizers.rb:6,29`, `extractor.rb:66` and `tool.rb:192`.

## Open questions

- `Q_rag_demo`: **resolved** (owner, 2026-11-18): vector-only against hybrid on the same
  corpus, which is exactly the chapter's lesson. It can't be a `--hybrid` flag on
  `pikuri-corpus`: that bin lives in pikuri-vectordb, and a vectordb bin wiring rag would point
  the dependency backwards. So `pikuri-corpus` moves to pikuri-rag, with its prompt, and gains
  `--hybrid`. Without the flag it stays vector-only, so vectordb.md runs it as it is today
  and rag.md adds one flag over the same corpus. vectordb.md then runs a bin from a gem it
  hasn't introduced yet, and one sentence says why. vectordb's README and
  `design/architecture.md` follow the bin. rag.md's "The watcher is on by default here" was
  about briefing; on this bin the watcher is `--watch`. Rejected: a researcher over a library
  (`../courts` exists, but a Finnish corpus is a hard demo for most readers), and a briefing
  fork here (one binary name in two repos doing two things).
- `Q_chapter_split`: **resolved** (owner, 2026-11-18): no split up front. This book takes both
  chapters whole and makes them read well here; pikuri then drops them and writes its own book
  around the file index. What both still say twice is accepted, and revisited later.
- `Q_running_order`: **resolved** (owner, 2026-11-18): … OS assistant → containers → vectordb →
  rag → Memories → MCP …. Memories builds on the vector chapter's setup, so vectordb has to
  come first; the os-assistant back-references change either way.
- `Q_container_primer`: **resolved** (owner, 2026-11-18): a short `containers.md` of its own,
  just before vectordb, whose `--qdrant` is the first container a reader starts here. Memories,
  MCP and MCPs revisited link it instead of each explaining rootless podman. Rejected: inside
  vectordb.md, as in book 1 (four other chapters would link into one chapter's middle), and
  grown into `mcp.md` (Memories and vectordb come before it).
- `Q_stemmers_fold`: **resolved** (owner, 2026-11-18): keep `Pikuri::Stemmers::Voikko` where
  it is. The placement reason is gone, but `D_voikko_stemmer`'s case still holds (one gem for
  every language, the library injected and never required), and a second rename in a month is
  churn that teaches nothing.
- `Q_one_runtime_picker`: **resolved** (owner, 2026-11-18): leave the three pickers. Sharing
  one would make pikuri-memory require pikuri-vectordb at runtime to save about ten lines.
