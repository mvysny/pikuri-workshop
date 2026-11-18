# pikuri-rag

Hybrid retrieval for the
[pikuri](https://github.com/mvysny/pikuri) AI-assistant toolkit: a
keyword index beside the vectors, so the agent can answer every kind of
question people ask about a pile of their own documents.

[`pikuri-vectordb`](../pikuri-vectordb/README.md) alone answers *"what
did we agree about the migration plan?"*. Two other questions need a
keyword index:

- **Completeness.** *"Every note mentioning Acme."* A vector search
  returns the top few hits, never all of them, so a timeline built from
  it can silently miss a note.
- **Exactness.** *"Invoice #4471."* Embedders rank ids and proper nouns
  poorly, so the note holding the literal string can lose to one that
  merely talks about invoices.

This gem keeps the same chunks in an SQLite FTS5 index as well and
merges the hits from both indexes into one ranking.

## Wiring

Your app builds one corpus per folder and gives each agent an extension
over it. Compared with `pikuri-vectordb`, the vector store gets wrapped
in a `Hybrid` beside a keyword store, and the extension class changes:

```ruby
require 'pikuri-rag'

corpus = Pikuri::VectorDb::Corpus.new(
  backend: Pikuri::Rag::Backend::Hybrid.new(
    vectors:  Pikuri::VectorDb::Backend::InMemory.new,
    keywords: Pikuri::Rag::Backend::Fts5.new
  ),
  source:   '~/notes',
  embedder: Pikuri::VectorDb::Embedder.new(server: ..., model: ...),
  private:  true,   # these documents are worth exfiltrating
  trusted:  true    # and every one of them is yours
)

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension Pikuri::Rag::Extension.new(corpus: corpus)
end

# Filling the index is up to you, as with pikuri-vectordb.
watcher = Pikuri::VectorDb::Watcher.new(corpus: corpus).start
```

`trusted: true` is a bigger claim than it looks: read
`Pikuri::VectorDb::Corpus#trusted?` before you make it about a
folder holding PDFs or shared with anyone.

You can't add both this extension and `pikuri-vectordb`'s to one agent.
Doing so raises an error, so the model never gets two search tools that
promise different things.

**Where the keyword index lives.** `Fts5.new` keeps it in memory; pass
`store:` an SQLite path to keep it in a file. Keep it in memory when the
vectors are in memory, and put it in a file under `Pikuri::Paths.cache`
when the vectors are in Qdrant, so both survive a restart. Any other
pairing still works, but every start re-embeds the whole corpus.

### One corpus per folder

Several agents reading the same folder share one corpus: build it once
and hand it to every agent's extension. Build two corpora over the same
folder and each one embeds every file again, and if their settings
differ, the index ends up mixing them. A different folder gets its own
corpus, with its own Qdrant collection and keyword file.

The corpus owns everything you hand it: closing it closes the vector
store, the keyword index and the stemmer. Closing an agent leaves the
corpus alone, since other agents may still be using it. A Qdrant
server is not part of the corpus, so close it separately; that takes
its container down.

Close things in the reverse order you opened them: first the watcher,
so nothing writes any more, then the agents, then the corpus, then the
vector server:

```ruby
watcher.close
agent.close
corpus.close
vector_server.close   # if you started one
```

## What you get

1. **`rag_search`**: the best five passages, found by both indexes and
   merged into one ranking, optionally re-sorted by a reranker. Each
   passage is cited as `source lines a-b`.
2. **`rag_search_keywords`**: *every* document containing all the
   words, anywhere in it, with the lines where they occur. Nothing is
   cut off.
3. **`rag_read`**: one indexed document in full, by its `source`.
4. **`rag_reindex`**: rebuild both indexes from disk.

The last two are `pikuri-vectordb`'s tools under a `rag_` prefix. How
the two indexes are kept in step is in the yardoc of
`Pikuri::Rag::Backend::Hybrid`.

## Other languages

Words are matched by their stem, so "meetings" finds "meeting". The
default stemmer is English. For another language, pass `stemmer:` to the
keyword index; Finnish ships in
[`pikuri-stemmers`](../pikuri-stemmers/README.md), whose README says
what to install:

```ruby
Pikuri::Rag::Backend::Fts5.new(
  store:   ...,
  stemmer: Pikuri::Stemmers::Voikko.new(Voikko.new(language: 'fi'))
)
```

Changing the stemmer of a saved index empties it at the next start,
and the next index run re-embeds every note. Why:
`design/decisions.md` `D_ruby_stemming`.

## Read more

The walk-through is the book's [RAG chapter](../book/rag.md).

## Install

```ruby
# Gemfile
gem 'pikuri-rag'
```

Pulls in `pikuri-vectordb`, `pikuri-core` and `sqlite3`, whose prebuilt
gem already includes FTS5, so the keyword index needs no extra service.

## Threat model

`pikuri-vectordb`'s, unchanged: the same `private:` / `trusted:`
declaration, no tool that sends anything out, and `rag_read` opens only
documents in the index. The keyword index is a second copy of the same
text, in an SQLite file owned by the same user. See
`pikuri-vectordb/design/architecture.md`.
