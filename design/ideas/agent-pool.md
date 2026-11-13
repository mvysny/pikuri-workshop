# A slim `Agent` and a `SessionList`: one design, two layers

Status: **first step done in pikuri** — `ServerPermits` / `RequestThrottle` deleted, `Agent.new(around_request:)` in (see "Leaves `Agent`"); the rest is the concrete shape, unbuilt. Grew out of pikuri's early-cancel fix
(`pikuri:D_host_resets_cancel`). Names are working names (`Q_naming`). Covers both layers because
they are one design: what leaves `Agent` is what the `SessionList` takes.

## The problem

**Hosts rebuild the same scheduler around `Agent`.** `Agent#run_loop` is a blocking,
thread-unsafe call with rules attached: serialize every call; reset the `Cancellable` under the
lock guarding your "running" flag as you start a turn, never later on the worker
(`pikuri:D_host_resets_cancel`); route a mid-turn message to the `Interloper`; start a turn for
injections left over at turn end; apply a model switch only between turns; never clear or load
mid-turn. pikuri-webui's `Runner`, pikuri-tui's `AgentSession` and Puri's `Conversation` each
implement this, each a little differently. None of the three calls `Cancellable#reset!` yet —
all pin a pikuri from before `D_host_resets_cancel` — so a pin bump alone breaks cancel in each.

**`Agent` absorbed what hosts wanted, and grew** — `agent.rb` is 1400 lines, plus
`ServerPermits`, `RequestThrottle` and `ContextWindowDetector` (~730 more) that only matter when
something runs concurrently.

## Direction: two layers, and the rule that splits them

- **`Agent` (pikuri-core) is the synchronous agentic loop**: what pikuri's `bin/` scripts, specs,
  sub-agents and one-off callers (the MCP Thinker, a titler) use. Simple enough to demo, and
  extensible through a small, closed set of seams.
- **`SessionList` (a new pikuri-workshop gem) hosts many conversations asynchronously**: it owns
  the threads, the turn state machine, the throttle and the `/props` probe. Conversation-centric:
  for the user the conversation *is* the agent. concurrent-ruby is its dependency, never core's.
- **The rule: a feature leaves `Agent` if it only matters when something else runs at the same
  time.** One `bin/` script never has that: tools run one at a time (`tool_concurrency` off),
  sub-agents run inline, so one agent tree sends one request at a time. Throttling and the
  probe's slot count are for N concurrent trees, i.e. a host.
- **What can't leave**: most of `agent.rb` is loop correctness every caller needs — answering
  dangling tool calls, withholding foreign thinking, the empty-turn guard, the
  `<system-reminder>` envelope, `History` metadata. The pool never sees inside a turn. Expect
  `agent.rb` to lose ~150 lines and core ~700, not a rewrite.

Why the workshop: pikuri grows by explaining better, never by gaining features — a scheduler is
a feature. Nothing in pikuri requires a workshop gem; the hosts depend on this one.

## What the callers need

webui is the reference host; Puri was written hastily, so a Puri quirk is evidence of what it
does, not of what it needs.

