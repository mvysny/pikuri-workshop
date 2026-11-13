# `AgentPool`: asynchronous, conversation-centric hosting of pikuri agents

Status: **open, direction agreed, not started.** Grew out of pikuri's early-cancel fix
(`pikuri:D_host_resets_cancel`, which records the alternatives turned down on the way here).

## The problem: hosts all rebuild the same scheduler around `Agent`

pikuri's `Agent#run_loop` is a blocking call with rules attached. A host must:

- serialize every call — `Agent` is thread-unsafe, "the caller serializes";
- reset the `Cancellable` where *it* decides a turn starts, on its own thread, under the lock
  guarding its "running" flag — never on the worker, or a cancel sent between the two is lost
  (`pikuri:D_host_resets_cancel`);
- route a message sent mid-turn to the `Interloper` instead of a second `run_loop`, and start a
  turn for injections still pending when a turn ends;
- guard `cancel!` with its own "running" flag;
- apply a pending model switch at the top of the next turn, never mid-turn;
- not call `clear_conversation` / `load_history!` while a turn runs.

Three hosts implement this state machine, each a little differently, and each needed its own
early-cancel fix:

- pikuri-tui `AgentSession`: `@turn_in_progress`, `queue_mid_turn`,
  `deliver_pending_injections`, `interrupt`, the picker's `take_pending`.
- pikuri-web `Runner`: `:idle`/`:queued`/`:running`, `claim_running`, `finish_turn`'s restart
  on pending injections, `@abandon`, `take_pending`, a shared executor.
- Puri `Conversation`: `@turn` + `@waiting`, `finish` starts the next waiting message, `cancel`
  clears the queue; queues a second message as its own turn instead of injecting.

## Direction

**pikuri's `Agent` stays as it is**: synchronous, thread-unsafe, no thread plumbing, its rules
documented. It is the low-level API — what pikuri's `bin/` scripts, its specs, sub-agents and
one-off scripts use, and easy to follow because nothing in it is asynchronous.

**The asynchronous layer is a new pikuri-workshop gem, and it is conversation-centric.** For
the user the conversation *is* the agent; nobody cares about the agentic loop. For the app, a
conversation is a `History` plus the user's wishes, served by some agent while a turn runs.

```ruby
conversation = pool.new_conversation          # or pool.load_conversation(history)
conversation.submit('how do I keep an avocado?')  # returns at once, schedules the turn
conversation.submit('also, ripe?')     # a turn is running: rides it, via the Interloper
conversation.switch_model(transport)   # now if idle, else at the next turn's start
conversation.cancel                    # queued: withdrawn; running: stops at the next check
# the conversation's listener hears the agent's events plus the pool's:
# queued, started, idle, model switched, ...
```

- **Every call returns at once and records a wish.** The pool applies it when it can and
  reports through events.
- **`submit` while a turn runs injects into it.** A flag for "always queue as a new turn" can
  come later; Puri probably wants injecting too, it just doesn't know it yet.
- **The pool obeys `Agent`'s rules once, for everyone**: it resets the `Cancellable` under its
  own lock as it starts a turn, wires the `Interloper`, delivers leftovers, applies pending
  model switches, and never clears or loads mid-turn.
- **The pool owns the threads**: one executor shared by all conversations, with
  per-conversation serialization on top — `Concurrent::SerializedExecution#post(executor,
  &task)` (concurrent-ruby) runs one key's tasks in order, never two at once.
- **concurrent-ruby is this gem's dependency, never pikuri-core's.**

Why pikuri-workshop: pikuri grows by explaining better, never by gaining features, and core
stays lean because every deployment carries it — a scheduler is a feature. pikuri's invariant
holds: nothing in pikuri requires a workshop gem; the hosts depend on this one (pikuri-tui
already depends on workshop gems).

## Settled

- **Sub-agents stay plain `Agent#run_loop` calls, inline on the parent's thread**, sharing the
  parent's cancel token, as today. Never submitted to the pool and waited on: a parent turn
  waiting on a child's future holds its thread, and enough of them deadlock a bounded pool.
