# pikuri-rag and pikuri-vectordb move here, with their chapters

Status: not started (2026-11-18). This is the workshop's half of decision **B** in pikuri's
`design/ideas/fileindex-replaces-rag.md`, which the owner agreed on 2026-11-17. That file says
why; this one lists the steps on this side. In short: pikuri's secretary and briefing search
through the desktop's file index (`pikuri-fileindex`), so nothing in pikuri needs vectors any
more, and rag's future is more features (`pikuri:D_gem_placement` test 1), so it belongs here.

## Preconditions on pikuri's side

- **A is done.** The secretary and `pikuri-briefing` run on `pikuri-fileindex`, and nothing
  in pikuri's other gems, `bin/` or specs requires `pikuri-rag` or `pikuri-vectordb`.
- **`pikuri-briefing` moves out of `pikuri-rag/bin/` first.** It stays in pikuri, so it can't
  live in the gem that's leaving. Its prompts (`pikuri-rag/prompts/pikuri-briefing*.txt`) go
  with it.
- **No downstream user.** puri, pikuri-webui and pikuri-tui don't mention either gem
  (checked 2026-11-18).

## Order across the two repos

1. pikuri: commit **X**, with A done and briefing out of `pikuri-rag`. Push it.
2. Here: set `PIKURI_REF` to X and copy the gems in from X in one commit. A plain copy, with
   X named in the commit message; no history import (git syncs code here, it isn't a
   curated history).
3. pikuri: delete the gems, both chapters and the D_ entries in commit **Y**, and point its
   links here. This has to come after 2, because pikuri's rewritten recall chapter links
   into this book's `vectordb.md`.
4. Here: set `PIKURI_REF` to Y.

Between 2 and 4 both repos hold the code, so edit neither copy in that window.

## a) The gems

- **Copy** `pikuri-vectordb/`: `lib/`, `spec/` (with `support/container_stub.rb`), `.rspec`,
  `bin/pikuri-corpus`, `prompts/pikuri-corpus.txt`, `design/architecture.md` and the README.
  Copy `pikuri-rag/`: `lib/`, `spec/`, `.rspec`, the README, `AGENTS.md`, and `CLAUDE.md`,
  which stays a symlink.
- **Gemspecs in the workshop's shape:** `require_relative '../version'`, version
  `Pikuri::Workshop::VERSION`, the workshop's homepage and URIs. pikuri-core is pinned to
  `Pikuri::Workshop::PIKURI`, and rag's dependency on vectordb to `= Pikuri::Workshop::VERSION`.
  `listen` and `sqlite3` stay as they are. Drop `bin/pikuri-briefing` from rag's description.
  vectordb's `lib/` mentions `Workspace::*` only in comments, so it needs no pikuri-workspace
  dependency.
- **spec_helper:** compare it with a sibling's (`pikuri-stemmers/spec/spec_helper.rb`), and
  bring the Zeitwerk inflector entries from both entry files across unchanged.
- **The PDF line-ranges spec comes too:** `pikuri-pdf/spec/pikuri/vector_db_line_ranges_spec.rb`
  becomes `pikuri-vectordb/spec/pikuri/vector_db/pdf_line_ranges_spec.rb`. pikuri-pdf is
  already in the root Gemfile's git block.
- **Root `Gemfile`:** add `gemspec path:` for both gems and drop both from the git block. Reword
  the comment above `PIKURI_REF`: "vectordb for the shared Qdrant image pin, and rag for
  pikuri-stemmers' spec" now describes siblings.
- **`Rakefile` `GEMS`:** add `pikuri-vectordb` and `pikuri-rag` right after
  `pikuri-extractors`. The list is topologically sorted, and the stemmers' spec builds a real
  `Fts5`.
- **Tripwires:** on 2026-11-18 I ran the five patterns from `tasks/tripwires.rake` over both
  `lib/` trees and got no hits, so `rake tripwires` should stay green. CI needs no new
  packages: the prebuilt `sqlite3` gem has FTS5, and the Qdrant specs stub the container.
  Prove both with `bundle exec rake check`.
- **Release:** both gems were published from pikuri at its lockstep version. The first
  workshop release that ships them must be numbered above the last version pikuri published.
  The owner check in the `Rakefile` passes, since it's the same owner.

### Workshop references to rewrite

- `pikuri-stemmers/README.md:3,25`: the pikuri-repo link to pikuri-rag's README becomes
  `../pikuri-rag/README.md`. The gemspec comment "Not pikuri-rag: a stemmer is a duck it
  calls" stays true.
