# Task tracking (the agent's working memory)

A short chapter near the end of the guide. By the end you'll know
why pikuri ships a task list, why it has exactly the shape it
does, and how to wire it onto any agent. Along the way, the gem
turns out to be a small but honest window into *how* LLMs actually
maintain (and lose) state across a long conversation.

## Why a task list at all

LLMs don't have memory. Each turn, the model sees the same flat
text blob — system prompt + every previous message + every tool
observation — and produces the next message. "Remembering" is just
"that text is still in the context window." Once a piece of text
falls off the end of the window, or gets buried 50 messages back,
it might as well not exist for next-turn purposes.

Try this thought experiment. You ask the agent to do a 30-step
refactor. By step 25, the original plan it laid out in step 1 is
thousands of tokens upstream. The model is now reasoning over the
last few tool observations, not over the plan. So it drifts: it
finishes step 23, mistakes step 24 for step 26, declares the task
done. You can *watch* this happen on a long enough task with no
externalized state.

A task list is the model's escape from this: a structured slot
that's *included in every turn's context* until the model
explicitly removes it. Three distinct effects fall out:

1. **Forced upfront decomposition.** Writing the plan as a tool
   call makes the model commit to a structure before it acts.
   Without that, models tend to do step 1, see new information,
   do step 2, get distracted, and never come back to step 4.
2. **Persistent working memory across turns.** The list is in
   context on *every* subsequent turn. Even at step 25 of 30, the
   plan is right there — not buried behind 4000 tokens of tool
   output.
3. **Self-correction checkpoint.** "Mark `in_progress` before
   starting, `completed` only when verified" forces an explicit
   state transition. The model has to *type* "completed" — which
   means it has to evaluate whether the step actually finished.
   Catches premature-victory bugs ("I wrote the function, done!"
   — but no tests ran).

That's the whole game. The gem is small; the lesson it embodies
is large.

## Watching the window fill

You don't have to take "context grows until things fall off" on
faith — pikuri's `TokenLog` listener prints a running headline
every assistant turn, wired into every `bin/pikuri-*` demo:

```
msg #1: ctx=6.8k  Δ+6.8k  ↑6.8k  ↓0.0k
msg #2: ctx=8.4k/32.0k  Δ+1.6k  ↑1.0k  ↓0.6k
```

`ctx` is the number to watch — the whole conversation *through
this turn* — and it only ever climbs. It's worth knowing exactly
what feeds it, because it's the number that eventually ends the
conversation. Each turn the provider reports its token usage split
across four fields. Three describe the prompt it just processed
and are *exclusive slices* that sum to this turn's prompt size:
`input` (freshly-read tokens), `cached` (prompt tokens served from
the provider's cache), and `cache_creation` (tokens written into
the cache). The fourth, `output`, is the tokens in the reply. Add
all four — `input + cached + cache_creation + output` — and you
have the tokens consumed *through* this turn: that's `ctx`.

The reason `ctx` climbs is the whole point of the chapter: this
turn's output becomes part of next turn's prompt. Every reply and
every tool observation is re-fed on the following turn, so the
running total only grows, and when it crosses the model's context
cap (the `/32.0k` suffix, shown once pikuri detects it) the
provider raises `RubyLLM::ContextLengthExceededError` and the turn
dies. Caching changes the *cost* of that prompt, not its size — a
big cached prefix is cheaper to reprocess but occupies exactly as
much of the window. Speed, not head-room. A task list doesn't stop
the climb; it just makes sure the one thing you can't afford to
lose — the plan — stays near the top of the pile the whole way up.

## The four tools

`pikuri-tasks` ships exactly four LLM-facing tools, one per verb:

- **`task_create`** — pass a JSON array of strings, one task per
  element. All start as `pending`. Use this once at the start
  of a multi-step task to capture the plan in one call.
- **`task_in_progress`** — pass the numeric `id` of an existing
  item. Marks it as in-progress. Use immediately before starting
  work on the item.
- **`task_completed`** — pass `id`. Marks the item as done.
  Use only after the work (and any verification) is actually
  finished.
- **`task_delete`** — pass `id`. Removes the item entirely.
  Use for items that turn out not to be needed; reserve
  `task_completed` for work actually done.

Every mutation returns the full current list as its observation,
so the model always sees fresh state — including each item's id —
without a separate read tool:

```
<tasks>
- #1 [pending] Add dark mode toggle
- #2 [in_progress] Write unit tests
- #3 [completed] Update README
</tasks>
```

Empty renders as `<tasks>(empty)</tasks>` — an unambiguous "the
call worked and the list is now empty" signal.

## Three design choices worth a moment

The shape above looks obvious once you see it, but each piece was
a decision with an alternative — and two of the three were
*reversed* after watching real transcripts. Both reversals teach
the same lesson, so they're worth walking through honestly.

### Status is in the verb name, not a parameter

The obvious shape is one `task_set_status(id:, status:)` tool
with `status` being an enum: `pending` / `in_progress` /
`completed`. Pikuri instead has three separate verbs.

