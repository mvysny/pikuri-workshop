# Bash confirmer: deferred work beyond the passive-command detector

Status: **deferred brainstorm** — design space mapped, not scheduled.
This note collects the deferred bash-confirmation-gate ideas, born on the
OS agent's confirmation-fatigue list. Four so far — three on the **volume** axis (fewer, more
meaningful prompts), one on the **comprehension** axis (understand the
prompts that remain):

1. **Session-sticky / always-allow grants** (volume) — let the human
   vouch for a command this session. The bulk of this note (through
   "Recommendation").
2. **Subcommand-aware read rules** (volume) — extend the allowlist's
   subcommand recovery to more mixed read/mutate binaries. A direction
   only; the concrete candidate this note once carried (hardware-SMART
   reads) has shipped.
3. **Batching** (volume) — collapse several queued confirmations into
   one prompt.
4. **AI translation aid** (comprehension) — explain a command in plain
   language beside it. The final section.

All build on {Pikuri::Code::Bash::PassiveCommandDetector} — the
predicate {Pikuri::Code::Bash} consults as its `passive_detector:`, which
already handles fatigue for commands it can *prove* read-only — and all
obey the same governing invariant (stated in "The invariant" below):
**code and the human decide — an LLM may *translate*, never render the
✓/⚠ verdict.**

## Related

- [The OS-assistant chapter](../../book/os-assistant.md) §"Confirmation
  fatigue — the passive-command detector" — what already ships; the
  OS-helper is one of the two agents that would use this note (the coding agent is the other, and the likelier winner — see
  below).