- `pikuri-memory/spec/pikuri/memory/mem0_server_spec.rb:161-170`: the
  `skip 'pikuri-vectordb not in this bundle'` branch is dead now, so the Qdrant image-pin check
  becomes unconditional.
- `pikuri-extractors/lib/pikuri/extractors/documents.rb:124`: "pikuri's
  `VectorDb::Server::Container.runtime`" now names a sibling.
- `design/decisions.md:1894` (`D_voikko_stemmer`): `pikuri:D_ruby_stemming` becomes
  `D_ruby_stemming`. `pikuri-memory/design/architecture.md:463` and
  `design/ideas/tool-list-in-context.md:83`: `pikuri:D_corpus_trust_declaration` becomes local.
- `README.md`: two rows in the gem table, and the pitch names semantic search. `AGENTS.md`:
  "What this is" names semantic search too, the module map gets two lines (rag's says
  "Rules: `pikuri-rag/AGENTS.md`"), and the `pikuri-stemmers` line stays.
- `CHANGELOG.md`: one sentence, "pikuri-vectordb and pikuri-rag moved here from pikuri,
  unchanged."

### Docs that move with the gems

- **D_ entries** go to `design/decisions.md`: `D_rag_gem`, `D_rrf_tuning`,
  `D_chunk_line_ranges`, `D_ruby_stemming`, `D_corpus_trust_declaration`. Their cites into
  pikuri (`D_gem_placement`, `D_secretary_wiring`, `D_llm_request_throttle`, …) become
  `pikuri:D_…`, and `rake design_tripwires` catches any left bare. Reread `D_ruby_stemming`'s
  "ship no language here" and its rejected alternative "Keeping the Finnish stemmer in
  pikuri-rag" now that both sit beside `D_voikko_stemmer` (`Q_stemmers_fold`).
- **pikuri's Connection and Request seams** (its `AGENTS.md:46,48`) name `VectorDb::Embedder`
  and `Reranker::LlamaServer`. Those two clauses go to a new `pikuri-vectordb/AGENTS.md`, with
  a Rules pointer in the module map. The root keeps only "pikuri's invariants hold here".
- **pikuri's `SECURITY.md`** lines on the corpus (the no-egress `pikuri-corpus` posture) go to
  ours.
- **Ideas:** `vectordb-deferrals.md` and `rag-hit-presentation-eval.md`, with its 12-file
  sidecar, go to `design/ideas/`. Fix their `../../` links.

## b) The book

### What moves, and what stays in pikuri

- `book/vectordb.md` (706 lines) and `book/rag.md` (488 lines) move.
- **rag.md loses its demo.** Its demo is `pikuri-briefing`, which stays in pikuri on the file
  index. pikuri's idea merges its two recall chapters into one with briefing as the demo, so
  these rag.md sections stay there: "The demo: a briefing from your own notes", "Name your
  notes…", "The one-legged agent", "Local inference is this agent's first invariant" and
  "Which gem *not* to wire". See `Q_rag_demo`.
- **One home for the completeness and exactness argument.** pikuri keeps "Two questions the
  vector DB cannot answer" to motivate its keyword index. rag.md here keeps the hybrid half:
  BM25, RRF, "indexed" meaning both stores hold it, model text never reaching `MATCH`, and the
  watcher. It links pikuri's chapter for the argument (`Q_chapter_split`).

### Running order and links in this book

- **Before Memories.** `memories.md` builds on the vector-DB chapter (lines 11, 69 and 100:
  "the two-step shape", "on top of the vector-DB chapter's setup"). Proposed order: … OS
  assistant → vectordb → rag → Memories → MCP … (`Q_running_order`).
- **`book/README.md`'s intro** says most of the book needs a cage and that hosting needs none.
  Retrieval needs none either: no egress, and Qdrant is a container for persistence, not a
  cage. Add that sentence, plus the hand-off from book 1's recall chapter.
- **`os-assistant.md:284,606`** cite pikuri's vectordb.md as something already read ("the
  vector-DB chapter met that registry"). Under the proposed order that chapter comes after the
  OS assistant, so reword them, or point them at wherever pikuri now introduces the
  `Extractor` registry.
- `memories.md:11,69,100,321` and `mcp.md:208` become local links.

### Rewriting the moved chapters for their new reader

- **vectordb.md gets a new opening.** The reader arrives from pikuri's recall chapter, which
  sorted search misses into three causes and said only the third needs vectors. Start there,
  with pikuri's numbers as the evidence:
  - The Finnish question: the file index found the English lease by search in 1 run of 10,
    while rag ranked it first every time it searched, twice from an all-Finnish query.
  - The GPU bill (`pikuri:D_secretary_wiring`): 11,685 files and hours of the GPU at 100%.

  Those eval numbers live only in pikuri's idea file. Give them a durable home here (this
  chapter or a D_ entry) before that idea graduates.
