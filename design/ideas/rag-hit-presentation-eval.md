# Does how `rag_search` presents a hit change which one the model picks?

Started 2026-11-16. Before dropping `(score=…)` from `vectordb_search` and `rag_search`, the
alternatives were measured on the model itself, since a retrieval eval only says whether the
gold is *in* the list, never whether the model picks it.

**Outcome (2026-11-16, owner accepted Ornith's results).** Hits print no score, no labels; the
fused top 5 keeps its RRF order. Cosine, per-leg labels, the 10+10 union and a pinned vector #1
are rejected with their numbers in `D_rrf_tuning`, and the score drop is committed. What's left
here is deferred, not open for today: whether a small model, or Ornith thinking, leans where
instant Ornith didn't (`Q_small_model`, `Q_thinking_labels`). Graduate by deleting this file and
its sidecar once those are run or dropped; the numbers already live in `D_rrf_tuning`.

The variants:

| Variant | What the model sees per hit |
|---|---|
| `none` | fused top 5, rank only — the working tree |
| `cosine` | fused top 5, `(cosine=0.66)` |
| `labels` | fused top 5, `— meaning #4, keyword #1` |
| `union10` | each leg's top 10 interleaved, header `Found 18 matches: 10 by meaning, 10 by keyword (2 found by both)`, each hit `meaning #r` and/or `keyword #k 'word', 'word'` |

**Decision rule.** A tie goes to the simplest: no score, no labels, fused top 5. `union10` at
about twice the tokens loses on a tie. With one sample per question, a gap of 1–2 of 41 is noise;
about 4, or consistently fewer tool calls, is a signal.

## Findings so far

Corpus: `../courts` (4 Finnish acts, 165 chunks, bge-m3, Voikko-stemmed FTS5, 41 questions in
`../courts/eval/questions.yml`), served by the host's llama-server.

- **Retrieval ceiling of `union10`.** ~16 hits, ~9.1 KB per call against ~2.8 KB for the fused
  top 5. Gold among the hits: 38/41 against 37/41. The one it adds is "työaikalain 5 luvun 19 §"
  (keyword #9, vector #33). The three misses sit past #10 in both legs, so no presentation of
  10-deep legs reaches them.
- **The keyword leg rarely rescues.** In 1 of 41 questions it had the gold in its top 10 where the
  vector leg didn't.
- **Cosine has no absolute meaning.** Over every question and rank to #50, bge-m3 cosines sit in
  0.42–0.76; a correct #1 scored 0.51, below another question's #50 (0.59).
- **But the gap at the top is a signal.** Where #1 led #2 by more than 0.045, #1 was gold in
  12/12; all 12 questions whose gold wasn't #1 had a flat top (≤ 0.03). This holds only in cosine
  order (`vectordb_search` without a reranker); on a fused list the cosines aren't monotone
  (0.60, 0.59, 0.61, 0.61, 0.55).
- **Matched-word labels are noise with Voikko.** Query words like 'voinko' and 'jos' match nearly
  every chunk, so `keyword #2 'voinko', 'töistä', 'jos', …` says little.
- **Full agent loop, Ornith-1.5: no lean, stopped.** 11 runs over the first 3 questions; every one
  cited the gold. `union10` used ~9.9k input tokens against ~5k. Ornith covers for weak retrieval
  through each act's table of contents: on TSL 6:3 neither leg had the gold in its top 10 and it
  still cited it. Too capable to show a presentation effect, and ~5 min a question.
- **Pick-the-hit test, Ornith with thinking off** (`chat_template_kwargs.enable_thinking: false`,
  the cheap stand-in for a weaker model): one search result per question, "which hit answers
  it?", no loop, no reading, 3 repeats, 492 picks. **A tie.**

  | Variant | Right | Gold #1: right | Gold below #1: right | No gold: said "none" |
  |---|---|---|---|---|
  | none | 91/123 | 53/60 | 38/51 | 4/12 |
  | cosine | 91/123 | 54/60 | 37/51 | 5/12 |
  | labels | 91/123 | 56/60 | 35/51 | 2/12 |
  | union10 | 98/123 | 79/87 | 19/27 | 0/9 |

  Per question the three fused variants agree almost everywhere: each of the 17 hard questions
  (gold below #1) is solved by all three or by none, but for four that differ by one or two
  repeats, in no direction. The snippet decides the pick, not the number beside it.
  `union10`'s edge is ordering, not its labels: interleaving puts the vector leg's #1 first,
  which is gold more often (87 of 123 against 60), and its accuracy at a given gold position is
  no better; it never says "none", and costs ~3× the context. A fusion-order observation, not a
  presentation one.
- **Pick-the-hit test, Ornith with thinking on** (output capped at 8k tokens), the 17 hard
  questions only, 1 repeat: `none` 12/17, `cosine` 14/17, `labels` 15/17. A lean toward the
  annotations, opposite to the thinking-off tie, but one sample: on the non-compete question
  `none` missed here and was right in all three thinking-off repeats. Perhaps a thinking model
  reasons about "meaning #1, keyword #4" where an instant one doesn't; two more repeats (102
  picks, ~30 min) or a small model would tell.
- **Vector #1 pinned first (`vfirst`)**, union10's one edge at the fused list's cost — the same
  hits, reordered. Retrieval (`rank.rb`, no model): top-5 37/41 as fused, gold at #1 29/41
  against 20, MRR 0.77 against 0.63. Picks, thinking off: 93/123 against `none`'s 91 — noise.
  The model already reads past #1 (finds a lower gold 38/51 under the fused order); pinning wins
  where the vector #1 is gold (83/87) and loses as much where it isn't, the model now trusting a
  wrong #1 (10/24 right). Owner's question was whether to keep union10's order or just "a cosine
  result first"; neither buys a measurable answer here. Belongs in `D_rrf_tuning`'s rejected
  alternatives on graduation.
- **Side finding: a killed client doesn't stop the server.** After the agent run was stopped, two
  of its non-streamed requests kept generating on llama-server for 11k+ tokens each (no
  `max_tokens`, so a thinking loop runs unbounded), holding two of Ornith's four slots and
  slowing everything behind them; only unloading the model ended them. The same holds for
  pikuri: Ctrl+C on a non-streaming agent leaves the GPU busy. Not this idea's question, but
  worth its own look.

## Open questions (deferred)

- `Q_small_model` — does a small model show the lean Ornith hides? Needs a ~4B chat model on the
  host; suggested `unsloth/Qwen3-4B-Instruct-2507-GGUF` Q4_K_M (no thinking step to cover with).
  Run: `THINK=off pick.rb <its id> pick-qwen4b.jsonl 3 none,cosine,labels,vfirst`. A clear win
  for `labels` or `cosine` (≥ ~10 of 123) would reopen the no-score decision.
- `Q_thinking_labels` — is thinking-on Ornith's 15 vs 12 (labels vs none) real? Two more
  repeats: `HARD=1 pick.rb Ornith-1.5 pick-ornith-hard.jsonl 3 none,cosine,labels`, ~30 min.

Answered: `Q_pick_ornith` (no variant raises instant Ornith's picks), `Q_cosine_back` (no),
`Q_labels` (no, unless the deferred two say otherwise), and the owner's "keep union10's order,
or just a cosine result first?" (neither — `vfirst` above).

## Files

`rag-hit-presentation-eval/` beside this file — the scripts and every result so far. Run from that
folder on the courts bundle (`BUNDLE_GEMFILE=/home/mavi/work/my/courts/Gemfile bundle exec ruby
…`); each reads the server from `~/.pikuri-examples-config.yaml`.

- `agent-eval.rb OUT_DIR [N] [VARIANTS]` — full agent loop, resumable; `summarize.rb OUT_DIR`
  re-scores the citations (the run's own matcher missed Markdown bold).
- `pick.rb MODEL OUT.jsonl [REPEATS] [VARIANTS]` — the pick test, resumable; `THINK=off`,
  `MAX_TOKENS=n` (default 8000) and `HARD=1` (gold below #1 only) as environment.
  `python3 tally.py FILE…` scores it. Variant `vfirst` (fused, vector #1 pinned) is there too.
- `rank.rb` — retrieval ranks without a model: vector leg, fused, `vfirst`.
- `results/` — `full/` (the stopped agent run), `pick-ornith-nothink.jsonl`,
  `pick-ornith-hard.jsonl` (thinking on), `pick-ornith-early.jsonl` (39 thinking-on picks from
  the clogged first attempt).
- `PREVIEW='a question' … agent-eval.rb` prints what each variant shows the model.
