# What should happen when the context window fills up?

Status: **draft; the policy is still a bare agenda, not yet arguments.**
Moved here from pikuri on 2026-11-15, once pikuri core shipped the
actuator and handed the policy to the workshop
(`pikuri:D_compaction_in_place`). This note owns the policy: when to
compact, how, with what, and whether at all.

[`context-budget.md`](context-budget.md) — whether to tell the *model*
how much context it has spent — is **blocked on this note**, because how
gracefully a host recovers from overflow sets the entire value of warning
the model in advance.


## Current state (grounded, 2026-11-15)

`RubyLLM::ContextLengthExceededError` is rescued in **12** `bin/` scripts,
seven in pikuri (chat, files, minions, corpus, briefing, thunderbird,
secretary) and five here (code, os, computer, memory, openlibrary), with
the same four-line block:

```ruby
rescue RubyLLM::ContextLengthExceededError => e
  warn "\nContext window exhausted: #{e.message}"
  warn 'The conversation has grown too large for the model. Start a fresh question.'
  exit 1
```

Two things worth knowing before designing anything:

- **Nothing is summarized.** The conversation is lost as-is.
- **A summarizer used to exist and was deleted** (2026-09-08) — see
  *The deleted summarizer* below, which carries its prompt and its
  message-walk verbatim. Do not go looking for
  `Pikuri::Agent::Synthesizer`; it is gone, along with the step limit
  that was its only trigger.
- Nothing handles overflow — it propagates out of `run_loop` to whoever
  called it. The actuator exists (*What pikuri ships* below), but nothing
  calls it yet.

Overflow is now also the **only** ceiling on a runaway loop. The step
limit went on the grounds that it never once caught a real loop and
repeatedly stopped legitimate long work (`pikuri:D_no_step_limit`), which
promotes this note from "compaction is a convenience" to "this is the
last backstop". That is not a reason to want the step cap back — a
tool-call count was always the wrong axis — but it does mean the
do-nothing answer below is now load-bearing rather than merely tidy.

Per both repos' AGENTS.md, the `exit 1` is a *demo script's* deliberate
simplicity and must not be read as policy. But 12 identical
copies of it means the moment there is a policy, there's a question of
whether it belongs in a shared place.


## What pikuri ships, and what is left to this note

`Pikuri::Agent::Configurator#replace_compacted_history(history)` swaps the
conversation for a shorter version of itself; tools, MCP connections,
extension state and the system prompt stay. A compaction extension keeps
its `c` and calls it, from `Extension#on_user_message` or between turns,
including the mid-turn drain once a tool batch is answered. Its yardoc has
the shape it enforces; `pikuri:D_compaction_in_place` has why it works in
place and why pikuri ships no policy (ruby_llm's own provider-side
`Chat#with_compaction` included).

So everything below is this note's: whether the interactive agent wants
any of it (the counter-thesis says maybe not), the trigger (before or
after the raise), what to summarize with, and what must never be pruned.
The sub-agent is the one case that *needs* automatic compaction, and
nothing triggers one mid-turn yet. A sub-agent's overflow that today ends
the parent's turn is pikuri's to fix (pikuri's
`design/ideas/subagent-deferrals.md`).

**A lead for strategy 5:** ruby_llm 2.2's
`Chat#with_context_budget(per_request:)` runs client-side: it leaves the
oldest tool results out of the request, each replaced by a note, while
the transcript keeps them. Known from its doc comment only, never run;
worth a look before writing an evict-by-kind policy by hand.


## The operator-discipline counter-thesis (2026-08-15)

Raised by the author, and it reframes the whole note: **a sensible
operator watches the context size and ends the session before it matters,
and may therefore never need compaction at all.** Reported practice — in
years of daily agent use, context compression has never once been needed;
the session ends and the idea file gets updated instead.

The conclusion largely survives scrutiny. The stated *mechanism* does
not, and the difference changes what pikuri should build.

### There is no 60% knee — the curve is in absolute tokens

A percentage of the window is the wrong unit. 60% of a 32k window is 19k
tokens; 60% of a 1M window is 600k. Those are not the same machine state,
and nothing in the model knows its own percentage. Everything that
degrades tracks the *absolute* count:

- **Cost.** Every step resends the whole conversation, so per-step input
  tokens equal the context size — linear from the first token, no knee. A
  20-step tool loop at 100k is 2M input tokens. Prompt caching cuts the
  *price* (~10% for a cache read) but not the count, and a cache miss
  after a TTL lapse re-prefills the lot. So "uses way more tokens" is
  right, and it is already true at 30%; it is merely twice as bad at 60%.