- **The executor is unbounded**, a `Concurrent::CachedThreadPool`, as pikuri-web already
  decided (`pikuri-webui:D_serial_turn_executor`): a turn holds its thread for its whole
  length, including waits that aren't load — a `Confirmer` waiting on a human, a long `bash` —
  so any bound strands conversations behind turns using no server slot.
- **Load stays bounded per request, by pikuri-core's `ServerPermits`** (pikuri's
  `D_llm_request_throttle`). They are process-wide already; the pool uses them, it doesn't own
  them.
- **The pool never calls out while holding its own lock** — no listener, no host code.
  pikuri-web serializes its state under one global monitor (`pikuri-webui:D_global_monitor`)
  and its listeners take it; calling them under the pool's lock invites a lock-order inversion.

## Superseded: `Agent::Runner` in pikuri-core

The earlier direction: `Agent` becomes an immutable template, `Agent::Runner` in core owns the
conversation and a turn queue, `submit` returns a cancellable future, `run_loop` becomes
submit-and-wait. Dropped: it put thread plumbing and a concurrent-ruby dependency into every
deployment, the `bin/` scripts included, which need none of it; and it kept the API
agent-centric while every host thinks in conversations. One trick from it is worth keeping in
reach: if a cancel ever has to be safe in a SIGINT trap (which can't take a `Mutex`), make it a
bare field write on a per-turn handle, and have the token's `check!` ask the *current* handle
(`raise Cancelled if @current&.cancelled?`) — no reset, and no stale or early cancel can land
on the wrong turn. GUI hosts don't trap, so the pool can take its lock to cancel.

## Open questions

- `Q_allocation` — an agent per conversation, or a pool of agents reloaded per conversation
  (`load_history!`, `clear_conversation`, a transport switch). Reuse fights `Agent`'s shape:
  listeners are fixed at `Agent.new` (pikuri-web attaches a per-conversation SSE listener),
  extensions hold conversation-scoped state, and a model is probed per agent. But `Agent.new`
  can cost LLM calls (the workshop's MCP synthesis at configure time). Lean: an agent per
  *active* conversation, built on its first `submit`, closed once idle for a while (the
  `History` stays); reuse only if construction cost bites.
- `Q_agent_factory` — how the pool builds an agent: a block like `Agent.new`'s configure block,
  handed the conversation (its id for sub-agent ids, its listener)?
- `Q_events_or_futures` — events only (simplest; a host that needs "the turn ended", e.g. to
  persist or title, listens for it), or `submit` also returns a future.
- `Q_persistence` — pikuri-web and Puri each persist `History` themselves. Lean: the pool
  doesn't; it emits a turn-ended event carrying the snapshot, and the host saves.
- `Q_bare_turns` — host-scheduled injections while idle (a UI-loaded skill,
  `Interloper#inject_system_message`) and the bare turn that delivers them: a `submit` variant
  or a command.
- `Q_boot_cancel` — if the pool builds agents, a construction that synthesizes MCP servers
  (`pikuri-code`, `pikuri-openlibrary`) runs on a pool thread; a cancel while the conversation's
  agent is still being built must reach it.
- `Q_thread_hopping` — a conversation's turns run on whichever pool thread is free. pikuri
  forbids keying state off `Thread.current`; check `Subprocess`, `Finalizers`, the LSP client
  and pikuri-web's thread names (`pikuri-webui:D_puma_thread_dump`) for thread affinity.
- `Q_tui_single` — pikuri-tui's shells hold one conversation; they'd use the pool too (one
  conversation), and the chat shell gains its first workshop dependency.
- `Q_naming` — `AgentPool` says what's inside; the hosts see conversations. The gem's name, per
  pikuri's "name a gem after what it refuses to become".

## Done when

- The gem exists, and pikuri-tui, pikuri-web and Puri drive their conversations through it,
  their own turn state machines gone.
- The nuggets land in this repo's durable docs: the pool's threading model and the
  conversation/agent split in the gem's `design/architecture.md`; why conversation-centric,
  why in the workshop and why the pool is shaped as it is as `D_` entries. Then this file is
  deleted.
