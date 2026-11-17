# pikuri-stemmers

Stemmers for [pikuri-rag](https://codeberg.org/mvysny/pikuri/src/branch/master/pikuri-rag/README.md)'s
keyword search, one per language. Out of the box pikuri-rag stems English only; a stemmer from
here lets "katu" find the note that says "kadulla".

Each stemmer runs over a language library you install and open yourself. This gem requires
none of them, so you install only the languages you use.

## Finnish: `Pikuri::Stemmers::Voikko`

Stems Finnish words to their dictionary forms and splits compounds, so a search for *kone*
(machine) finds a note about a *tietokone* (computer). English words in the same notes keep
their stemming.

Install `libvoikko1` and `voikko-fi` from your distro, then add both gems:

```ruby
# Gemfile
gem 'pikuri-stemmers'
gem 'voikko', '~> 0.2'
```

```ruby
require 'pikuri-rag'
require 'pikuri-stemmers'
require 'voikko'

Pikuri::Rag::Backend::Fts5.new(
  store:   ...,
  stemmer: Pikuri::Stemmers::Voikko.new(Voikko.new(language: 'fi'))
)
```

The stemmer closes the Voikko handle when the corpus that owns the keyword index is closed.

Switching stemmers on a saved index empties it at the next start, and the next index run
re-embeds every note.

## Threat model

pikuri-rag's, plus one addition: libvoikko, C code, reads every word of your notes and of
every search the model writes, inside the pikuri process. It sees one word at a time, and
SQLite already reads the same words in the same process, so this adds little. The argument
is `design/decisions.md` `D_voikko_stemmer`.