- **Latency.** TTFT is prefill-bound: ~400–800ms at 10k input tokens,
  several seconds at 100k. Smooth and roughly linear, again no knee.
- **Local decode (this matters most for pikuri, being llama.cpp-first).**
  Token generation is bottlenecked on KV-cache memory bandwidth, so
  tok/s falls steadily as the cache grows. Here a genuine *cliff* does
  exist — but it is a hardware artifact, not a model property: it hits
  when the KV cache stops fitting in VRAM and spills. Its location is set
  by `n_ctx`, quantization and card, not by a percentage.

The one source arguing for a percentage — an unreplicated preprint
(arXiv 2601.15300) claiming a 45.5% collapse at ~50% of max window over a
narrow 10% band — is exactly the shape the 60% intuition predicts, and is
noted here precisely so nobody leans on it: Chroma's 18-model *Context
Rot* study finds degradation **gradual and task-dependent, with no
universal threshold**, which is the better-supported picture.

### The number the operator actually wants is ~30k, and it's about quality

The strongest argument for the discipline isn't speed or cost — it's that
the answers get worse, far earlier than the window fills:

- **NoLiMa**: 11 of 12 models fell below *half* their short-context score
  at 32k tokens.
- **Aider's Paul Gauthier**: models "get confused when you feed them more
  than ~25–30k tokens."
- **Lost-in-the-middle** (Stanford): 20 retrieved docs (~4k tokens) drops
  accuracy from 70–75% to 55–60%, U-shaped by position.

So the practical yardstick is **absolute, around 30k tokens**, and on a
modern window that is nowhere near 60% — it's 3% of 1M. The 60% figure
only looks right on a *small* window, where percentage and absolute
converge; on llama.cpp at 32k, 60% ≈ 19k, which lands in the right
ballpark by coincidence. For calibration, Claude Code's own auto-compact
default sits at ~95%, with operators tuning anywhere from 20–40%
(aggressive) to 80%+ (late) — the spread itself says there is no physical
constant to find.

### Where the thesis holds, and where it can't

It holds completely for the **interactive main agent**: a human at every
turn, watching `TokenLog`, is a better context manager than any
summarizer, and the honest read is that compaction is a *convenience*
there, not a correctness requirement.

It cannot hold for the **autonomous legs**, and the sharpest of those is
the **sub-agent**: no human sits between the parent's tool call and the
child's return, so a child can burn its whole window inside one glance at
the parent. One tool observation (a large file read, `rg` across a
monorepo, a scraped page) can add tens of thousands of tokens between two
consecutive human glances. The operator cannot watch what they are not
watching.

