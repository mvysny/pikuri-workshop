# pikuri-os design notes

The settled design rationale that fits neither the user-facing guide
chapter ([`book/os-assistant.md`](../../book/os-assistant.md)) nor
the per-class YARD headers — the cross-cutting *why* that spans several
classes at once. The gem's threat model (kernel-severed egress +
confirmed mutations + the passive-command detector) is **not** here:
it graduated into the book's OS-assistant chapter and the Sandbox seam
([`../pikuri-code/AGENTS.md`](../../pikuri-code/AGENTS.md)) plus the
Confirmer / Workspace seams
([`../pikuri-workspace/AGENTS.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/pikuri-workspace/AGENTS.md)). What remains for this file
is what no single class owns:

1. the choice of backend engine (`localsearch` vs `recoll`), spanning
   {Pikuri::Os::LocalSearch} + {Pikuri::Os::Recoll} + the selection in
   {Pikuri::Os::Extension};
2. why keyword recall is the whole file-search posture and semantic
   search (`pikuri-vectordb`) is deliberately declined here;
3. whether the default local model is deep enough for diagnosis.

## File search: keyword recall, not embeddings

`fileindex_search` is only as good as the backend's lexical match. When
it whiffs, the cause is one of *three*, and they have different answers
— only the third is a genuine "nothing we can do":

1. **Content not indexed / not reachable** — the dominant real limit,
   and it's *structural*, not a quality problem. `localsearch`
   **mime-gates** extraction: `text/plain` / Markdown / PDF / office get
   full body text, but **source code is filename-only** (`text/x-java`
   etc. store zero content — a 90 KB `.java` indexes 0 chars), and any
   tree containing `.git` is skipped wholesale. On top of that it has
   **no directory scoping** — it ranks globally over the whole `$HOME`
   index, so a small target corpus is buried below the default result
   limit even when fully indexed. So on a dev box the code is invisible
   and the target folder is drowned. The fix is grep (cause 2 already
   wires it) or a *different indexer* (`recoll`; survey below) — not
   embeddings.
2. **Phrasing / synonym miss** — the doc is indexed but the user's words
   differ ("the doc about our refund policy" vs. a file that says
   "returns & cancellations"). This is **already handled and in
   posture**: the agent reformulates (synonyms, narrower terms) and,
   because pikuri-os runs `FullFsNoNet` with full-disk *read* and wires
   `grep`/`glob`/`bash`, falls back to grepping likely directories when
   the index misses. `localsearch`'s index is already stemmed
   ("mouse"↔"mice", see {Pikuri::Os::LocalSearch}), so inflectional
   variants come free; the residue is true synonymy, which query
   iteration handles better than any lexical index would.
3. **Genuine semantic / conceptual gap** — cross-lingual, or "that thing
   about being frugal" → an unlabelled budget spreadsheet. The only
   cause embeddings actually address, and the rarest on a personal
   machine. Declined deliberately — **not** because `pikuri-vectordb`
   "would re-index what `localsearch` already holds" (that conflates
   *indexing cost* with retrieval *modality*; vectordb would be a
   **different modality** over the same bytes), but because owning a live
   `$HOME` embedding index means reinventing the freshness daemon
   `localsearch` hands us for free, plus embedding VRAM and a large new
   surface — straight against the offline, "small enough to audit"
   posture. Semantic *re-ranking* of `localsearch` hits doesn't rescue
   this either: it fixes precision, not recall — a doc the keyword miss
   kept out of the candidate set can't be re-ranked back in.

Cause (2) is the primary answer and needs no new infra — at most a
prompt nudge to reformulate / grep on a weak hit, *especially* for code
and git repos, which `fileindex_search` cannot see at all (cause 1).
Cause (1)'s only outward lever is `recoll`, but the survey below shows
it's a thin slice. Cause (3) stays declined.

## Backend engine: `localsearch` vs `recoll`

Both are wired behind the same duck type and {Pikuri::Os::Extension}
picks the first `available?` one, so this is a wiring outcome, not a
rewrite. The question is which earns the default and what the fallback
actually buys.

Qualified answer: `recoll` wins for *coverage and scoping*, **not for
search quality** and not for the semantic gap. Both are **lexical**
(stemmed keyword) indexers; neither does embeddings, so neither closes
cause (3) above.

**Measured (2026-07; `localsearch` vs `recoll` vs `rg` over a 59-file
pikuri Markdown corpus and `~/flowsrc`, ~825 Java files; harness +
numbers were a throwaway bench).** On content `localsearch` actually
indexes (the Markdown), `localsearch` and `recoll` are **equivalent** —
both reach ~100% recall against a ripgrep oracle across distinctive,
common, morphological, and multi-word/concept queries, returning
near-identical file sets; `localsearch` stems and does stemmed-AND
multiword just like `recoll`. recoll is *not* a better engine here. The
tempting "recoll wins 100%→single-digits" on the Java corpus was an
**artifact** — `localsearch` doesn't content-index source at all, so
those `localsearch` "hits" were *filename* matches; the fair corpus is
prose. `localsearch`'s real limits are structural, not quality:
**(a) no source code** (mime-gated; `.java` etc. filename-only, `.git`
trees skipped); **(b) no directory scoping** — global ranking over the
whole `$HOME` index, so a small target corpus is buried below the
default limit (everything is *in* the index — ~100% at a high limit —
but the LLM, capped at ten hits, sees none of it for a common word).

| | `localsearch` (tracker3) | `recoll` |
|---|---|---|
| Backend | GNOME knowledge graph (SPARQL) | Xapian |
| Setup | **zero** — already running on GNOME | install + build index + pick dirs |
| Freshness | continuous daemon (GNOME-managed) | cron *or* inotify daemon (`recollindex -m`) |
| Recall on indexed prose | ~100% (**= recoll**, measured) | ~100% |
| Source code | **filename-only** (mime-gated); `.git` trees skipped | full-text (all text mimes) |
| Directory scope | **none** — global ranking only | `dir:` filter + per-config `topdirs` |
| Query ops | stemmed AND / OR | + phrase / proximity / wildcard / field filters |
| Desktop tie-in | **GNOME-only** | DE-independent (KDE, Xfce, headless) |
| Headless CLI | `localsearch search` / `info` | `recollq` |

Reading the table: on a GNOME box `localsearch` is the right default for
whole-`$HOME` *document* discovery — already indexing, always fresh,
zero-config, and (measured) as good as recoll at it. recoll only pulls
ahead where `localsearch` is structurally blind — **source trees,
`.git` repos, scoped in-folder search, non-GNOME hosts** — and those
cases are *already* covered by the wired `grep`/`glob` (scoped, exact,
zero-setup, blind to none of it). So recoll's marginal value over the
shipped `localsearch` + grep pairing is a thin slice: fast indexed,
stemmed, ranked search over *large non-code corpora* outside GNOME's
indexed set. That thinness is why {Pikuri::Os::Extension}'s
`FILE_INDEX_BACKENDS` order encodes "localsearch if you have it": recoll
is the fallback for the **non-GNOME host** (no `localsearch` at all) or
the large non-code corpus wanting fast indexed ranking grep would scan
too slowly.

Two shape notes worth carrying: recoll's blind spot is the **inverse**
of localsearch's — it indexes exactly the configured `topdirs` (source
code included) rather than all of `$HOME` minus source, which is why its
`limitations` is a *method* reading the live `topdirs` rather than a
constant (see {Pikuri::Os::Recoll.limitations} vs
{Pikuri::Os::LocalSearch::LIMITATIONS}); and pikuri never *builds* or
*configures* a recoll index — it only queries an index the user already
maintains, so recoll's `available?` requires a built `<confdir>/xapiandb`
lest an installed-but-unindexed recoll win selection and then error on
every query.

Sources: local measurement (above);
[recoll.org](https://www.recoll.org/),
[Recoll (Wikipedia)](https://en.wikipedia.org/wiki/Recoll),
[Tracker SupportedFormats](https://wiki.gnome.org/Projects/Tracker/SupportedFormats).

## Model fit: is ~3 B active enough to diagnose?

The default `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M` splits the question in
two. Factual recall scales with *total* params — 35 B is ample for FHS,
man pages, apt. The worry was reasoning depth, which scales with the ~3 B
*active* budget: a causal chain like "service failed → the log says Y →
therefore Z" might come out shallow. Initial testing says it doesn't — the
model carries a real diagnosis end to end, not just flag recall. The
design hedges anyway: the agent iterates with tools rather than
one-shotting, and verifies recall by *reading* (a man page beats a
remembered flag). **Revisit** if longer causal chains show the active
budget falling short. Why an MoE at all, and the same-tier and
dedicated-box swaps, is the book's first-conversation chapter
([`book/chat.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/book/chat.md) §"Why a mixture-of-experts model").