| Need | webui | tui | Puri | bins | Lands in |
|---|---|---|---|---|---|
| One agent per conversation, never reused across conversations | ✓ | ✓ (one) | ✓ | ✓ (one) | `SessionList` |
| Agent built at view, off the host's lock (no I/O under webui's monitor) | ✓ | at boot, on the UI thread today | on first ask | at boot | `Session` `:booting` on a pool thread |
| Conversation readable from `History` with no agent yet | | | ✓ | | `Session` in `:new` |
| `submit` while idle starts a turn; while running injects | ✓ | ✓ | queues (incidental) | — | `Session#submit` |
| Synchronous answer to `submit` (`:started`/`:injected`/`:discarded`) | ✓ (404, drops stashed images) | | | — | `Session#submit` |
| Attachments on submit and on injection | ✓ | ✓ | | pikuri-chat | both |
| Which model the *next* turn reaches, and its modalities, thread-safely | ✓ (status bar) | ✓ (attachment check) | | — | `Session#status` |
| Host-scheduled system injection + bare turn while idle (`/skill`) | | ✓ | | pikuri-code | `Session#inject_system` |
| Leftovers at turn end restart a turn — after a normal end only | ✓ (`D_interloper_mid_loop_input`) | ✓ | | — | turn task |
| Cancel keeps undelivered injections | ✓ keeps | re-sends as a turn | drops | — | `Session#cancel` + host choice |
| Cancel releases a parked confirmation | | ✓ (`cancel_pending!`) | ✓ (polls token) | — | the Confirmer watches the token |
| Model switch last-wins, re-pickable, applied between turns, never lost | ✓ | ✓ | — | — | `Session#switch_model` + `Agent#transport=` |
| Save before going idle ("idle means saved"), also after cancel/failure | ✓ | — | ✓ | — | `on_turn_end:` hook |
| Delete: atomically refuse if busy (409), else retire; no save after | ✓ | — | cancel then delete | — | `Session#close` |
| Clear refused while running | — | ✓ | — | pikuri-code | `Session#clear` |
| Errors reach the UI with their class (`EmptyTurnError`, `UnsupportedAttachmentError`, other) | wants it | ✓ | ✓ | — | `TurnEnded` event |
| Turn thread named per conversation; per-turn thread priority | ✓ (`D_puma_thread_dump`) | | ✓ (−3, `R_gvl_main_loop`) | — | `SessionList` |
| Shutdown without waiting / with a timeout | ✓ no wait | quits | cancel+join | — | `SessionList#shutdown` |
| Side LLM calls (titler) on the shared executor, throttled | ✓ | | ✓ | — | `SessionList#executor`, `around_request: list.around_request` |
| Throttle covers sub-agents, the titler, the MCP Thinker | ✓ | ✓ | ✓ | — | `Agent.new(around_request:)`, passed on by each builder |
| Status snapshot read under the host's own lock | ✓ (`status_data`) | | | — | `Session#status` |
| Lock order host lock → pool lock → `Interloper` lock | ✓ | | ✓ | — | pool never calls out under its lock |

Refused: a routing hook in `submit` for "a message typed while a confirmation is pending
redirects it" (Puri). The host does `confirmer.redirect(text) || session.submit(text)`;
`redirect` is atomic and answers `false` once the confirmation is gone.

## `Agent` — the shape

```ruby
agent = Pikuri::Agent.new(transport:, system_prompt:, cancellable: nil, id: '', streaming: false) do |c|
  c.add_tool(...); c.add_listener(...); c.add_extension(...); c.on_close { ... }
end
answer = agent.run_loop('how do I keep an avocado?', attachments: [])  # => final assistant text
agent.transport = other                 # switch, between turns only
```

**Constructor**

| kwarg | Change |
|---|---|
| `transport:` | stated facts only — `context_window`, `modalities`; `Agent` never probes |
| `system_prompt:` | unchanged |
| `cancellable:` | unchanged — shared down to sub-agents; the caller resets it per turn |
| `around_request:` | **done** — `call(api_base, cancellable) { request }`, shared down to sub-agents like `cancellable:` |
| `interloper:` | **dropped** — every agent owns one (`agent.interloper` never `nil`); every caller passes `Interloper.new` today |
| `id:` | unchanged (sub-agent tool only) |
| `streaming:` | unchanged |

**Public methods**

| Method | Behaviour | Change |
|---|---|---|
| `run_loop(user_message = nil, attachments: [])` | one turn: drain the `Interloper`, append the message, `complete`; blank = bare turn | positional message; **returns the final assistant text** (replaces `last_assistant_content`, whose three callers read it right after); **`transport:` kwarg dropped** |
| `transport` / `transport=` | the current transport; the writer switches between turns, emits `ModelSwitched` + `ContextCap`. A transport differing only in stated facts (cap, modalities) emits `ContextCap` alone | **new writer** — replaces `run_loop(transport:)`, so a switch is never lost to a turn that dies before its top |
| `clear_conversation`, `export_history`, `load_history!`, `close`, `trifecta` | as today | — |
| `tools`, `sub_agent_tools`, `extensions`, `cancellable`, `interloper`, `streaming` | readers, as today | — |
| `context_window_cap`, `modalities` | — | **dropped**: `transport.context_window` / `transport.modalities` |
| `model`, `system_prompt`, `last_assistant_content` | — | **dropped**: no non-spec callers, or `run_loop`'s return |

