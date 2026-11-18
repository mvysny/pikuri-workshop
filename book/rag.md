# Hybrid retrieval: the questions vectors can't answer

By the end of this chapter the [previous chapter](vectordb.md)'s agent
answers two kinds of question it couldn't, with one more flag:

```sh
./pikuri-rag/bin/pikuri-corpus --hybrid
```

and you'll understand what the flag adds: a keyword index sitting
beside the vectors. You've met a keyword index before. pikuri's file
index is one, and the vector-DB chapter traded it for meaning. Hybrid
retrieval keeps both, behind one tool call, and this chapter is about
what each half promises and how the two are fused.

## Two questions the vector DB cannot answer

The vector-DB chapter left you with a sentence worth re-reading:
*there is no keyword index underneath, no inverted file, no fuzzy
match — it's pure geometry over meaning vectors.* That geometry is
excellent at one question and structurally incapable of two others.

The question it answers is **relevance**: *"what did we agree with
Acme about the migration plan?"* Embed the question, return the five
nearest chunks, optionally rerank them. Nothing else in this book does
that better.

Now try these two.

**Completeness.** *"Show me every note that mentions Acme."* Vector
search returns the top *k* — a sample, by construction. You could
raise *k*, but to what? Cosine similarity has no calibrated zero: a
score of 0.31 means "somewhat related" for one embedder and one corpus
and something else for another, so there is no threshold you can
document as a promise. And this is not a mild imprecision. A brief
assembled from a ranked handful of notes is *quietly* wrong: the note
you didn't see is the commitment nobody remembers, and the agent has
no way to know it was missing.

**Exactness.** *"Which note has invoice #4471?"* Rare tokens — invoice
numbers, ticket ids, a customer's name, a product SKU — are precisely
what embedders rank worst. An embedder is trained to place *meanings*
near each other, and `4471` has no meaning; the note holding the
literal string can easily rank below one that merely discusses
invoices at length. This is the failure that feels like a bug the
first time you hit it, and it isn't one. It's the model doing exactly
what it was built to do.

Neither is a shortcoming to patch on the vector side. The field
settled this years ago: put a **keyword index** beside the vectors and
combine the two. That's *hybrid retrieval*, and it's what
`pikuri-rag` is.

## Two tools, two promises

`pikuri-rag` ships four tools, and the interesting split is between
the first two.

**`rag_search`** is the ranked answer, and it runs both legs:

- The **vector leg** embeds your query and pulls the 10 nearest
  chunks — the previous chapter's vector search.