- [`more-confirmers.md`](https://github.com/mvysny/pikuri/blob/master/design/ideas/more-confirmers.md) — the sibling
  confirmer questions still open (structured `Request` context, the
  ingest gate). That file is the **what-to-show / where-to-gate**
  axis; this note is the **fatigue +
  comprehension** axis (*how often* we ask, and *how well* the human
  understands what they're approving). Kept distinct on purpose.
- {Pikuri::Code::Bash::PassiveCommandDetector} — the static allowlist
  this extends; the design below reuses its `Tokenizer` +
  `segment_passive?` discipline wholesale.
- {Pikuri::Workspace::Confirmer} — records the **rejected**
  `:once/:always` scope knob; the "invariant" section below is why
  session grants are a different animal, not that knob resurrected.

## The problem

Fatigue is a **security** concern, not UX (see
{Pikuri::Code::Bash::PassiveCommandDetector}'s "why fatigue is a security
concern"): a user who has clicked "yes" forty times this session has
stopped reading, so the injected forty-first prompt gets rubber-stamped.
The allowlist's whole job is to make prompts **rare and meaningful**.

Bash sits at the **weak end** of the confirmer-strength spectrum
(pikuri's [security chapter](https://github.com/mvysny/pikuri/blob/master/book/security.md)
§"The human gate, and why fatigue is the enemy") on *two* compounding axes at once: it's both **high-frequency**
(the fatigue above) *and* **low-legibility** (a human often can't tell
what a pipeline does), so even an un-fatigued bash approval is a weaker
barrier than a rare, fully-legible one like email compose. That double
weakness is exactly why bash needs the fatigue-cutting machinery this note
collects, where a self-evident action like sending an email leans on the
human gate directly.

`PassiveCommandDetector` handles fatigue for commands it can *prove*
read-only, and it keeps absorbing more cases (the `journalctl` example
the OS-helper note once used for "session grants" is now stale — it
shipped in the flag denylist). But one residue can **never** join a
static allowlist, by construction: **commands that execute arbitrary
project code** — `pytest`, `cargo build`, `npm test`, `make`, `./run.sh`,
`bundle exec rspec`. None can join `PASSIVE_BINARIES` (whose curation
rule is "no mutating form in *any* argument"), yet a real coding /
diagnosis loop runs them dozens of times a session and each one prompts.

These are safe **by the human's judgment of this session**, not safe
**by proof**. That is the gap: the allowlist encodes universal proofs; it
has no way to encode "I, the human, vouch for `pytest` in *this* run."
The missing capability is turning a one-off approval into a
session-scoped standing rule.

## The danger

A session grant is a **standing capability that later untrusted content
can ride**. Once "always allow `pytest`" is in place, a *subsequent
injected* command that matches it auto-approves silently — the exact
rubber-stamp the mechanism fights, just deferred. Three things decide
whether that is survivable:

1. **Granularity is the whole ballgame.** "Always allow *this exact
   string*" is safe-ish but nearly useless (args vary). "Always allow the
   binary `git`" re-opens `git reset --hard`; "always allow `find`"
   re-opens `find . -delete`. A grant is only as safe as the matcher it
   compiles to, and a loosely-specified grant silently re-imports the
   mutating forms the allowlist was curated to *exclude*.
2. **Composition.** If a grant applies to anything but a
   metacharacter-free simple invocation, `granted-cmd && evil` rides it.
3. **TOCTOU on the executed bytes.** *Every* text-keyed grant — even an
   exact-string one — pins the command *text*, not the *code that text
   executes*. `./run.sh` is the same string tomorrow with different
   bytes; `pytest` re-reads `conftest.py`; `make` re-reads the Makefile.
   So a grant is a **capability grant** (trust the binary for the
   session), never a **safety proof**. This is why Option A below is not
   the "provably-safe floor" it first appears to be.

## The invariant, and the rejected-knob reconciliation

Two documented positions look like they collide:

- This note wants session grants in Claude Code's shape:
  **deterministic rules + user-granted session approvals, no LLM in the
  yes/no.**
- {Pikuri::Workspace::Confirmer} **rejected** the `:once/:always` scope
  knob — "the long-term answer to fatigue is making confirmations rare
  (sandboxing, `--yolo`), not smarter approval modes."

They reconcile once you see they name different things — and the
predicate/confirmer split makes the reconciliation *structural*, not just
rhetorical. What the yardoc killed was a *scope knob baked into the
confirmer's return* — making the `Confirmer` protocol cleverer about
saying yes. What this note wants is a **deterministic rule layer inside
{Pikuri::Code::Bash::PassiveCommandDetector}**: the human authors a rule,
*code* matches it. That layer lives in the `passive_detector` predicate —
a different object from the `Confirmer` entirely — so it is the same
category as the static allowlist, just runtime-populated, and it cannot
touch the confirmer protocol even in principle. Not a smarter approval
mode.

So the governing invariant, which this note owns for every item in it:
**AI may
*translate* a command, but code and the human *decide* — never an AI
✓/⚠ verdict.** The grant must originate from a *human keystroke*; an LLM
proposing "add this to the allowlist" would be exactly the AI-approver
anti-pattern. Concretely, three constraints keep this on the right side
of the rejected knob:

1. **Human-authored** — a grant is recorded only on an explicit human
   keystroke, never inferred.
2. **No widening past the simple-invocation gate** — a grant is honored
   only for a metacharacter-free, bare-name simple segment (reuse
   `segment_passive?`), so it can never be composed.
3. **Session-only, in-memory, never persisted** — a persisted grant
   outlives the human's attention and becomes a config-file attack
   surface; the OS-helper is "start fresh each session" anyway.

## Options

**A — Exact-command-string grants.** "Don't ask again for *this exact
normalized string*." Marketed as the provably-safe floor — but the TOCTOU
point above kills that claim: the string is pinned, the executed bytes
are not. Strip the false safety and A is just the *brittle* option
(`pytest tests/a` ≠ `pytest tests/b`, near-zero hit rate). Not worth
building on its own.

**B — Binary-scoped grants, gated by the existing `Tokenizer`
(recommended if ever built).** The human grants `pytest`; it joins a
**session grant-set** that the same `segment_passive?` discipline
consults, so it is honored only for a metacharacter-free, bare-name
simple invocation — `pytest && rm -rf` still delegates. Reuses all the
machinery already there; the only new thing is a user-populated set
beside the static one. Honest difference from `PASSIVE_BINARIES`: a
granted binary carries **no "no mutating form" guarantee** — it is a
capability grant (Claude Code's `Bash(pytest:*)` model), and the human
must understand they are handing that binary its full power for the
session. The metacharacter-free gate is what stops it composing; the
session scope bounds the window.

**C — Structured patterns (`git commit:*`).** B generalized to
subcommand + prefix. More expressive, more rope, and the pattern language
becomes its own attack surface (users will mis-specify). Defer until B
proves insufficient.

## Architectural fit — no protocol change

The clean shape falls out of the predicate/confirmer split and reopens
no return type:

- A **shared, in-memory, session-scoped grant-set**.
- The **matcher** is a small addition *inside*
  {Pikuri::Code::Bash::PassiveCommandDetector}: `segment_passive?`
  additionally consults the grant-set, so a granted bare name approves a
  simple segment. It must live *inside* the approver, **not** as a
  sibling predicate OR'd beside it — the whole-line safety (the
  `Tokenizer` parse plus the "every segment read-only" quantifier) is a
  *conjunctive gate* a granted command must clear too, and re-running
  that gate in a second matcher is exactly how a bypass slips in. (Same
  lesson that keeps the static rules one parse-based predicate rather
  than one-approver-per-command.)
- The **chrome** (`Confirmer::Terminal`) offers a third answer on an
  otherwise-declined prompt — `[y] yes  [a] always (this session)
  [n] no` — and on `a` **mutates the shared grant-set directly**.

`Bash` already orchestrates the two in the right order:
`passive_detector` first (now reading the grant-set), and only on a miss
the human `Confirmer` — whose `[a]` keystroke feeds the grant-set the
approver reads next time. Because approver and chrome hold a reference to
the *same* object, the "always" keystroke needs **no new `Approved` case
and no `remember:` flag** — the confirmer return type stays exactly
as-is. Better still, the grant now lives in the `passive_detector`
predicate, a different object from the `Confirmer` altogether, so this
can't resurrect `:once/:always` *by construction* — not merely by the
discipline of "it's a side-effect, not a return value."

## Recommendation, and why it's deferred

If built: **Option B**, under the five constraints above
(human-authored · simple-invocation-gated · session-only · in-memory ·
shared-object side-effect). It is a small add given the `Tokenizer` and
`segment_passive?` gate already exist inside the detector.

Deferred anyway, because:

- **The OS-helper barely needs it.** Its repetitive commands are mostly
  read-only queries the static allowlist already covers; the
  build/test/mutate residue that grants would help is small there.
- **The coding agent is the real customer** (`pytest`, `cargo build`,
  `git commit` loops), so this should be scoped when a real
  `pikuri-code` session shows the residue biting — not speculatively.
- **The residual is real and must ship documented** when it does: a
  grant is a standing capability a later injection can ride; session
  scope bounds the window, the simple-invocation gate bounds
  composition, and granularity + the TOCTOU-on-bytes truth are the
  human's explicit, informed choice.

## Subcommand-aware read rules

Extend the allowlist's existing subcommand recovery — the way
{Pikuri::Code::Bash::PassiveCommandDetector} already carves the read-only
query subset out of mixed binaries (`dpkg`/`apt`/`systemctl`/`nvme` by
leading subcommand, `dmesg`/`journalctl` by flag denylist, `smartctl` by
flag *allowlist*, `git` under `allow_git:`) — to further binaries still
delegated whole.

Every concrete candidate this note has ever named has since **shipped**
(`systemctl status`, read `journalctl`, and the `nvme`/`smartctl` SMART
reads — that last one built as spec'd: verb immediately after `nvme`,
`smartctl` classified by a flag allowlist so `-l` and the mutators
abstain, both kept off the glob fast path). What remains is the general
direction — each new mixed binary is a hand-audited entry, added only
when a real session shows it prompting often enough to matter.

The hard part, and why it stays deferred rather than "just add more
verbs": a "read" verb can still **execute config-directed code** — the
lesson `git` taught (a bare `git status` runs `core.fsmonitor`; closed
only by `Bash::GIT_HARDENING`). So a candidate binary earns an entry
only after its read verbs are shown to have no such vector, or the
vector is hardened the way git's was. Deny-by-default holds throughout:
an un-audited binary keeps delegating to the human.

## Batching

Collapse several queued confirmations into a single prompt — when the
agent emits a run of mutations (or the passive-command detector passes
some and leaves three that need a human), present them together rather
than one modal at a time. Pure prompt-*volume* reduction; the decision
stays per-command.

The invariant still binds: batching changes *presentation*, never *who
decides* — no "approve all" that becomes a rubber-stamp, and each
command's raw bytes stay individually visible and individually sanitized
(the human may approve a subset). The open part is UI-shaped — how a
terminal renders a multi-item approve/reject without losing the
sanitizer's per-item warning gating — a `Confirmer`-chrome concern, not
one for the passive detector's pure-code predicate.

## Permission-model granularity — the broader wishlist

`Confirmer::Terminal` is binary today (approve / deny per call). The
real-world ergonomics push, beyond the session-grant mechanism above:

- **Per-tool, per-pattern stickiness** ("always allow `git status`",
  "always allow read under `./src/**`"). This is the general form of
  the session grants worked out above (Options A–C) — those cover the
  bash-binary slice; the wishlist extends the same shape to read/glob
  path globs and to the other tools.
- **Risk tiers** — read light, write medium, bash heavy, unknown-host
  fetch heavy. A tier could pick the default answer / how loud the
  prompt is, rather than every call being flat.
- **Dry-run preview for `Bash`** (echoed argv, no shell-metachar
  surprise) — the deterministic cousin of the AI translation aid below.
- **Time-bound approvals** ("for this session only" — implicit on
  session boundaries). The session-only constraint above is the
  in-memory realization of this; a longer-lived grant would reopen the
  persistence attack surface the grant design deliberately refuses.

Risk to weigh, cutting across all four: **every persisted approval is
past-you trusting future-you's judgment, which prompt injection can lean
on** — the same standing-capability danger §"The danger" states for
session grants, amplified the moment a grant outlives the session.

---

## AI translation aid — describe the command, never judge it

The second extracted item, and a different axis from grants: grants cut
prompt *volume*; this improves the *comprehension* of the prompts that
remain. The confirmation gate is only as good as the human's ability to
parse what they're approving — and pikuri-os's audience is a
privacy-conscious user, not necessarily a sysadmin.

**What it is.** When the gate shows a command for confirmation, add —
*beside* the raw `$ <command>` — a plain-language rendering of what it
does: next to `find . -mtime +30 -delete`, a dim "≈ deletes every file
here not modified in the last 30 days." A decoration on the existing
`Confirmer::Terminal` render, not a new gate.

**The three constraints, and why each is load-bearing.** This is the
literal "an LLM may *translate*" half of the section invariant above —
and the constraints are what keep it a translation, not a verdict:

- **Never a verdict** (no "safe ✓" / "dangerous ⚠"). An AI verdict is
  corruptible by *the same laundered content that steered the agent into
  emitting the command* — a second LLM in the same poisoned context adds
  zero security. And a *silent-by-default warner* is worse: the user
  learns to read silence as "safe," and it goes quiet exactly when an
  injection is crafted to look benign. So it is neither approver nor
  warner — only a describer.
- **Always beside the raw command.** The translation can itself be wrong
  or manipulated (it summarizes hostile bytes). If it *replaced* the raw
  command, a mistranslation of `rm -rf ~` as "cleans a temp folder"
  would be the attack. The raw bytes stay the authoritative thing the
  human confirms against; the aid can only *add* context.
- **Optional.** A decoration, not a gate — the confirmer works without
  it.

It complements the shipped {Pikuri::Sanitizer}, which is the
*deterministic, byte-level* flag ("this text contains a right-to-left
override" — a fact about spoofing, not a verdict). The translation aid
is the *semantic-level* companion ("these bytes, read plainly, do X").
Both leave the yes/no to the human.

**Why deferred, and the design fork.** `Confirmer` is a pure
presentation seam with no transport, so an LLM translator would need one
wired in — and safely: an **isolated one-shot pass** (a
{Pikuri::Mcp::Thinker}-style call) fed *only the raw command*, no
conversation history, or the surrounding poisoned context can steer the
translation and reintroduce the manipulability the "no verdict" rule
fought. That is an LLM call + latency on *every* mutating prompt, not a
free decoration. So **deterministic-first**:

- **Rules-based translator** — reuse the passive detector's `Tokenizer` to
  recognize the high-value destructive shapes (`rm -rf <path>`,
  `dd of=<dev>`, `find … -delete`, `> <file>` truncation, `chmod -R`)
  and print a canned plain-language line. No LLM, no manipulation
  surface, deterministic — fits the "concrete code that does one named
  thing" ethos, and covers most of the value.
- **LLM one-shot pass** — only if the rules prove too narrow, and only
  in the isolated-pass shape above.

**Soft residual.** Even a pure, accurate translation can *drift into
being read as a verdict* ("the AI explained it, so it must be fine") —
the same complacency one level up. Neutral framing (a description, never
safety language) is a presentation discipline, not something code can
enforce.