- **"Plugging in PDF support — your first extractor"** (vectordb.md:298) was book 1's first
  meeting with the `Extractor` registry. This book's reader already knows the registry, so keep
  only the vectordb part: line ranges over `--- Page N ---`.
- **"Prerequisites: three models, one server"** (vectordb.md:74) leans on pikuri's
  `chat.md#3-start-llama-server-in-multi-model-mode`. If pikuri drops the embedder and reranker
  presets from that chapter, this one owns them whole.
- **Links:** relative links to `chat.md`, `prerequisites.md`, `secretary.md`, `security.md`
  and `trifecta-detector.md` (`#who-declares-each-leg` included) become absolute links
  into pikuri's GitHub repo; check that the anchors still exist after pikuri's rewrite. The links into
  `../design/ideas/vectordb-deferrals.md` and `../pikuri-vectordb/design/architecture.md` keep
  working because both move. vectordb.md:341's link to book 2's README becomes local.
- **Measure, don't port.** Re-run every claim from the workshop checkout: boot `pikuri-corpus`,
  run `--qdrant --watch`, and wire the PDF extractor. Commands like
  `./pikuri-vectordb/bin/pikuri-corpus` work from this root unchanged.
- **Headings become link targets.** pikuri's rewritten recall chapter will link into these
  chapters, and renaming a heading then needs a pikuri-side fix. Settle the headings before
  pikuri links them.

### The container primer

Once Qdrant leaves pikuri, its prerequisites chapter loses "Containers: Podman, or rootless
Docker" ("Meet containers", "Podman: the short path", "Docker, if you already have it"). Our
chapters link it for the rootless setup: `mcp.md:66` and `memories.md:176,194`. The primer
moves here (`Q_container_primer`).

## Other

- **One container-runtime picker in three places**, all here once vectordb arrives:
  `VectorDb::Server::Container.runtime`, `Memory::Mem0Server` and `Extractors::Documents`, each
  "by convention" after the others (`Q_one_runtime_picker`).
- **Not ours, listed so nothing falls between the repos.** pikuri still has to fix its own
  references, as its idea lists: the `AGENTS.md` seam clauses, `pikuri-pdf`'s gemspec text, and
  `D_gem_placement`'s two rag cites. Also the comments in pikuri-core that use `VectorDb` as an
  example: `finalizers.rb:6,29`, `extractor.rb:66` and `tool.rb:192`.

## Open questions

- `Q_rag_demo`: what does rag.md demo once briefing leaves?
  - (a) `pikuri-corpus --hybrid`: one bin, vector-only against hybrid on the same corpus,
    which is exactly the chapter's lesson.
  - (b) A researcher binary over a library: the persona pikuri rejected for its ending,
    because search quality *is* that user's product, i.e. this book's reader. `../courts`
    (4 Finnish acts, 41 gold questions) exists from `rag-hit-presentation-eval`, but a Finnish
    corpus is a hard demo for most readers.
  - (c) A rag-flavoured briefing fork here. Reject it: one binary name in two repos doing two
    things.

  Leaning (a).
- `Q_chapter_split`: split rag.md's argument between pikuri's recall chapter and this book's
  rag.md in the same sitting as pikuri's rewrite. Otherwise both books keep a copy.
- `Q_running_order`: vectordb and rag just before Memories, or as a retrieval block somewhere
  else? Whatever the choice, the os-assistant back-references change.
- `Q_container_primer`: where does pikuri's container section land?
  - (a) In vectordb.md, the chapter where "containers first earn their keep", as in book 1.
  - (b) A short `containers.md` of its own, just before the first chapter that runs a
    container, which every container chapter links.
  - (c) Grown into `mcp.md`'s existing "Podman, or rootless Docker" section, but Memories and
    vectordb come before MCP.

  Leaning (b), since five chapters use containers, but it depends on `Q_running_order`.
- `Q_stemmers_fold`: with rag here, does `Pikuri::Stemmers::Voikko` fold back into rag as
  `Rag::Stemmer::Voikko`? The placement reason is gone, but `D_voikko_stemmer`'s case still
  holds (one gem for every language, the library injected and never required). Leaning keep:
  a second rename in a month is churn and teaches nothing.
- `Q_one_runtime_picker`: share one picker across the three gems? A shared one means a
  cross-gem runtime dependency (pikuri-memory requiring pikuri-vectordb) to save about ten
  lines. Leaning leave it.