- The **keyword leg** takes the same query, splits it into words, and
  asks the keyword index for the 10 best matches by
  [BM25](#bm25-in-one-paragraph).

Then it fuses the two lists and returns five results. So *"what did we
agree about pricing?"* still works through meaning, and *"invoice
4471"* now works through the literal token, from the same tool call.

**`rag_search_keywords`** is the *complete* answer, and it has no vector leg at
all. Give it a term and it returns **every** document containing it —
the `source` path, how many of its chunks matched and the line each
of them starts at, and the file's size:

```
3 documents contain all of: "acme" "pricing". Counts are how many of the document's chunks matched, not occurrences; lines are where each matching chunk starts.

acme-2026-08-14.md — 3 chunks (lines 1, 38, 77), 5.2 KB
acme-2026-07-02.md — 1 chunk (line 12), 1.8 KB
acme-2026-03-11.md — 1 chunk (line 1), 2.4 KB
```

Each line is a ready `offset` for `rag_read`, so in a long document
the agent reads from the match instead of from the top.

No cutoff, no top-*k*, and the tool's own description says so in those
words — because the promise is the whole point. A keyword match is
*boolean*: either the word is in the document or it isn't. That's what
lets this tool claim completeness where no amount of tuning could let
`rag_search` claim it.

The size is bytes and not lines, which is a small decision with a
reason: bytes cost one `stat`, where a line count means reading every
matching file end to end. And for anything the extractor converts —
a PDF, a DOCX — the file's newlines are *container* bytes, not the
text the model reads, so the number would disagree with the offsets
`rag_read` pages by. Bytes answer the only question the agent is
actually asking here, which is *is this short enough to read whole?*

The other two tools are `rag_read` (pull one indexed document into
context in full, by a `source` path either of the above printed) and
`rag_reindex` (build or rebuild the index). Those are
`pikuri-vectordb`'s own tools, registered under this gem's prefix —
same code, same membership gate, one different string in their name.

**Why two tools rather than one with a `mode:` flag?** Because they
make different promises with different output shapes, and a model
choosing between them by flag value is a model reading a parameter
description instead of a tool name. `rag_search` returns ranked
snippets; `rag_search_keywords` returns a complete listing. Those are two tools.

### The AND/OR split, which looks like an inconsistency

`rag_search` **OR**s the words in your query. `rag_search_keywords` **AND**s
them. Same corpus, same index, opposite operator — and both are right.

`rag_search` takes a natural-language question. *"What did we agree
with Acme about pricing?"* is eight words; ANDing them matches nothing,
because no chunk contains all eight. OR maximizes recall and BM25 does
the ranking — and BM25's inverse-document-frequency term already
discounts "what", "did", "we" and "about", which appear in every
document and therefore carry almost no score.

`rag_search_keywords` takes terms, and its promise is a *set*. If you ask for
"acme pricing", a set that includes every note saying "pricing" is not
the set you asked for. So the tool ANDs, and its parameter description
tells the model to pass one entity or a couple of words rather than a
sentence.

**And that AND is per document, which is not what you get for free.**
SQLite's full-text search has an implicit AND — write two words and it
requires both — but it evaluates that AND *within one row*, and a row
here is a chunk, not a document. So the obvious one-line query silently
omits a note whose "Acme" sits in its first chunk and whose "pricing"
sits in its fourth. That is not a corner case: under the default
512-token chunker, any note past a couple of kilobytes is several
chunks, so the obvious query fails on exactly the long documents a
corpus is made of — and it fails by returning *nothing*, which reads as
"no such note".

So `pikuri-rag` queries once per term and intersects the results by
`source`. Two words, two queries, and a document is listed when every
term appears *somewhere* in it. Worth dwelling on because it is the
shape of bug this whole tool exists to prevent: an answer that looks
like a confident "none" and is actually a missing row.

### BM25 in one paragraph

BM25 is the standard relevance score for keyword search, and it's
worth knowing what it rewards, because it's not "how many times does
the word appear". Three factors: **term frequency** (more occurrences
score higher, with diminishing returns — the tenth mention adds much
less than the second), **inverse document frequency** (a word that
appears in every document is nearly worthless; a rare word is
valuable), and **length normalization** (a match in a short note
counts for more than the same match buried in a long one). That last
one is why, in a two-note corpus where both mention pricing, the
shorter note ranks first.

Stemming happens before any of that. By default `pikuri-rag` uses
SQLite's built-in Porter stemmer, so "meetings", "meeting" and "meet"
collapse to one term and a search for the singular finds the plural.
Porter knows only English, and it works by chopping suffixes off. That
fails for a language like Finnish, where *katu* (street) is *kadulla*
"on the street" and *kadun* "of the street": the stem changes inside the
word. So `pikuri-rag` can stem in Ruby before SQLite sees a word, with
whatever stemmer you hand it. For Finnish, this repo's
`pikuri-stemmers` uses Voikko, a dictionary that *analyses* each word
instead and returns its dictionary form. It also splits compounds, so a
search for *kone* (machine) finds a note about a *tietokone* (computer).
The gem's README shows how to switch it on.

### Reciprocal rank fusion, and why not a weighted sum

You have two ranked lists. How do you merge them?

The tempting answer is a weighted sum of the scores: `0.7 × cosine +
0.3 × bm25`. Don't. Cosine similarity lives in `[0, 1]`. BM25 is an
unbounded corpus statistic whose magnitude depends on how many
documents you have and how long they are — in a two-document corpus
it's a millionth of a unit; in a ten-thousand-document one it's single
digits. Adding those two numbers is adding a percentage to a
temperature, and every weight you pick is a knob with no principled
setting.

**Reciprocal rank fusion** throws the magnitudes away and keeps only
what each leg is actually good at: the *ordering*. Each leg hands over
its top 10, and a chunk at rank *r* in a list contributes `1 / (5 + r)`
to its fused score, summed across the lists it appears in. So:

- Agreement between two different retrieval methods is evidence: a
  chunk both legs rank highly beats a chunk only one of them found.
- But only agreement *near the top*. A leg's rank-1 scores 1/6; a chunk
  both legs rank 10th scores 2/15, less. So one leg's confident first
  hit still beats the other leg's leftovers.

Most hybrid stacks ship `60` there instead, and fuse fifty results a
leg — the constant from the paper that introduced the method, which
fused many search systems at once. With two legs, one much stronger
than the other, it backfires: any chunk both legs mention *anywhere* in
their top fifty outscores the stronger leg's rank-1. Measured on a
corpus of Finnish statutes, that setting found the right section less
often than vector search alone; `5` over ten found it more often than
either leg. The numbers are in `design/decisions.md`, `D_rrf_tuning`.

After fusion, the optional cross-encoder reranker from the last
chapter runs over the fused candidates unchanged — it never knew where
its candidates came from.

## How the keyword index rides along

Here's the part worth understanding even if you never touch the code,
because it's the reason this gem is small.

`pikuri-rag` does **not** ship a second indexer. It ships two small
classes that compose:

```ruby
hybrid = Pikuri::Rag::Backend::Hybrid.new(
  vectors:  Pikuri::VectorDb::Backend::InMemory.new,   # last chapter's store
  keywords: Pikuri::Rag::Backend::Fts5.new             # the new one
)
```

`Fts5` is the keyword store — chunks in a SQLite full-text table, and
the only place in the gem that speaks SQL. `Hybrid` holds both stores,
fans every write out to the two, and keeps their reads separate for the
search tool to fuse.

To everything upstream — the corpus that walks your folder, the
watcher that reindexes on save, the read tool — `hybrid` simply *is* a
backend, because it answers the same methods. So the whole indexing
pipeline from the last chapter is reused byte-for-byte: one walk of the
folder, one text extraction per file, one content hash. Nothing
re-reads your files to build the keyword half:

```ruby
corpus = Pikuri::VectorDb::Corpus.new(backend: hybrid, source: '~/notes', embedder: embedder)
c.add_extension Pikuri::Rag::Extension.new(corpus: corpus)
```

The corpus is your folder plus its index: your app builds one per folder, hands it to
every agent that reads that folder, and closes it at the end, which
closes both stores.

And because both stores hold the same chunks, with the same ids and the
same `source` citations, fusion is textbook: both legs return the same
identifiers, so matching them up is a hash lookup rather than a
heuristic.

Two things fall out of that split worth noticing. A third index — a
graph store, a second keyword engine — is a third store handed to
`Hybrid`, not another wrapper around it. And the keyword store is
useful alone: a corpus with no embedder at all can be indexed into an
`Fts5` and searched by word, which is also why it can be tested without
a vector backend anywhere in sight.

The alternative — a `Rag::Indexer` that wraps SQLite plus the vectordb
corpus — was the larger cut and got rejected. It would re-read and
re-extract every file, and it would have to merge two "what's indexed?"
manifests. `design/decisions.md` `D_rag_gem` has the full comparison.

### "Indexed" means both stores hold it

Two of `Hybrid`'s methods don't simply delegate, and the reason is a
correctness invariant rather than tidiness.

Picture the failure it prevents. You run with Qdrant, so your vectors
persist across restarts. Your keyword index defaults to in-memory, so
it doesn't. You restart. The vector store says "I have 4,000 chunks,
nothing to do"; the keyword index is empty; `rag_search_keywords` returns nothing
for every query, forever, and never says why.

So `Hybrid` answers "what is indexed?" with the **intersection** of the
two stores' manifests, and a chunk count of `0` when *either* store is
empty. Now the restart goes differently — the watcher's boot sweep sees those 4,000
chunks' sources as unindexed, and reindexes them into both stores.
Slower, and correct.

`pikuri-corpus` walks you into the same situation on purpose: both
modes share one Qdrant collection, and the keyword file only exists
once you've run `--hybrid`. We ran the vector-only agent with
`--qdrant --watch` until the collection held this book, then
`--hybrid --qdrant --watch` over the same folder. The vector store was
full, the keyword file was new, and the watcher's first sweep
re-indexed all sixteen files into both, about thirty seconds, before
the first question.

