# Three cheap borrows from grok-build — one yes, one no, one chore

Status: **idea, not built.** Fallout from the grok-build survey
(`design/research.md`, `pikuri:R_available_tools` and `pikuri:R_tool_descriptions`).
These were flagged there as the three cheapest borrows; grounding them
against the actual code changed two of the three verdicts, so this note
is as much a correction as a proposal.

| # | Borrow | Verdict |
|---|---|---|
| 1 | Unicode confusable handling in `Edit` | **Yes — but diagnose, don't repair** |
| 2 | Sparse line-number anchors in `Read` | **No — collides with a decided, externally-confirmed trade** |
| 3 | Interpolate caps from the enforcing constant | **Yes, mostly a chore — with one real question inside** |

---

## 1. Confusables in `Edit`: diagnose, don't repair

**The failure.** Text pasted from a chat app or a word processor carries
typographic Unicode — `'` U+2019 for `'`, `—` U+2014 for `--`, `…`, NBSP
— that renders *identically to ASCII* in a terminal. {Pikuri::Workspace::Read}
shows the model a line that looks like ASCII; the model sends back an
ASCII `old_string`; {Pikuri::Workspace::Edit} matches byte-for-byte and
fails. The model then re-reads the file, sees the same thing, and sends
the same bytes. Nothing in the error tells it what's wrong, because
`"old_string not found … re-read with the read tool if uncertain"` is
advice that cannot work here.

**Not the Sanitizer's set, and don't merge them.**
{Pikuri::Sanitizer} already handles hostile Unicode — bidi overrides,
zero-width, control bytes, mixed-script homoglyphs. That set is about
*deception*, and the response is neutralize-and-warn. This set is about
*accident*, and the response is "your bytes are fine, the file's aren't."
grok-build keeps its map deliberately narrow for exactly this reason,
excluding `U+2212 MINUS` and `U+00D7 MULTIPLICATION` because they carry
meaning. Two sets, two purposes; folding them into one table would make
the Sanitizer warn about smart quotes and make `Edit` "repair"
homoglyphs. Keep them apart.

**Why *repair* is the wrong half to copy.** `Edit` normalizes CRLF today
by rewriting the whole file (`edit.rb:174–206`): `content` is
LF-normalized, the splice happens there, and `final` re-applies CRLF
everywhere. That is safe for line endings because a file is uniformly
CRLF or not. It is **not** safe for confusables, which are sprinkled:
normalize-edit-writeback would silently convert every smart quote in the
file to ASCII and slip the mass rewrite past {Pikuri::Workspace::WriteGate}
under a `"1 occurrence"` label. Doing it properly needs grok-build's
byte-offset remap — match in a normalized copy, splice into the
*original* bytes — which is precisely the machinery the CRLF path avoids.

**So invert it.** On a zero-match, retry the match against a
confusable-normalized copy. If *that* matches, **do not edit** — return
an error naming the culprit:

```
Error: old_string not found in lib/foo.rb, but it matches except for
typographic Unicode: line 42 has ' (U+2019 RIGHT SINGLE QUOTATION MARK)
where you sent ' (U+0027). Copy the bytes from the file, or use
replace_all on a substring that avoids them.
```

This costs one extra normalized `include?` on a path that has already
failed, touches no write path, needs no remap, and keeps the
byte-for-byte doctrine `pikuri:D_single_hunk_edit` is built on. It turns a
mystifying loop into a self-correcting one, which is the whole value —
the repair was never the point.

**Open:** does the same diagnosis belong on `Grep`'s zero-hit path? Same
failure (a pattern that can't match bytes the model can't see), same
cheap check. Probably yes, and it argues for a shared
`Pikuri::Confusables.explain(haystack, needle)` helper rather than a
private method on `Edit`.

---

## 2. Sparse line-number anchors in `Read` — rejected, and it was already decided

The borrow: grok-build prints its `LINE→` prefix on the first line and
every tenth thereafter ("count from the nearest anchor"), not on every
line. Same addressability, a fraction of the tokens.