The reason is typo failure modes. Enum values are *strings* the
model emits — and a model will occasionally produce
`"in-progress"` or `"inprogress"` or `"InProgress"`. The
validator catches it and replies with an `Error: ...` string, the
model retries, sometimes lands the same wrong value again. Tool
names, by contrast, are picked from a finite list the API
enforces structurally — the model literally cannot misspell
`task_in_progress`. Trading one parameter for three tool classes
eliminates a whole category of failure.

(This is a recurring design move: convert "string the model
emits" into "tool the model selects" wherever you can, because
the second is API-enforced and the first isn't.)

### Mass-create takes a JSON array — the training prior always wins

`task_create` originally took a newline-separated string:
`"first\nsecond\nthird"`. The theory was failure surface — a JSON
array is brackets, quotes, and escapes a small model has to
balance, while a flat string is just text.

Real transcripts killed the theory. Every mainstream harness's
task tool (Claude Code, opencode) takes a JSON array, so that's
the shape the model's training data overwhelmingly contains — and
the model *sent a JSON array anyway*, stuffed into the string
parameter. The newline splitter then dutifully created garbage
tasks: `[`, `"Update lib/foo.rb...",` (quotes and trailing comma
included), `]`. The model saw the wreckage, tried to clean it up,
failed to reproduce the mangled contents exactly, and abandoned
the list.

The lesson: **a parameter description does not beat the training
prior.** When every tool the model has ever seen takes shape X,
asking for shape Y in prose doesn't make Y arrive — it makes X
arrive disguised as Y. So `task_create` now declares `items` as a
real `{type: 'array', items: {type: 'string'}}` parameter: the
model sends the array natively in the tool-call JSON (the shape
it wanted to send all along), and the strict validator rejects
anything else with an actionable error.

### Items are addressed by numeric id — same lesson, second verse

The same original design used the content string itself as the
identifier: `task_completed(content: "Add dark mode toggle")`.
The argument was that models are very good at echoing back
strings sitting in their own context, while IDs are a mapping to
hallucinate.

The argument half-survives: models *are* good at echoing strings.
But "good" isn't "perfect", and the failure mode is brutal — one
near-miss in reproducing the exact bytes (a stray quote, a
trailing comma, an em-dash typed as a hyphen) and the call errors.
The model retries from semantic memory rather than byte-exact
memory, misses again, and is effectively locked out of its own
list. An id is two digits the model just read back in the
previous observation; there is nothing to mis-transcribe. It's
also — again — the shape every other harness uses, so the prior
helps instead of fighting.

Ids are assigned on create, shown in every render
(`- #3 [pending] ...`), and never reused after a delete — a stale
id errors loudly (`Error: no such task id: 7`, with the current
list attached so the model recovers in one turn) instead of
silently hitting a newer task. Duplicate contents are still
rejected on creation, not because they'd be ambiguous now, but
because a duplicate is almost always the model re-sending a plan
it already captured.

## What state lives where

The list is an `Array<Item>` inside one `Pikuri::Tasks::List`
instance, held by the `Pikuri::Tasks::Extension` that wired it.
Three properties matter:

- **Per-Agent.** Each agent that adds the extension gets its own
  fresh list. Two agents in the same process don't share.
- **In-memory.** Nothing is written to disk. When the agent is
  garbage-collected, the list goes with it. Re-running the binary
  starts you fresh — by design; persistence is a feature the gem
  deliberately doesn't have.
- **Not inherited by sub-agents.** This follows pikuri's
  established rule from the sub-agents chapter: sub-agents don't inherit
  extensions. A `RESEARCHER` or `FILE_MINER` spawned via the
  `agent` tool gets no task list. The parent's plan stays private
  to the parent, and sub-agents focus on their narrow remit
  rather than the parent's overall workflow.

If you want a sub-agent to also have its own list, add the
extension to its configurator at construction — explicit opt-in,
no implicit sharing.

## Wiring it onto an agent

Adding tasks to any pikuri agent is one line in the `Agent.new`
block:

```ruby
require 'pikuri-core'
require 'pikuri-tasks'

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension Pikuri::Tasks::Extension.new
end
```

That's the whole setup. `Pikuri::Tasks::Extension#configure`
constructs a fresh `Tasks::List`, registers the four tool classes
(each capturing the same list by closure), and appends a brief
`<tasks_usage>` workflow snippet to the system prompt — the
LLM-facing nudge that explains the workflow.

For your own host: pick a system prompt that gives the model
something multi-step to do, drop the extension into the block,
and watch the model decompose its work in the first tool call.
That's the entire feedback loop.

`pikuri-code` wires this extension by default — coding agents do
multi-step work, and the externalized-plan property pays off there
more than anywhere else in the guide. [The coding-agent chapter](code.md)'s
walkthrough shows the four-extension block (skills, tasks, MCP,
sub-agents) all wired together; this chapter focused on tasks
alone so the single-purpose API doesn't get lost in that wider
picture.

## What's next

[Skills (stub)](skills.md) covers the last
extension `pikuri-code` discovers: [Agent
Skills](https://agentskills.io/specification), portable folders of
"when you see *X*, do *Y*" instructions. Skills are text the model
loads into the conversation on demand — closely related to the
task list in that both are about giving the model *more useful
context* than it could maintain by itself.