Two earlier props for this paragraph are gone, and the honest version is
narrower than the one they supported. It used to cite `max_steps` of 40
as an autonomous leg and read sub-agents' unconditional
`on_exhausted: :synthesize` as independent corroboration ("the leg no
human watches is the one that must summarize itself"); both were deleted
with the step limit. And a check of how the binaries actually run
(2026-09-08) found **no unattended wiring at all** — all 12 `bin/`
scripts are a human at a prompt with SIGINT trapped to
`cancellable.cancel!`, `bin/pikuri-briefing` included (its `ARGV`
one-shot runs a turn and then falls into a Reline loop, so it would block
on stdin under cron). So the argument now rests on the sub-agent alone,
and on any future host that runs a turn nobody is watching.

### The sharp bit: the idea file *is* the compaction

The reported practice works because **the state lives in files, not in
the conversation.** "End the session, update the idea file" is not the
absence of compaction — it is compaction, done by hand, into a durable
artifact. And it's a strictly better artifact than an in-context summary:
reviewable, editable, versioned in git, readable by a human, and
re-loadable by the *next* session (and by a different model).

That reorders the agenda below. If the durable-artifact handoff is what
actually works in practice, pikuri's job is not to build a compactor but
to **make ending a session cheap and resuming it exact** — which is
strategies 2 and 7, not 3. It also argues the eventual `pikuri-tui`
should treat a session boundary as a first-class, *visible* event rather
than something to paper over.


## What this note must decide

- **Is recovery wanted at all for the interactive agent?** Per the
  counter-thesis above, a watching human may make it moot there, leaving
  only the autonomous legs to serve. "Ship nothing for the main agent" is
  a live answer, not a placeholder.
- **Does a `bin/` script get a choice?** Not through a core
  `on_context_overflow:` knob (`pikuri:D_compaction_in_place`). A demo
  that wants the real behaviour wires this note's extension; whether any
  should, or all 12 keep `exit 1`, is open.
- **Recover before or after the raise?** Reacting to
  `ContextLengthExceededError` is simple but late (the request already
  failed and the turn is half-built); acting on a threshold *before* it
  needs a trustworthy cap, which per `pikuri:D_context_window_sources` most
  wirings don't have.
- **What must never be pruned?** The Agent Skills spec's own
  client-implementation guide (Step 5) says to exempt skill content from
  pruning: losing a loaded skill mid-conversation degrades the agent
  *silently*, with no error — the model simply stops following guidance it
  can no longer see, which is the one failure mode pikuri's "errors are
  loud" rule exists to prevent. Nothing to fix today (nothing prunes), but
  it constrains strategies 3–5, and the enabling half is already in place:
  {Pikuri::Skill::Renderer.format_skill}'s `<skill name="…">` envelope is
  exactly the tag a compactor would key on, so don't lose it if the
  envelope is ever restyled. The same guide recommends tracking
  activations and skipping re-injection of an already-loaded skill —
  {Pikuri::Skill::SkillTool} re-renders the full body per call, so loading
  `cop` three times pays ~2 800 tokens three times. Cheap to fix, and
  whether it's worth fixing depends on whether anything here ever
  summarizes.


## Candidate strategies (agenda only — argue these later)

1. Fail loudly, lose the conversation. *(today)*
2. Summarize, then exit — hand the human a resumable digest.
3. Summarize in place and continue (auto-compaction).
4. Evict oldest turns; keep the system prompt and the last N.
5. Evict by *kind* — drop bulky tool observations, keep the dialogue.
6. Offload to disk / the vector store and retrieve on demand.
7. Hand off to a fresh agent seeded with a summary + open task list.
8. Ask the human what to do.

0. Don't reach the wall — the operator ends the session first, and the
   handoff is a file in the repo. *(today, for a disciplined human; see
   the counter-thesis. Not available to an autonomous leg.)*

These are not mutually exclusive, and the right answer may differ for a
demo script, a TUI, and a sub-agent. Given (0), 2 and 7 look stronger
than 3.

**Images are the lopsided case for 5.** Measured 2026-11-04 (Ornith-1.5
on llama.cpp `b10438`, solid-colour square PNGs, `prompt_tokens` minus
~26 for the text): 64 px ≈ 9 tokens, 256 px ≈ 64, 1024 px ≈ 1024,
2048 px ≈ 4096, 4096 px ≈ 4096 — one token per 32×32 px, **capped at
~4096 by llama.cpp's mtmd**. An old screenshot (a user's `@path` or a
`read` result) therefore costs ~4 K, while the note that stands in for it
once its bytes are dropped (`Read image: shot.png (…)`) costs ~20 — the
best tokens-freed-per-meaning-lost trade in the conversation, and a
History rewrite that keeps the call/result pairing intact (only
`attachments` empties). The cost is already in the server-reported
`prompt_tokens`, so no estimator is needed to see it. Per projector,
though: another family (Gemma 3 is said to charge a flat ~256,
unmeasured) will differ, so a policy keys on the reported counts, not on
this table.


## The deleted summarizer

`Pikuri::Agent::Synthesizer` was a nested tools-free `Agent` that
answered a question from the evidence an exhausted agent had already
gathered. It shipped for the *neighbouring* trigger — a tripped
`Control::StepLimit` under `on_exhausted: :synthesize` — and both went
in one commit (`pikuri:D_no_step_limit`). It never handled overflow, but it is
the closest thing pikuri ever had to "summarize, then exit", so what it
knew is recorded here rather than left for git archaeology.

Last pikuri commit where it existed: **`d0efb6c10df0`** (2026-09-08),
`pikuri-core/lib/pikuri/agent/synthesizer.rb` plus its spec. Read it
there if you want the construction boilerplate; what follows is the part
worth reconstructing.

**The prompt, verbatim.** Four sentences, and every clause was earned by
watching a model do the opposite:

```
You are given evidence another agent collected before running out of steps. Answer the user's question using only this evidence. You have no tools. If the evidence is insufficient, state plainly what's missing and what partial answer you can give. Do not apologize or comment on the previous agent.
```

