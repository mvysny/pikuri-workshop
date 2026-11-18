# pikuri-vectordb design notes

The settled design rationale that fits neither the user-facing book
chapter ([`book/vectordb.md`](../../book/vectordb.md))
nor the per-class YARD headers: the threat model, which `pikuri-rag`
shares unchanged, and the backend-engine survey behind Qdrant as the one
persistent engine.

## Threat model

**No tool here sends anything out.** Every tool that returns corpus text
carries `egress_payload_review: :no_egress`, so an agent wired with the
corpus alone holds at most two legs: private data and untrusted content.
The third leg comes only from what else the host wires. An agent that
holds the corpus *and* egress is the host's choice, and the cure is to
weaken the egress, as `pikuri:D_secretary_wiring` does, not to put the
corpus behind a sub-agent (`D_corpus_trust_declaration`).

**The two legs are declared, not guessed.** Whether a corpus is private,
and whether every byte in it is yours, are properties of the data, so the
host declares them once on `Corpus.new(private:, trusted:)` and
`CorpusLegs.derive` turns them into the legs of every reading tool. Both
default off, which prints the pessimistic map. The declaration decides
what the boot map *prints*; it blocks nothing. `trusted: true` is three
claims, and the extraction gap in the first one (a PDF's hidden text is
present in what the model reads) is the one that bites:
`Corpus#trusted?` has them, `D_corpus_trust_declaration` the reasoning.
`vectordb_reindex` declares no legs at all: its result is a count, never
corpus text or a filename.

**The reader reads only what the index holds.** `vectordb_read`, and
rag's `rag_read`, accept only a `source` the backend already indexed,
checked before any disk access, with a path-containment check behind it.
A poisoned chunk that says "read `../../.ssh/id_rsa`" names no indexed
source and fails. So the corpus tools reach exactly the folder they
index, which is what lets the declaration be honest.

**What the stores add is copies.** `InMemory` lives in the process and is
gone at exit. `--qdrant` keeps every chunk under `Paths.cache/qdrant` and
serves it from a pinned container on `127.0.0.1` with no auth, so any
process that reaches the host's loopback reads the indexed corpus: the
same residual as `pikuri-memory`'s published API. rag's FTS5 index is the
same text again, in memory or in an SQLite file the host names. And the
embedder reads every chunk at index time, so an embedder on a remote
provider receives the whole corpus.

**Parsing is the extractor's problem, not this gem's.** A hostile PDF
that exploits the parser attacks the `Pikuri::Extractor` that reads it,
before any chunk exists. `trusted:` never means "safe to parse".

## Backend engines: Chroma vs Qdrant (survey 2026-06-02)