**Pikuri already looked at this and said no**, in
{Pikuri::Workspace::Read}'s own yardoc (`read.rb:11–20`): the `"%6d\t%s"`
cat-n shape is chosen for **training-data familiarity** — `cat -n` is
everywhere, so even small local models recognize it — over opencode's
cheaper `"<n>: "` and pi's numberless output. And the clincher:

> The numbering and DESCRIPTION's read-a-larger-window nudge were
> confirmed as a pair by an outside-model review (Grok 4.6, 2026-08) —
> don't trade either back for tokens.

So the format was reviewed by *Grok*, and Grok told pikuri to keep it —
while the product Grok ships does the opposite. That is not a
contradiction, and the reason it isn't is the generalizable nugget:

> **A first-party model vendor can tune the model to the format; a
> harness has to meet the model where it already is.** grok-build can
> ship any encoding it likes and teach its model to read it. Pikuri
> targets small local models it will never train, so familiarity is a
> feature it is buying, not a token cost it is failing to notice.

That test is worth applying to *every* future grok-build borrow, which
is the main reason this note exists. It also retro-justifies why the
description templates (`pikuri:R_tool_descriptions`) transfer while the
parallel toolsets don't.

**Action:** none — `design/research.md` records the rejection and the
vendor-vs-harness test under `pikuri:R_available_tools`.

---

## 3. Interpolate caps from the constant that enforces them

The convention exists in-tree and is followed *most* of the time —
{Pikuri::Code::Bash}'s `timeout`, the three `thunderbird_*` searches,
both `fileindex_*` tools, and `read`'s `limit` all interpolate. Three
tools type the number by hand:

| Tool | Description says | Enforced by |
|---|---|---|
| `fetch` | `'Defaults to 5000; hard-capped at 100000.'` | `DEFAULT_MAX_CHARS` / `MAX_MAX_CHARS`, via `.clamp` (`fetch.rb:16,20,63`) |
| `web_scrape` | `'Defaults to 20000; hard-capped at 100000.'` | `DEFAULT_MAX_CHARS` / `MAX_MAX_CHARS`, via `.clamp` (`web_scrape.rb:14,18,45`) |
| `web_search` | `'Defaults to 10; most providers cap this at 20.'` | *nothing* — `max_results: 10` is a literal in the `execute` lambda |

The first two are a pure chore: the constants exist, they are already
what `.clamp` enforces, and `web_scrape` even interpolates
`WebScrape::DEFAULT_MAX_CHARS` in its `execute` default two lines below
the hand-typed description. Same file, both styles. Fix by
interpolation, no new constants.

**`web_search` is the one with a question in it.** There is no cap to
interpolate, and `"most providers cap this at 20"` is not a pikuri
constraint at all — it is unverified prose about third parties, stated
in the register of a limit the tool enforces. Two things to decide:

- Extract `DEFAULT_MAX_RESULTS = 10` and interpolate (trivially right).
- Then either **enforce** a cap (`.clamp`, mirroring `fetch`) and
  describe *that*, or **drop the "20" sentence** — because a number the
  tool doesn't enforce and can't verify is worse than no number: it
  reads as a contract, and the failure it invites (asking for 50,
  silently getting whatever the engine returns) is invisible. Leaning
  toward clamping, since {Pikuri::Web::Search} fans out over
  engines with different ceilings and the model shouldn't have to know
  which one is wired.

---

## Graduation

Landing any of these means backporting per `AGENTS.md`'s map, then
deleting this file:

- **#1 shipped** → the diagnose-don't-repair rationale is per-symbol
  truth: {Pikuri::Workspace::Edit}'s yardoc. The *rejected* repair arm
  (with the mass-rewrite trap that killed it) is a genuine fork →
  `design/decisions.md`.
- **#2** is already decided and documented, and `design/research.md` now
  carries both the rejection and the vendor-vs-harness test where the next
  survey will re-read them → nothing left to backport.
- **#3 shipped** → nothing to backport for `fetch`/`web_scrape` (a chore
  leaves no rationale). The `web_search` cap decision is a fork if it
  goes the enforce route → `design/decisions.md`; if it just deletes the
  sentence, the yardoc carries it.