The same rule quietly repairs a half-written pair. If a write lands in
the keyword index and the vector store's network call then fails, that
source drops out of the intersection and the next sweep fixes it.
Nothing has to be transactional across two stores.

It's also why the pairing guidance is guidance and not a check: pair
in-memory with in-memory, and a file under the pikuri cache with
Qdrant. Get it wrong and you're *correct*, just paying a full re-embed
at every boot — and nothing in `Hybrid` can tell whether the vector
store you handed it persists.

### Model text never reaches the query language

SQLite's `MATCH` operator takes a small query language of its own:
`AND`, `OR`, `NOT`, `*` for prefixes, `^` for anchors, `column:`
filters, phrase quotes, `()` and `{}` for grouping. Hand it raw model
text and a stray quote is a *syntax error*, not a query that finds
nothing.

So every expression is built by one small module, which splits the
text into runs of letters and digits and emits each one as a quoted
phrase term. `acme OR initech` becomes `"acme" "or" "initech"` — three
literal words, one of which happens to be spelled "or". The operators
are never exposed, deliberately: "Acme *or* Initech" is two
`rag_search_keywords` calls, and the model doesn't get a query language to
misuse. If nothing survives the split — the model passed `???` — the
tool says "no searchable terms" and the database is never touched.

## The demo: one flag, the same corpus

The previous chapter's agent, with the flag:

```sh
./pikuri-rag/bin/pikuri-corpus --hybrid
```

Same corpus, the same Qdrant collection if you add `--qdrant`, the same
no-egress rule. Only the tools change:

```
Trifecta: pikuri-corpus — 1 of 3 legs (untrusted); no private/egress leg found.

pikuri-corpus [:untrusted_hard]
  calculator []
  rag_search [:untrusted_hard]
  rag_search_keywords [:untrusted_hard]
  rag_read [:untrusted_hard]
  rag_reindex []
```

Ask both agents a completeness question this book can check with
`grep`: *"Which chapters of the workshop book mention pasta? List every
one."* Before this section was written the answer was five: `shell.md`,
`mcp.md`, `mcp-revisited.md`, `memories.md` and `code.md`. In all five
it's `pasta`, the tool that gives a cage a loopback of its own, and
`memories.md` also suggests a pasta dinner. (This chapter makes it six.)

**Vectors only.** The agent searched for "pasta", read three of the
chapters its five hits came from, searched once more, and answered
with two: `shell.md` and `code.md`. It had seen `memories.md` and
`mcp-revisited.md` among its hits and dismissed them as "embedding-based
false positives … no literal mention of 'pasta'". Both mention it.
`mcp.md` never came up at all. Halfway through, the model even wrote
down what it lacked: *"Since I can't grep, let me read the remaining
relevant portions."*

**Hybrid.** `rag_search_keywords` with the one word `pasta` answered
`Found 5 documents`. The agent read the matching lines of each, listed
all five, and told the networking tool from the dinner.

An exact token goes the same way, only more quietly: *"What listens on
port 8888, according to the workshop book? Name every chapter that
says."* Two chapters do, for two different listeners: mem0's front door
in Memories, and the egress proxy in MCPs revisited. Both agents got it
right. The vector agent got there in fifteen calls after the index,
ten searches and five reads, three of them whole chapters (1,638 lines)
read only to make sure nothing else said 8888: a number has no meaning
to be near. The hybrid agent asked `rag_search_keywords` for `8888`,
got `Found 2 documents`, and was done in six.

That is one run per question, so it shows what happens, not how often.
The mechanism is the point. The vector agent wasn't careless: asked for
a set, it was handed a ranked sample, and nothing in five good hits
could tell it the set was larger. So it either stops short, as with
pasta, or reads whole chapters to make sure, as with 8888.

## What's next

You now have both halves of corpus retrieval: the vector primitive and
the hybrid system on top of it, over a corpus you chose and indexed.
[Memories](memories.md) is the other half of recall. Not a corpus you
handed the agent, but notes it takes about you on its own, with the
same embedder and the same Qdrant image underneath.

→ Continue to [Memories](memories.md).