Errors unchanged: `Cancellable::Cancelled`, `EmptyTurnError`, `UnsupportedAttachmentError` (from the
transport's stated modalities; unknown goes out).

**The one new seam: `Agent.new(around_request:)`** (done), a callable
`call(api_base, cancellable) { request }` that `Agent`'s ruby_llm instrumenter runs around every
HTTP request (the only seam that brackets exactly one, `pikuri:D_llm_request_throttle`). Default
`nil`: no instrumenter installed. On the agent rather than the transport, so a model switch can't
drop it and a fresh lambda can't break `ChatTransport#==`; `api_base` is handed per call because
a switch may change server. Not inherited by itself: `SubAgentTool` passes `parent.around_request`;
the MCP Thinker must pass `c.around_request` (a `Configurator` reader) — **not done yet**, so a
Thinker runs unthrottled until it does. The throttle is one object per list, not per server: it
looks up its permits by `api_base`.

**Leaves `Agent`**: `ServerPermits` and `RequestThrottle` — **deleted from pikuri**, recover them
for the `SessionList` gem with `git show 5c87269:pikuri-core/lib/pikuri/agent/server_permits.rb`
(likewise `request_throttle.rb`, `spec/pikuri/agent/{server_permits,request_throttle,throttle_integration}_spec.rb`,
and `D_probe_when_unknown` in `design/decisions.md`, the reasoning for re-seeding slots from the
probe). The probe no longer seeds slots and is skipped once cap + modalities are stated. Still to
go: the `/props` probe call (`detect_and_emit_context_cap!`,
`@cap_pending`) goes. `ContextWindowDetector` itself stays in core as a transport utility
(`Q_detector_home`) — a bin resolves its transport at boot in one visible line.

**Stays**: the `Interloper` — not only host plumbing: `Skill::Extension#schedule_load_skill`
queues through it in pikuri-code's single-threaded REPL. `Extension`, `Configurator`,
`ExtensionContext`, listeners — unchanged; listeners stay read-only.

## `SessionList` and `Session` — the shape

```ruby
list = SessionList.new(
  system_prompt: ->(session) { prompt },               # String or per-session proc
  configure: ->(c, session) { c.add_tool(...) },        # the Agent.new block, minus what the pool owns
  on_turn_end: ->(session, history) { store.save(session.id, history) },  # optional
  streaming: true, priority: 0, executor: nil)         # nil: an own CachedThreadPool
list.limit('http://localhost:8080', 1)                 # the throttle, ex-ServerPermits.limit
session = list.open(id:, transport:, listener:, history: nil, boot: true)
session.submit('how do I keep an avocado?')            # => :started
session.submit('also, ripe?')                           # => :injected
```

**`SessionList`**

| Method | Behaviour |
|---|---|
| `new(system_prompt:, configure:, on_turn_end: nil, streaming: true, priority: 0, executor: nil)` | the pool builds every `Agent` itself, wiring what it owns — `cancellable:`, the forwarding listener, its `around_request` — then calls `configure`. `priority` is each turn thread's |
| `open(id:, transport:, listener:, history: nil, boot: true)` → `Session` | a conversation. `listener` hears the agent's events and the session's, fixed for its life. `boot: false` leaves it in `:new` until the first `submit` (Puri) |
| `[](id)`, `each` | lookup |
| `limit(server, permits)` | an explicit permit count, overriding the probe's `total_slots` |
| `around_request` | the list's throttle, for side agents the host builds (titler); `open` wires it itself |
| `executor` | for host side work (titler) on the same threads |
| `shutdown(timeout: 0)` | cancel every turn; running turns unwind, run `on_turn_end`, close their agents; waits at most `timeout`, never on a host lock. `0` returns at once (webui's Puma `:state` hook) |

**`Session`** — every method is thread-safe, returns at once, never calls out under the pool's lock.

| Method | Behaviour |
|---|---|
| `submit(text = nil, attachments: [])` | `:new`: boot, queue it → `:started`. `:booting`: queued → `:started`. `:idle`: start a turn → `:started`. `:running`: inject → `:injected`. Blank while running → `:ignored`; blank while idle → a bare turn delivering pending injections. `:closed` → `:discarded`. Raises `UnsupportedAttachmentError` synchronously when the next model's stated modalities refuse one |
| `inject_system(text)` | inject a reference block; if idle, start a bare turn to deliver it (tui/pikuri-code `/skill`). Same answers as `submit` |
| `cancel` | `:booting`: cancels construction (the token reaches MCP synthesis). `:running`: `cancel!`. Undelivered injections **stay** (webui's `D_interloper_mid_loop_input`) — the host decides: a blank `submit` re-sends them (tui), `discard_pending` drops them (Puri) |
| `pending` / `discard_pending` | snapshot / take-and-clear of the undelivered `Interloper::Item`s |
| `switch_model(transport)` | last-wins; re-picking the current model clears the pending one. Applied at the next turn's start via `Agent#transport=`. → `:selected` / `:discarded` |
| `clear` | `:idle` → `:cleared`; running → `:busy` |
| `close(force: false)` | idle or `:new` → close the agent, `:closed`. Running → `:busy`, or with `force` cancel and close once it unwinds. Once closing, `on_turn_end` is **not** called — a delete never races a save |
| `status` → `Status` | frozen snapshot: `state`, `pending` count, `model` (what the agent is on), `next_model` (pending or current) — each a transport, so its `modalities` / `context_window` ride along. Readable under the host's lock |
| `history` | the last snapshot — from `open`, or the last `on_turn_end` |
| `trifecta` | `nil` until booted |
| `id`, `listener` | as opened |

**State machine**, guarded by the pool's lock:
`:new → :booting → :idle ⇄ :running → :closed`. A message arriving in `:new`/`:booting` goes into
the agent-to-be's `Interloper`; the first turn after boot is a bare turn that drains it — one
queue, not two.

**The turn task**, on a pool thread:

1. Under the lock, whoever moves the session to `:running` — `submit` on the caller's thread, or
   the restart in step 6 on the worker — resets the `Cancellable` in the same critical section,
   so no cancel can fall between (`pikuri:D_host_resets_cancel`).
2. Name the thread `turn <id>`, set its priority.
3. Take the pending model switch; probe `/props` if this transport hasn't been (cached per
   server+model, seeds the throttle's slots, `pikuri:D_deferred_cap_probe`'s reason intact);
   `agent.transport = resolved`.
4. `agent.run_loop(...)`, rescuing `Cancelled` and `StandardError` into an outcome.
5. Unless closing: `on_turn_end.(session, agent.export_history)` — on the worker, off the lock,
   before going idle, for every outcome.
6. Under the lock: completed **and** `interloper.pending?` and not closing → stay `:running`,
   reset, loop as a bare turn; else `:idle` (or `:closed`). Then emit `TurnEnded`.

**Session events** (alongside the agent's, on the session's listener, never under the pool's lock):
`Booting`, `Ready(trifecta:)`, `BootFailed(error:)`, `TurnStarted(user_message:, attachments:)`
(before the probe, so a UI shows the message during a cold model load), `PendingChanged(count:)`
(the pool owns `Interloper#on_change`), `ModelPending(transport:)` (`nil` = cleared),
`CancelRequested`, `TurnEnded(outcome: :completed|:cancelled|:failed, error:, restarting:)` (after
`on_turn_end`), `Closed`.

## How each host reads

- **webui**: `Runner` and `claim_running`/`finish_turn` go; `Registry` keeps sessions;
  `on_turn_end` persists (idle still means saved); `discard!` is `close` → `:busy` → 409;
  `status_data` is `session.status`; the titler passes `around_request: list.around_request` on
  `list.executor` and can move to `TurnEnded` (`titler-first-turn-permit.md`); `ServerPermits.limit`
  is `list.limit`. Must also drop `Listener::RateLimited` (removed from pikuri in 613103e).
- **tui**: `AgentSession`'s flag, `deliver_pending_injections` and the picker's `take_pending` go;
  one session, `boot: true`, so MCP synthesis leaves the UI thread and becomes cancellable;
  Ctrl+C → `cancel`, then a blank `submit` re-sends the correction; errors arrive as `TurnEnded`.
  The listener still marshals through `event_queue.submit`.
- **Puri**: `Conversation`'s `@turn`/`@waiting` go; `boot: false` keeps "readable before an agent";
  `on_turn_end` saves; injection replaces queueing, so its `TurnListener` must render
  `UserTurn(mid_loop: true)` as a block; cancel drops via `discard_pending`; `core.close` becomes
  `shutdown(timeout:)` instead of a thread kill. Its dummy backend (`turns:` strategy) stays
  outside the pool — the GTK specs keep their own fake.
- **bins**: unchanged in shape, slightly simpler — `run_loop(message)` returns the answer, a
  model switch is `agent.transport =`, the cap needs a stated or boot-resolved transport.

## Settled

- **Sub-agents stay plain `Agent#run_loop` calls, inline on the parent's thread**, sharing the
  parent's cancel token — never submitted to the pool and awaited, which deadlocks a bounded pool.
- **The executor is unbounded** (`CachedThreadPool`, `pikuri-webui:D_serial_turn_executor`): a turn
  holds its thread through waits that aren't load — a `Confirmer` on a human, a long `bash`.
- **Load is bounded per request by the throttle**, never per turn (`pikuri:D_llm_request_throttle`).
- **The pool never calls out under its own lock** — no listener, no hook, no host code; webui's
  listeners take its global monitor (`pikuri-webui:D_global_monitor`). It owns
  `Interloper#on_change` for the same reason: `enqueue` fires it on the injecting thread, which
  holds the pool's lock during a mid-turn `submit`.
- **A plain state machine, not `Concurrent::SerializedExecution`.** With `submit` injecting, no
  second turn ever queues, so per-key serialization only duplicates the `running` flag — and
  once anything queues behind a turn, a reset at post time wipes the running turn's cancel.
- **No idle eviction**: an agent lives until `close`. Closing and rebuilding from `History` loses
  state outside it (Tasks' list, Skill activations, MCP `mcp_connect`s), and webui rejected
  reaping already.
- **`Agent` stays thread-unsafe**; the two `Control`s remain the only doors in from another thread.

## Superseded

- **`Agent::Runner` in pikuri-core** (an immutable `Agent` template, a turn queue, futures): put
  thread plumbing and concurrent-ruby into every deployment, and stayed agent-centric. Kept in
  reach: if a cancel ever must be safe in a SIGINT trap, make it a bare field write on a per-turn
  handle that `check!` reads — no reset, no stale cancel.
- **Cancel drains and hands the text back**: no host can put text back into its input, and webui
  decided against draining (it discards text the user typed and never saw rendered).
- **The throttle as an `Extension` hook with `for_sub_agent`**: misses the agents no extension
  reaches — the titler, the MCP Thinker.

## Open questions

- `Q_detector_home` — `ContextWindowDetector` stays in core as a utility bins call at boot, or
  moves to the gem with the throttle (then bins state their cap or show none).
- `Q_probe_at_boot` — probing in step 3 keeps a router from loading a model the conversation
  never uses, but then `status.next_model.modalities` is unknown before the first turn, so an
  attachment can fail only inside the turn (`TurnEnded(:failed, UnsupportedAttachmentError)`).
  Probe at `:booting` instead, cached per model?
- `Q_replay` — webui's `HistoryReplay` and Puri's Replay both turn a `History` into display
  events, and webui's duplicates the dangling-call repair. A pure `History#events` in core,
  usable with no agent?
- `Q_listener_swap` — listeners are fixed at `Agent.new`; webui keeps a detached conversation's
  15 fps timer alive. A session-level listener swap is cheap (the pool owns the forwarder).
- `Q_confirmer_token` — pikuri-code's `Confirmer` should watch the cancel token as Puri's does, so
  `cancel` needs no host hook; a pikuri-code change, not the pool's.
- `Q_thread_hopping` — a conversation's turns hop pool threads; check `Subprocess`, `Finalizers`,
  the LSP client for `Thread.current` affinity.
- `Q_book` — the chapter: lost cancels, stranded injections, a lock-order inversion around a
  synchronous core.
- `Q_permit_scope` — `list.limit` makes the permit registry per list, where
  `pikuri:D_rate_limiter_scope` says one per process, keyed by server: two lists against one
  llama.cpp would each hand out its slots. Keep the registry process-global inside the gem, or
  record why per-list is fine.
- `Q_naming` — `SessionList` / `Session`, and the gem's name, per pikuri's "name a gem after
  what it refuses to become".

## Done when

- pikuri's `Agent` has the shape above, its bins and the workshop's bins follow, and pikuri's
  `D_llm_request_throttle` (done) and `D_deferred_cap_probe` say where those moved.
- The gem exists; pikuri-tui (first — one conversation, the cheapest test), then pikuri-webui,
  then Puri drive their conversations through it, their own turn state machines gone.
- The nuggets land in durable homes: the threading model and the conversation/agent split in the
  gem's `design/architecture.md`; why two layers, why the workshop, why the pool is shaped so as
  `D_` entries; the chapter in `book/`. Then this file is deleted.
