# Telling the *model* how much context it has spent

Status: **idea, not built — and the shape that started it is now refused
outright.** Origin: the 2026-08 in-harness review (Grok 4.6; it lived in
pikuri's `design/ideas/feedback.txt`, deleted 2026-08-25 once its last item closed),
whose headline ask was a readout on *every* turn: *"I can't see token
use... a small budget line on each turn (~40% context used) would change
behavior."* The author refused that on 2026-08-25 — watching the budget
is the human operator's job, and the readout that already ships is
enough (see *What already ships* below, and the operator-discipline
thesis in [`context-overflow.md`](context-overflow.md)).
So the per-turn line is **dead, not deferred**; the reasons are kept
under *Why the per-turn line is wrong* because they are why, not
history.

Moved here from pikuri on 2026-11-15 together with the overflow note it
is blocked on, since both are policy. The `design/decisions.md` below is
whichever repo the warning finally lands in: pikuri's if it becomes a
core `Control`, this one's if it is a workshop extension.

What stays open is the much smaller question this note argues its way
down to: one late warning, for the autonomous legs no operator is
watching. That remains blocked on
[`context-overflow.md`](context-overflow.md), which is
also the note that draws the operator-discipline line between the
interactive agent (where the refusal is clearly right) and those legs
(where it can't reach).

The human-facing half of this already ships. The open question is whether
to add a model-facing half, and — after arguing it out — the answer is at
most **one late warning**, never a per-turn readout. Its *wording*,
though, turns out to be a function of the overflow policy, so even the
late warning can't be written yet; what can be built ahead of that
decision is the threshold detector underneath it (sensor vs. actuator,
below).


## What already ships (grounded)

The number exists; it just points at the human.

- {Pikuri::Agent::ChatTransport#context_window}, stated by the host and
  read off `agent.transport`; core emits no cap event (`pikuri:D_deferred_cap_probe`).
- `Event::Tokens` per assistant message (`agent.rb:653`) — input, cached,
  cache_creation, output.
- {Pikuri::Agent::Listener::TokenLog} computes exactly the wanted number:
  `input + cached + cache_creation + output`, rendered `ctx=8.4k` in
  absolute tokens, with no cap.
- `TokenLog#status_line` + `#on_status_line` exist *specifically* so a
  host can put the readout in a TUI footer.

So "the user should watch the context size" is already implemented.

(An earlier draft of this note claimed `bin/pikuri-code` was the one
binary not wiring `TokenLog`. That was simply wrong — all ten binaries
wire it, `pikuri-code` since the monorepo extraction. What they mostly
lack is an `on_status_line` observer, so the readout is log-only: it
reaches the human through `PIKURI_LOG`, not through the chat surface.
That is a much weaker gap, and a `bin/` script's crudeness rather than a
bug.)


## What happens at the wall — and why that's not settled

Every binary rescues `RubyLLM::ContextLengthExceededError`; `pikuri-code`
does `warn` + `exit 1` (`pikuri-code/bin/pikuri-code:366`).

**Do not read that as pikuri's overflow policy.** `bin/pikuri-*` are dev
/ demo entry points (pikuri's AGENTS.md), and dying on overflow is that
deliberate simplicity in action — the right move for a script whose job
is to be readable end-to-end. A real host (`pikuri-tui`) can and should
do something better; *what* is
[`context-overflow.md`](context-overflow.md)'s
question, not this note's.

That matters here because it changes the size of the prize. Against
`exit 1`, a pre-wall handoff written by the model saves a session that
would otherwise be lost outright. Against a host that compacts, or
auto-clears with a summary, or lets the human rewind, most of that value
evaporates — such a host can summarize the history *after* the fact and
doesn't need the model to have volunteered anything in advance.

**So this note is downstream of `context-overflow.md`, and
should not land before it.** If the host handles overflow well, the honest
outcome may be "tell the model nothing" (see the steelman below).

With that caveat, the test for the feature is: **what can the model do
with the number that the host can't?** Exactly two things:

1. Stop pulling bytes in — delegate broad recon rather than reading files
   inline, don't re-read what's already read. Real, but marginal; a
   well-prompted agent should do this anyway.
2. **Write a handoff before the wall.** The model is the only party that
   knows which state matters *while it still has the full picture*. At
   the very top of the window, "here's what's done, what's next, clear
   and paste this" is an artifact no post-hoc summarizer can match — but
   only by a margin, and only if the host doesn't already summarize.

(2) is the entire case for the feature, and its strength scales inversely
with how good the host's overflow handling is. (1) alone would not be
worth a token.


## Why the per-turn line is wrong

Three independent reasons, any one sufficient:

- **Inert in the middle band.** Between ~20% and ~60% the number changes
  no behaviour. It is pure cost, plus a standing invitation to optimize
  against a constraint that isn't binding.
- **It accumulates, permanently.** `Extension#on_user_message` is
  append-only by design (its own yardoc: the Agent "only ever appends…
  never rewrites or removes an earlier one, which would bust the provider
  prefix cache"). A long conversation therefore carries a growing pile of
  stale percentages, each a small nudge toward shortcutting. Ironic for a
  feature about context frugality.
- **Panic.** Showing a model a budget makes it rush — truncate work, skip
  verification, "let me wrap up given limited context". Claude Code's own
  standing prompt carries an explicit counter-instruction ("you don't need
  to wrap up early or hand off mid-task"). That sentence exists *because*
  the failure mode is real; they shipped a leash rather than removing the
  number.

The steelman for telling it nothing at all is strong and worth writing
down: **without the number the model acts as if context were unbounded,
which is correct on the overwhelming majority of turns and produces its
best work.** Knowledge of a constraint only pays when the constraint
binds. The late-warning shape is an attempt to keep that property for
~90% of turns while making the last 10% non-fatal.

The operator-discipline argument in
[`context-overflow.md`](context-overflow.md)
strengthens that steelman for the interactive agent specifically — if a
human is watching the readout that already ships and ends the session
first, the model never needs the number either. It leaves the case for
(2) standing only where nobody is watching: the autonomous legs.


## Proposed shape

One `:system` append when crossing ~85%, optionally a second at ~95%.
Fired once per band, with hysteresis (never twice for a band, never on
the way down). Bare:

```
Context: 109k / 128k used.
```

No percentage — a percentage reads as a progress bar toward death, a raw
count reads as an instrument. No adjective, no advice, no anti-panic
paragraph: if the model draws the wrong conclusion from one late
mechanical reading, more words won't fix it, and the words are exactly
what makes the per-turn version intolerable.

### …but the wording can't actually be settled yet

That "bare number, no advice" rule doesn't survive contact with the
blocked question. **Actionable = fact + consequence**, and the bare line
is only the fact. What the model should *do* on reading it differs per
overflow policy:

| Overflow policy | Right reaction at 85% |
|---|---|
| Fail loudly, lose the conversation *(today)* | write the handoff into the next message — stdout is the sink, the human pastes it into a fresh session |
| Summarize in place and continue | **nothing.** Any reaction is pure damage: work truncated to dodge a wall that isn't there |
| Hand off to a fresh agent seeded with a summary | write the handoff somewhere *durable* (task list, file) — prose is discarded with the history |

Three policies, three incompatible reactions, so the sentence cannot be
written before the policy is picked. And once the consequence is in the
message, "no advice" is already broken.

The uncomfortable implication: **the bare-number shape reads as an
instrument only because it silently assumes `exit 1`.** Under today's
demo behaviour a model can guess what the instrument means; under
auto-compaction the same bytes are an active hazard. That is the concrete
mechanism behind "downstream of `context-overflow.md`" — not
ordering hygiene, but the message text being a function of the policy.

Home: a `Control` — the family already holds the loop-level signals, and
the natural firing point is the `after_tool_result` boundary where the
interloper drains (the only place mid-turn where conversation state is
consistent). `Extension#on_user_message` is the wrong hook for this: it
fires once per *user* turn, so a long autonomous run — precisely the case
that blows the window — would get one reading, taken before the run
started.

This bullet used to cite `Control::StepLimit` as the sibling that made
`Control` obviously the right home. That sibling is gone
(`pikuri:D_no_step_limit`), and `Control` is now `Cancellable` + `Interloper` —
both *host-facing signal holders*, neither a budget. So "controls are the
family for budgets" is no longer true by example, and a token control
would be the first of its kind. Weigh that as a cost of this proposal,
not a formality.

**Off by default**, wired by `pikuri-code` only.

### Unknown cap ⇒ no line at all

Per `pikuri:D_context_window_sources`, the cap is `nil` unless the host states
`ChatTransport#context_window` (or its own `/props` probe fills it in). A threshold
feature needs a denominator, so with no cap there is no band to cross and
nothing to emit. Never invent a denominator, and never emit a bare "56k
used so far" as a consolation prize — that's the inert middle-band line
wearing a different hat.


## Sensor vs. actuator — what is buildable now

The feature is two pieces, and only one of them is blocked:

- **Sensor** — band-crossing detection: 85/95, once per band, hysteresis,
  `nil` cap ⇒ no bands. Pure arithmetic over `agent.transport.context_window`
  and `Event::Tokens`, both of which already ship, over a numerator
  `TokenLog` already computes (`token_log.rb:164`). Policy-free: *every*
  compaction strategy needs the same trigger — summarize-in-place and
  seed-a-fresh-agent both fire on a threshold, not on the raise. Unlike
  the actuator, it is ordinary wiring and **is** testable with
  `Testing.fake_transport`.
- **Actuator** — the `:system` append to the model. Blocked, per the
  table above.

The catch is AGENTS.md's no-abstraction-just-in-case rule: a sensor whose
only consumer is a feature that may never ship is speculative, and would
be a `Control` firing an event nobody listens to. It earns its place
today only with a *human*-facing consumer — a footer that goes amber, or
one `warn` at 85% in `pikuri-code`. That needs no policy decision (the
human is the actor and already knows what clearing does) and touches none
of the blocked fork. Without such a consumer, the honest move is to build
neither half and wait.

Note this splits the blocking cleanly: the model-facing question is
blocked on the overflow decision, the sensor is blocked only on wanting a
human-facing warning.


## Considered and rejected

- **A budget line on every turn** (the original feedback ask) — the three
  reasons above.
- **`Extension#system_prompt_snippets`** — assembled at construction and
  on `clear_conversation` only (`agent.rb:490`), so it would be frozen at
  0%. And a prompt that changes per turn invalidates the provider prefix
  cache for the whole conversation: the most expensive possible home for
  a number that changes constantly.
- **Appending to every tool result** — that's the tool's contract, and
  you'd pay it on every step of the run.
- **A `context_status` tool** — the model has to know to ask, which is
  the one thing it can't know.
- **`<total_tokens>` as a design precedent.** Claude Code emits a
  `<total_tokens>N tokens left</total_tokens>` counter on every turn, and
  it briefly looked like evidence that "remaining" beats "used" as a
  framing. It isn't: the figure (15M) far exceeds that model's context
  window, so it's a spend budget, not a context readout. Recorded here so
  nobody re-derives the false lead.


## Coupling to compaction (orthogonal, but not independent)

Automatic context compaction is a separate feature and should stay one.
But the *absence* of graceful overflow handling is what gives this note
its value: where the host recovers, the wall is a hiccup and no warning
is needed; where it doesn't, the model's pre-wall note is the only
salvage. This warning is best understood as the cheap stand-in for a
host that handles overflow properly. **If compaction ships — or if
`pikuri-tui` handles overflow well on its own — delete the warning
rather than keeping both.**


## How to settle it

The *actuator* is not testable with `Testing.fake_transport` — it is a
claim about model behaviour, not wiring (the sensor is ordinary wiring
and does spec normally). The experiment is running `pikuri-code` on one
real, long task twice, warning on and off, and watching whether the
warned run degrades *before* the wall or hands off cleanly *at* it.

Until that's run, "off by default" is the honest posture, and shipping it
as a flag is what makes the experiment cheap.

**Sequence, though: settle `pikuri-tui`'s overflow behaviour first.** It
sets the value of the prize, and could well settle this note by making it
unnecessary. Running the A/B before that risks measuring a feature
against a `bin/` script's deliberate simplicity rather than against the
host anyone will actually use.


## Graduation plan

Blocked on [`context-overflow.md`](context-overflow.md)
— see above. Once that's settled, the fork here is real (late-only vs.
nothing — the per-turn arm is already refused, see the status note), so
this earns a `design/decisions.md` entry whenever it lands, including the "tell
it nothing" branch, which is a legitimate outcome. Write the entry only
then: today's refusal kills one *shape*, and an entry claiming the whole
axis is settled would be wrong about the autonomous legs.

- Decision + rejected alternatives → `design/decisions.md`.
- The `nil`-cap ⇒ no-line rule, and the once-per-band hysteresis → yardoc
  on the new `Control`.
- The compaction coupling → that entry's *Consequences*.
- The fact-plus-consequence argument — why the message text is a function
  of the overflow policy — → that entry's rationale, since it is the
  reason the fork exists at all.

The **sensor** can graduate ahead of all that, if a human-facing warning
is wanted for its own sake: no `design/decisions.md` entry (no fork — a
threshold with hysteresis is just how it works), rationale to the new
`Control`'s yardoc, `nil`-cap rule included.