Point-in-time comparison — star counts, versions, and image sizes move;
verify before depending. Context: `pikuri-vectordb` shipped a Chroma
backend + supervisor first; `pikuri-memory`'s mem0 stack
independently runs **Qdrant** (chosen there for correctness — see
[`pikuri-memory/design/architecture.md`](../../pikuri-memory/design/architecture.md) §"Why Qdrant,
not pgvector"). Two gems, two self-managed vector databases, two
engines. The decision this survey backs: **converge the preferred
engine on Qdrant.** The `Backend` seam is duck-typed precisely so this
is a wiring choice, not a rewrite.

### Side-by-side

| | Chroma | Qdrant |
|---|---|---|
| First public release | Feb 2023 (company founded Apr 2022) | 2021 (development started 2020) |
| GitHub stars (2026-06-02) | 28.2k | 31.7k |
| License | Apache-2.0 | Apache-2.0 |
| Open-source status | OSS single-node server + managed Chroma Cloud | OSS server incl. clustering + managed Qdrant Cloud |
| Core language | Rust core since 1.0 (2025); was Python before | Rust from the first commit |
| Latest release | 1.5.9 (May 2026) | v1.18.1 (May 2026) |
| Backing | Chroma Inc (SF); ~$20M (pre-seed 2022, $18M seed Apr 2023) | Qdrant GmbH (Berlin); ~$85M ($7.5M seed 2023, $28M A Jan 2024, $50M B Mar 2026) |
| Server image, compressed amd64 | 168 MiB (`chromadb/chroma:1.5.9`) | 74 MiB (`qdrant/qdrant:v1.12.4`), 67 MiB (`v1.18.1`) |
| Quantization / vectors-on-disk | none native — full-precision vectors stay resident | scalar int8 (~4×), binary (up to 32×), mmap'd on-disk vectors |
| REST API history | v1 → v2 breaking change; nested tenant/database paths; collections addressed by UUID | 1.x REST stable since 2023; flat paths; collections addressed by name |

Image sizes measured via the Docker Hub API on the survey date; the
rest from the projects' GitHub pages and the sources linked below.

### Popularity

Effectively tied, with different audiences. Chroma (28.2k stars) is the
tutorial default — `pip install chromadb` and an in-process store is
the first vector database most RAG walkthroughs reach for, and that
embedded mode drives enormous PyPI volume. Qdrant (31.7k stars) is the
*server* people reach for when the store runs as its own process —
which is the only mode pikuri uses either of them in. Both are safely
past the "will this be abandoned next year" bar.

### Age and track record

Qdrant is the older project: public since 2021, written in Rust from
day one, 1.x line since early 2023 with the REST surface stable since.
Chroma launched publicly in February 2023 and has had one major
architectural event since — the 1.0 Rust-core rewrite (2025), which
replaced the Python core ("[4× faster](https://www.trychroma.com/project/1.0.0)"
by their own announcement) and, earlier, a v1→v2 REST API break that
pikuri's Chroma client had to navigate by hand. Two data points,
same direction: Qdrant's wire surface has been the steadier one to
build a thin hand-rolled Faraday client against.

### License and open-source status

A wash. Both are Apache-2.0, VC-backed, open-core with a managed cloud
— and in both cases everything pikuri touches (the single-node server,
the REST API) is in the open-source part. Neither has pulled a
license-rug (relicense to BSL/SSPL) as of the survey date; both being
Apache-2.0 means a fork survives even if one does.

### Maturity

Both ship pinned, versioned server images and are used in production
broadly. The difference is positioning: Qdrant is built *as* a
standalone server — clustering, quantization, payload-filtered HNSW
traversal, snapshots are all in the OSS server. Chroma's center of
gravity is the embedded/developer experience, with the server mode and
Chroma Cloud growing out of it. For pikuri — which only ever runs the
server in a supervised container — Qdrant's priorities line up better.

### Performance

Internet numbers, not measured here (and vendor-adjacent — salt
accordingly): third-party 2025/2026 comparisons consistently put Qdrant
at [3–4× the RPS with lower latencies](https://aloa.co/ai/comparisons/vector-database-comparison/chroma-vs-qdrant)
on server workloads; Chroma's Rust core closed much of its *own* gap
(4× over its 0.x Python core) but didn't flip the ordering. Telling
detail: [Qdrant's official benchmark suite](https://qdrant.tech/benchmarks/)
compares against Weaviate, Milvus, Elasticsearch, pgvector, Redis —
Chroma isn't in the lineup, because it doesn't position itself as a
server-throughput contender.

Honesty clause: at pikuri's scale this is a tiebreaker, not a decider.
A personal corpus is 10³–10⁵ chunks; both engines answer top-k over
that in single-digit milliseconds.

### Memory footprint

At pikuri scale, negligible either way: a 768-dim float32 vector is
3 KB, so a 10k-chunk corpus is ~30 MB of vectors. Both servers are
Rust-core now, so neither drags a Python runtime; the measured image
sizes (74 vs 168 MiB compressed) still favor Qdrant ~2.3×.

The structural difference is headroom. Qdrant serves
[~1M 1536-dim vectors in ~1.2 GB](https://qdrant.tech/articles/memory-consumption/)
and can cut that ~4× with int8 quantization or page vectors from disk
via mmap. Chroma keeps full-precision vectors resident with no native
quantization — fine at 10⁴ chunks, the wall you hit first at 10⁷. No
pikuri user should hit that wall; it's listed because "what happens
when the corpus grows 100×" is a fair question for a default.

### Ease of setup

From pikuri's seat: identical. Both are exactly one pinned container,
one `127.0.0.1`-published port, one bind-mounted data dir, one HTTP
heartbeat — the two supervisors were near-mechanical clones. Chroma's famous
`pip install chromadb` embedded mode is Python-only and unreachable
from Ruby; pikuri's equivalent of that zero-setup tier is
`Backend::InMemory`, which stays the default regardless of this survey.

The one felt difference is client-side, from writing the Chroma client:
Chroma's v2 API nests collections under tenant/database path segments
and addresses them by UUID (name → id lookup first), and has already
broken compatibility once (v1→v2). Qdrant's REST is flat and
name-addressed — `PUT /collections/{name}`, `PUT .../points`,
`POST .../points/search` — and has held stable across the 1.x line.
A thin hand-rolled Faraday client (the audit-friendly shape both
backends use) has less to get wrong against Qdrant.

## Verdict: Qdrant; Chroma dropped

**Qdrant is the persistent backend** (`Backend::Qdrant` +
`Server::Qdrant`); **`Backend::InMemory` stays the educational
default.** Another engine is one more class behind the duck-typed
`Backend` protocol.

Why Qdrant, in pikuri-specific order:

1. **One engine across the monorepo.** `pikuri-memory`'s mem0 stack
   already runs Qdrant, verified end-to-end. Choosing Qdrant here
   means a user running memory + vectordb has one vector-database
   technology to learn, audit, and trust — and one image on disk —
   instead of two. (Instances stay separate; only the engine
   converges. Sharing one instance is a possible later step, gated on
   an assistant that wires both.)
2. **Wire-surface stability.** Qdrant's 1.x REST has been stable since
   2023; Chroma has one major API break on record. Pikuri hand-rolls
   its backend clients, so API churn is paid in pikuri's own code.
3. **Lighter and roomier.** Less than half the image size, and
   quantization + on-disk vectors as the growth story.

**Why not keep Chroma as a supported alternative** (it shipped as one
until 2026-11-15, ~540 lines + ~620 of specs, reachable only from
`pikuri-corpus --chroma`)? "Already written, costs nothing but its line
count" didn't hold: every `Backend` protocol change (`Chunker::Piece`
line ranges, `replace_source`) and every image bump was paid twice, and
Chroma is the engine whose API has already broken once. Its one asset,
name recognition from RAG tutorials, is worth a sentence in the book,
not a second engine — `InMemory` ↔ `Qdrant` already demonstrates the
swappable seam. A host that wants Chroma writes one more `Backend`
class, or recovers the old one from git history.

**Cross-gem pin invariant:** `Server::Qdrant::IMAGE` (this gem) and
`Pikuri::Memory::Mem0Server::DEFAULT_QDRANT_IMAGE` should reference the
**same tag** (currently `qdrant/qdrant:v1.12.4`), so the two stacks
share one image on disk. The gems don't depend on each other, so this
can't be one shared constant — it's a convention, recorded here and in
both constants' yardocs, bumped in lockstep. (v1.12.4 rather than
latest: it's the tag the mem0 path was verified against; bump both
together when there's a reason.)

Survey sources: [qdrant/qdrant](https://github.com/qdrant/qdrant),
[chroma-core/chroma](https://github.com/chroma-core/chroma),
[Chroma 1.0 announcement](https://www.trychroma.com/project/1.0.0),
[Chroma seed round](https://www.trychroma.com/company/seed),
[TechCrunch on Qdrant's Series A](https://techcrunch.com/2024/01/23/qdrant-open-source-vector-database/),
[Qdrant benchmarks](https://qdrant.tech/benchmarks/),
[Qdrant memory-consumption article](https://qdrant.tech/articles/memory-consumption/),
[aloa.co Chroma-vs-Qdrant comparison](https://aloa.co/ai/comparisons/vector-database-comparison/chroma-vs-qdrant).