The last sentence is the one that looks droppable and isn't: without it a
salvage answer opens with a paragraph of apology for a failure the user
never saw. `state plainly what's missing` is what stops a confident
answer built on three of the eight facts it needed. For an overflow
summarizer the first sentence changes (`running out of steps` → whatever
the trigger is) and the rest transfers as-is.

**The message walk, verbatim.** This is the fiddly half — it encodes the
shape of ruby_llm's message graph, which is stable and which a rewrite
will get wrong at least once:

```ruby
def self.format_evidence(messages)
  results_by_id = messages
                  .select { |m| m.role == :tool }
                  .to_h { |m| [m.tool_call_id, m.content] }

  lines = []
  messages.each do |msg|
    next unless msg.role == :assistant

    text = msg.content
    lines << "Note: #{text}" if text.is_a?(String) && !text.empty?

    msg.tool_calls&.each_value do |tc|
      result = results_by_id[tc.id]
      next unless result

      args = tc.arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
      lines << "Tool call: #{tc.name}(#{args})"
      lines << "Tool result: #{result}"
      lines << ''
    end
  end
  lines.join("\n").rstrip
end
```

Four things in there are non-obvious. `tool_calls` is a **Hash**, hence
`each_value`, and it is insertion-ordered. Results pair by
`tool_call_id`, which lives on the `:tool` message, not on the call.
`msg.content` carries only an image observation's note — the bytes ride
in `msg.attachments` — so the rendered evidence says an image was there,
not what it showed. And **calls with no matching result are dropped**: the
call that tripped the budget never executed, so rendering a nonexistent
result invents evidence.

That last rule is where this connects to the open problem below: a
compactor has to cut without separating a call from its result, and
`replace_compacted_history` only refuses a bad cut, it doesn't find a
good one. `format_evidence` is that same constraint solved in the read
direction — proof the pairing is tractable to walk.

**Three traps in the construction**, which is otherwise boilerplate you
should not copy:

1. **Check the cancel flag before building the nested agent.** The
   nested `run_loop` calls `Cancellable#reset!` at its turn boundary, so
   a cancel requested between the trigger and the rescue was silently
   erased. The old code called `ctx.agent.cancellable&.check!` as its
   first statement for exactly this reason.
2. **Carry the parent's already-resolved `context_window` onto the
   nested transport** (`transport.with(context_window: ...)`) or the
   child re-probes the model. This matters *more* for overflow than it
   did for step exhaustion: you are recovering from a cap you have
   already measured.
3. **Give the nested agent a distinct `id` suffix** (`"#{id}_synthesizer"`,
   `_` being the separator sub-agents use) so `TokenLog` bills the
   rescue separately from the loop. Without it the salvage tokens look
   like the run's own.

A fourth trap has no expression any more: the old code gave the nested
agent a defensive `StepLimit.new(max: 1)` against a provider that
returns a tool call to a tools-free agent. There is no step limit to
reach for now, and the honest answer is that this never fired.


## Pointers

- pikuri `d0efb6c10df0` — the last commit holding `Pikuri::Agent::Synthesizer`
  and `Pikuri::Agent::Control::StepLimit`. See *The deleted summarizer*
  above for what survived the deletion, and `pikuri:D_no_step_limit` for why.
- {Pikuri::Agent::Listener::TokenLog} — where the live usage number
  already lives.
- {Pikuri::Agent::Configurator#replace_compacted_history} — the actuator:
  export with {Pikuri::Agent#export_history}, shorten, hand back. Where to
  cut is still the compactor's problem; the method only refuses a cut that
  strands a tool result or drops the last message.
- `pikuri:D_context_window_sources` — why a cap is often `nil`, which constrains
  every threshold-based option.
- `book/tasks.md` mentions the overflow raise in passing; if behaviour
  changes, that line needs a look.

Sources for the numbers above (checked 2026-08-15):

- Chroma, *Context Rot* — <https://www.trychroma.com/research/context-rot>
  (18 frontier models; gradual, task-dependent, no universal threshold)
- NoLiMa + Gauthier's ~25–30k figure, via
  <https://www.albertsikkema.com/ai/development/tools/2026/04/23/smaller-context-window-better-claude-code.html>
- Claude Code's ~95% auto-compact default and the operator spread —
  <https://code.claude.com/docs/en/context-window>
- The lone percentage-threshold claim, treated as unreplicated —
  <https://arxiv.org/abs/2601.15300>
