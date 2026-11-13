# A slim `Agent` and `pikuri-conversations`: one design, two layers

Status: **shape settled; `Conversations::HistoryFile` and `Store` built, the scheduler and the
throttle not.** pikuri has done its half: an `Agent` is one conversation, resumed through
`Agent.new(history:)` (`pikuri:D_agent_is_one_conversation`); `History` is in-memory only; every
agent owns its `Interloper`; and `Agent.new(around_request:)` replaced `ServerPermits`, which is
deleted — the throttle is ours to build. Grew out of pikuri's early-cancel fix
(`pikuri:D_host_resets_cancel`). Covers both layers because they are one design:
what leaves `Agent` is what `pikuri-conversations` takes.

## The problem

**Hosts rebuild the same scheduler around `Agent`.** `Agent#run_loop` is a blocking,
thread-unsafe call with rules attached: serialize every call; reset the `Cancellable` under the
lock guarding your "running" flag as you start a turn, never later on the worker
(`pikuri:D_host_resets_cancel`); route a mid-turn message to the `Interloper`; start a turn for
injections left over at turn end; apply a model switch only between turns; never clear or load
mid-turn. pikuri-webui's `Runner`, pikuri-tui's `AgentSession` and Puri's `Conversation` each
implement this, each a little differently. None of the three calls `Cancellable#reset!` yet —
all pin a pikuri from before `D_host_resets_cancel` — so a pin bump alone breaks cancel in each.

**They rebuild the rest of hosting too.** webui's `Conversations::Store` (512 lines) and Puri's
`Core::Store` (206) write the same folder format; each has a titler.

**`Agent` had absorbed what hosts wanted** — the permit registry, the request throttle, a
history serializer, clear and load on a live agent. pikuri has since shed all four; what they did
for hosts is this gem's to do.

## Direction: two layers, and the rule that splits them

- **`Agent` (pikuri-core) is the synchronous agentic loop**: what pikuri's `bin/` scripts, specs,
  sub-agents and one-off callers (the MCP Thinker, a titler) use. Simple enough to demo, and
  extensible through a small, closed set of seams.
- **`pikuri-conversations` (a workshop gem) hosts many conversations asynchronously**: it owns
  the threads, the turn state machine, the throttle, the `/props` probe, the folder of saved
  conversations and the titler. Conversation-centric: for the user the conversation *is* the
  agent. concurrent-ruby is its dependency, never core's.
- **The rule: a piece leaves `Agent` if it only matters when something else runs at the same
  time, or across many conversations.** One `bin/` script has neither: tools run one at a time
  (`tool_concurrency` off), sub-agents run inline, so one agent tree sends one request at a time;
  and a bin holds one conversation. Anything a single bin needs stays in core.
- **What can't leave**: most of `agent.rb` is loop correctness every caller needs — answering
  dangling tool calls, withholding foreign thinking, the empty-turn guard, the
  `<system-reminder>` envelope, `History` metadata. The scheduler never sees inside a turn.
  Expect `agent.rb` to lose ~150 lines and core ~700, not a rewrite.

Why the workshop: pikuri grows by explaining better, never by gaining features — a scheduler is
a feature. Nothing in pikuri requires a workshop gem; the hosts depend on this one.

Why one gem and not a grab-bag (`pikuri-ext`): the rule above is what it refuses — a UI, an HTTP
server, a database, and anything one bin needs. A utility that fails the rule finds another
home. Its parts stay independent inside it: `Conversations` never references `Store`; the host
joins them in one `on_turn_end` line.

## Where each piece lands

| Piece | Today | Lands in | Why |
|---|---|---|---|
| `ServerPermits` + `RequestThrottle` | deleted from pikuri (`8d764bd`) | `Conversations::Throttle`, passed as `Agent.new(around_request:)` | only N concurrent trees need it |
| sizing permits from `/props` `total_slots` | pikuri's probe did it | the throttle, probing once per server | pikuri's probe no longer seeds slots |
| `ContextWindowDetector` | pikuri-core | stays (`Q_detector_home`) | a bin resolves its cap at boot in one line |
| `History`, the value | pikuri-core | stays | `export_history` / `Agent.new(history:)` speak it |
| its JSON, `save(dir)` / `load(dir)`, `Attachment#stored_name` | dropped from pikuri (`5c87269`) | `Conversations::HistoryFile` — **built** (`D_history_file`) | storing is the host's; a deployment that never resumes shouldn't carry a format |
| the folder of conversations: ids, `meta.json`, list, retitle, delete, upload stash | webui `Store`, Puri `Store` | `Conversations::Store` — **built** | two copies of one format; a bin holds one conversation |
| the titler | webui, Puri `Core::Titler` | `Conversations::Titler` | side calls on the shared executor, through the throttle |
| replay (`History` → display events) | webui `HistoryReplay`, Puri `Replay` | core, `History#events` (`Q_replay`) | needs neither concurrency nor many conversations |

## What the callers need

webui is the reference host; Puri was written hastily, so a Puri quirk is evidence of what it
does, not of what it needs.

| Need | webui | tui | Puri | bins | Lands in |
|---|---|---|---|---|---|
| One agent per conversation, never reused across conversations | ✓ | ✓ (one) | ✓ | ✓ (one) | `Conversations` |
| Agent built at view, off the host's lock (no I/O under webui's monitor) | ✓ | at boot, on the UI thread today | on first ask | at boot | `Conversation` `:booting` on a pool thread |
| Conversation readable from `History` with no agent yet | | | ✓ | | `Conversation` in `:new` |
| `submit` while idle starts a turn; while running injects | ✓ | ✓ | queues (incidental) | — | `Conversation#submit` |
| Synchronous answer to `submit` (`:started`/`:injected`/`:discarded`) | ✓ (404, drops stashed images) | | | — | `Conversation#submit` |
| Attachments on submit and on injection | ✓ | ✓ | | pikuri-chat | both |
| Which model the *next* turn reaches, and its modalities, thread-safely | ✓ (status bar) | ✓ (attachment check) | | — | `Conversation#status` |
| Host-scheduled system injection + bare turn while idle (`/skill`) | | ✓ | | pikuri-code | `Conversation#inject_system` |
| Leftovers at turn end restart a turn — after a normal end only | ✓ (`D_interloper_mid_loop_input`) | ✓ | | — | turn task |
| Cancel keeps undelivered injections | ✓ keeps | re-sends as a turn | drops | — | `Conversation#cancel` + host choice |
| Cancel releases a parked confirmation | | ✓ (`cancel_pending!`) | ✓ (polls token) | — | the Confirmer watches the token |
| Model switch last-wins, re-pickable, applied between turns, never lost | ✓ | ✓ | — | — | `Conversation#switch_model` + `Agent#transport=` |
| Save before going idle ("idle means saved"), also after cancel/failure | ✓ | — | ✓ | — | `on_turn_end:` hook → `Store#save` |
| Saved conversations: list, open, retitle, delete; images on disk before the turn | ✓ | — | ✓ | — | `Store` |
| Delete: atomically refuse if busy (409), else retire; no save after | ✓ | — | cancel then delete | — | `Conversation#close`, then `Store#delete` |
| Clear refused while running | — | ✓ | — | pikuri-code | `Conversation#clear` |
| Errors reach the UI with their class (`EmptyTurnError`, `UnsupportedAttachmentError`, other) | wants it | ✓ | ✓ | — | `TurnEnded` event |
| Turn thread named per conversation; per-turn thread priority | ✓ (`D_puma_thread_dump`) | | ✓ (−3, `R_gvl_main_loop`) | — | `Conversations` |
| Shutdown without waiting / with a timeout | ✓ no wait | quits | cancel+join | — | `Conversations#shutdown` |
| Side LLM calls (titler) on the shared executor, throttled | ✓ | | ✓ | — | `Titler` on `Conversations#executor` |
| Throttle covers sub-agents, the titler, the MCP Thinker | ✓ | ✓ | ✓ | — | `Agent.new(around_request:)`, passed on |
| Status snapshot read under the host's own lock | ✓ (`status_data`) | | | — | `Conversation#status` |
| Lock order host lock → gem lock → `Interloper` lock | ✓ | | ✓ | — | the gem never calls out under its lock |

Refused: a routing hook in `submit` for "a message typed while a confirmation is pending
redirects it" (Puri). The host does `confirmer.redirect(text) || conversation.submit(text)`;
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
| `transport:` | stated facts only — `context_window`, `modalities`; `Agent` never probes. Carries `around_request` |
| `system_prompt:` | unchanged |
| `cancellable:` | unchanged — shared down to sub-agents; the caller resets it per turn |
| `interloper:` | **dropped — done** (`9174dd2`): every agent owns one |
| `history:` | **new — done** (`a31c2eb`): resume a conversation; the only way, since there is no `load_history!` |
| `around_request:` | **new — done** (`8d764bd`): called around each HTTP request with the dialed `api_base` and the agent's `Cancellable`; the `agent` tool passes it to children, `c.around_request` hands it to an extension building its own agent |
| `id:` | unchanged (sub-agent tool only) |
| `streaming:` | unchanged |

**Public methods**

| Method | Behaviour | Change |
|---|---|---|
| `run_loop(user_message = nil, attachments: [])` | one turn: drain the `Interloper`, append the message, `complete`; blank = bare turn | positional message; **returns the final assistant text** (replaces `last_assistant_content`, whose three callers read it right after); **`transport:` kwarg dropped** — not done in pikuri yet |
| `transport` / `transport=` | the current transport; the writer switches between turns, emits `ModelSwitched` + `ContextCap`. A transport differing only in stated facts (cap, modalities) emits `ContextCap` alone | **new writer** — replaces `run_loop(transport:)`, so a switch is never lost to a turn that dies before its top |
| `export_history`, `close`, `trifecta` | as today | `clear_conversation` and `load_history!` **gone — done** (`a31c2eb`) |
| `tools`, `sub_agent_tools`, `extensions`, `cancellable`, `interloper`, `streaming` | readers, as today | — |
| `context_window_cap`, `modalities` | — | **dropped**: `transport.context_window` / `transport.modalities` |
| `model`, `system_prompt`, `last_assistant_content` | — | **dropped**: no non-spec callers, or `run_loop`'s return |

Errors unchanged: `Cancellable::Cancelled`, `EmptyTurnError`, `UnsupportedAttachmentError` (from the
transport's stated modalities; unknown goes out).

**The throttle seam is `Agent.new(around_request:)`** (shipped, `pikuri:D_llm_request_throttle`):
`call(api_base, cancellable) { request }`, run by `Agent::RequestInstrumenter` around exactly one
`request.ruby_llm` event. `around`, not a `before`/`after` pair: a permit must be released when a
request raises, is cancelled, or streams for 20 s. On the agent rather than the transport, so a
model switch can't drop it and a fresh lambda can't break `ChatTransport#==`; `api_base` is
handed per call because a switch may change server. The throttle is one object per list, not per
server: it looks up its permits by `api_base`. Not inherited by itself: `SubAgentTool` passes
`parent.around_request`. **To do**: the MCP `Thinker` builds its one-shot agent without it, so
its boot-time calls run unthrottled — thread `c.around_request` (a `Configurator` reader) through
`Extension` → `Synthesizer`/`Verifier` → `Thinker`, as a host's titler must too.

**Recovering the old throttle**: `ServerPermits` and `RequestThrottle` are deleted from pikuri;
`git show 5c87269:pikuri-core/lib/pikuri/agent/server_permits.rb` (likewise
`request_throttle.rb`, `spec/pikuri/agent/{server_permits,request_throttle,throttle_integration}_spec.rb`,
and `D_probe_when_unknown` in pikuri's `design/decisions.md`, the reasoning for re-seeding slots
from the probe). pikuri's probe no longer seeds slots and is skipped once cap + modalities are
stated.

**Stays**: the `Interloper` — not only host plumbing: `Skill::Extension#schedule_load_skill`
queues through it in pikuri-code's single-threaded REPL. `Extension`, `Configurator`,
`ExtensionContext`, listeners — unchanged; listeners stay read-only.

## `pikuri-conversations` — the shape

`Pikuri::Conversations` is the gem's root constant *and* the list class, as `Pikuri::Agent` is a
class with `Agent::History` inside. A `History` is a conversation as a value; a `Conversation` is
the live one — an agent and a turn state. "Session" was rejected: in webui it reads as the HTTP
one.

```ruby
store = Pikuri::Conversations::Store.new(root:, shell: 'pikuri-webui-chat')
convs = Pikuri::Conversations.new(
  system_prompt: ->(conv) { prompt },                  # String or per-conversation proc
  configure: ->(c, conv) { c.add_tool(...) },           # the Agent.new block, minus what the gem owns
  on_turn_end: ->(conv, history) { store.save(entry, history, model:, server:) },  # optional
  streaming: true, priority: 0, executor: nil)         # nil: an own CachedThreadPool
convs.limit('http://localhost:8080', 1)                # the throttle, ex-ServerPermits.limit
conv = convs.open(id:, transport:, listener:, history: nil, boot: true)
conv.submit('how do I keep an avocado?')               # => :started
conv.submit('also, ripe?')                              # => :injected
```

**`Conversations`**

| Method | Behaviour |
|---|---|
| `new(system_prompt:, configure:, on_turn_end: nil, streaming: true, priority: 0, executor: nil)` | the gem builds every `Agent` itself, wiring what it owns — `cancellable:`, the forwarding listener, its `around_request` — then calls `configure`. `priority` is each turn thread's |
| `open(id:, transport:, listener:, history: nil, boot: true)` → `Conversation` | a conversation. `listener` hears the agent's events and the conversation's, fixed for its life. `boot: false` leaves it in `:new` until the first `submit` (Puri) |
| `[](id)`, `each` | lookup |
| `limit(server, permits)` | an explicit permit count, overriding the probe's `total_slots` |
| `around_request` | the list's throttle, for side agents the host builds (titler); `open` wires it itself |
| `executor` | for host side work (titler) on the same threads |
| `shutdown(timeout: 0)` | cancel every turn; running turns unwind, run `on_turn_end`, close their agents; waits at most `timeout`, never on a host lock. `0` returns at once (webui's Puma `:state` hook) |

**`Conversation`** — every method is thread-safe, returns at once, never calls out under the
gem's lock.

| Method | Behaviour |
|---|---|
| `submit(text = nil, attachments: [])` | `:new`: boot, queue it → `:started`. `:booting`: queued → `:started`. `:idle`: start a turn → `:started`. `:running`: inject → `:injected`. Blank while running → `:ignored`; blank while idle → a bare turn delivering pending injections. `:closed` → `:discarded`. Raises `UnsupportedAttachmentError` synchronously when the next model's stated modalities refuse one |
| `inject_system(text)` | inject a reference block; if idle, start a bare turn to deliver it (tui/pikuri-code `/skill`). Same answers as `submit` |
| `cancel` | `:booting`: cancels construction (the token reaches MCP synthesis). `:running`: `cancel!`. Undelivered injections **stay** (webui's `D_interloper_mid_loop_input`) — the host decides: a blank `submit` re-sends them (tui), `discard_pending` drops them (Puri) |
| `pending` / `discard_pending` | snapshot / take-and-clear of the undelivered `Interloper::Item`s |
| `switch_model(transport)` | last-wins; re-picking the current model clears the pending one. Applied at the next turn's start via `Agent#transport=`. → `:selected` / `:discarded` |
| `clear` | `:idle` → close the agent and build a fresh one, extensions and all (`pikuri:D_agent_is_one_conversation`) → `:cleared`; running → `:busy` |
| `close(force: false)` | idle or `:new` → close the agent, `:closed`. Running → `:busy`, or with `force` cancel and close once it unwinds. Once closing, `on_turn_end` is **not** called — a delete never races a save |
| `status` → `Status` | frozen snapshot: `state`, `pending` count, `model` (what the agent is on), `next_model` (pending or current) — each a transport, so its `modalities` / `context_window` ride along. Readable under the host's lock |
| `history` | the last snapshot — from `open`, or the last `on_turn_end` |
| `trifecta` | `nil` until booted |
| `id`, `listener` | as opened |

**State machine**, guarded by the gem's lock:
`:new → :booting → :idle ⇄ :running → :closed`. A message arriving in `:new`/`:booting` goes into
the agent-to-be's `Interloper`; the first turn after boot is a bare turn that drains it — one
queue, not two.

**The turn task**, on a pool thread:

1. Under the lock, whoever moves the conversation to `:running` — `submit` on the caller's
   thread, or the restart in step 6 on the worker — resets the `Cancellable` in the same critical
   section, so no cancel can fall between (`pikuri:D_host_resets_cancel`).
2. Name the thread `turn <id>`, set its priority.
3. Take the pending model switch; probe `/props` if this transport hasn't been (cached per
   server+model, seeds the throttle's slots, `pikuri:D_deferred_cap_probe`'s reason intact);
   `agent.transport = resolved`.
4. `agent.run_loop(...)`, rescuing `Cancelled` and `StandardError` into an outcome.
5. Unless closing: `on_turn_end.(conv, agent.export_history)` — on the worker, off the lock,
   before going idle, for every outcome.
6. Under the lock: completed **and** `interloper.pending?` and not closing → stay `:running`,
   reset, loop as a bare turn; else `:idle` (or `:closed`). Then emit `TurnEnded`.

**Conversation events** (alongside the agent's, on the conversation's listener, never under the
gem's lock): `Booting`, `Ready(trifecta:)`, `BootFailed(error:)`,
`TurnStarted(user_message:, attachments:)` (before the probe, so a UI shows the message during a
cold model load), `PendingChanged(count:)` (the gem owns `Interloper#on_change`),
`ModelPending(transport:)` (`nil` = cleared), `CancelRequested`,
`TurnEnded(outcome: :completed|:cancelled|:failed, error:, restarting:)` (after `on_turn_end`),
`Closed`.

**`Store`** (built): one folder per conversation under a root — pikuri's `history.json` and
`attachments/` beside the store's `meta.json`, schema 1, the format webui and Puri already
write. Webui's shape, as the reference host: a `Store::Entry` value, `find` through the listing,
an unreadable envelope listed as `supported: false`, the upload `stash`. From Puri: `history`, and
`extra:` keys on `meta.json` (its `last_question`, `asked_at`).

**`Titler`**: not yet ported; webui's and Puri's to be compared first.

## How each host reads

- **webui**: `Runner` and `claim_running`/`finish_turn` go; `Registry` keeps conversations;
  `on_turn_end` persists through `Store` (idle still means saved); `discard!` is `close` →
  `:busy` → 409; `status_data` is `conversation.status`; the titler is the gem's, on
  `convs.executor` (`titler-first-turn-permit.md`); `ServerPermits.limit` is `convs.limit`. Its
  `Conversations::Store` and `Store::Conversation` go — mind its own `Conversations` module
  beside `Pikuri::Conversations`. Must also drop `Listener::RateLimited` (removed from pikuri in
  613103e).
- **tui**: `AgentSession`'s flag, `deliver_pending_injections` and the picker's `take_pending` go;
  one conversation, `boot: true`, so MCP synthesis leaves the UI thread and becomes cancellable;
  Ctrl+C → `cancel`, then a blank `submit` re-sends the correction; errors arrive as `TurnEnded`.
  The listener still marshals through `event_queue.submit`. No `Store`.
- **Puri**: `Conversation`'s `@turn`/`@waiting` go; `boot: false` keeps "readable before an
  agent"; `on_turn_end` saves through `Store` (its unreadable envelopes now list as unsupported
  rather than log-and-skip); injection replaces queueing, so its `TurnListener` must render
  `UserTurn(mid_loop: true)` as a block; cancel drops via `discard_pending`; `core.close` becomes
  `shutdown(timeout:)` instead of a thread kill. Its dummy backend (`turns:` strategy) stays
  outside the gem — the GTK specs keep their own fake.
- **bins**: unchanged in shape, slightly simpler — `run_loop(message)` returns the answer, a
  model switch is `agent.transport =`, the cap needs a stated or boot-resolved transport.

## Settled

- **Sub-agents stay plain `Agent#run_loop` calls, inline on the parent's thread**, sharing the
  parent's cancel token — never submitted to the pool and awaited, which deadlocks a bounded pool.
- **The executor is unbounded** (`CachedThreadPool`, `pikuri-webui:D_serial_turn_executor`): a turn
  holds its thread through waits that aren't load — a `Confirmer` on a human, a long `bash`.
- **Load is bounded per request by the throttle**, never per turn (`pikuri:D_llm_request_throttle`).
- **The gem never calls out under its own lock** — no listener, no hook, no host code; webui's
  listeners take its global monitor (`pikuri-webui:D_global_monitor`). It owns
  `Interloper#on_change` for the same reason: `enqueue` fires it on the injecting thread, which
  holds the gem's lock during a mid-turn `submit`.
- **A plain state machine, not `Concurrent::SerializedExecution`.** With `submit` injecting, no
  second turn ever queues, so per-key serialization only duplicates the `running` flag — and
  once anything queues behind a turn, a reset at post time wipes the running turn's cancel.
- **No idle eviction**: an agent lives until `close`. Closing and rebuilding from `History` loses
  state outside it (Tasks' list, Skill activations, MCP `mcp_connect`s), and webui rejected
  reaping already.
- **`Agent` stays thread-unsafe**; the two `Control`s remain the only doors in from another thread.
- **Naming**: the gem `pikuri-conversations`; `Conversations` / `Conversation`, not
  `SessionList` / `Session` (an HTTP session) nor `pikuri-host` (it hosts nothing by itself).

## Superseded

- **`Agent::Runner` in pikuri-core** (an immutable `Agent` template, a turn queue, futures): put
  thread plumbing and concurrent-ruby into every deployment, and stayed agent-centric. Kept in
  reach: if a cancel ever must be safe in a SIGINT trap, make it a bare field write on a per-turn
  handle that `check!` reads — no reset, no stale cancel.
- **Cancel drains and hands the text back**: no host can put text back into its input, and webui
  decided against draining (it discards text the user typed and never saw rendered).
- **The throttle as an `Extension` hook with `for_sub_agent`**: misses the agents no extension
  reaches — the titler, the MCP Thinker.
- **A grab-bag `pikuri-ext` for utilities**: refuses nothing, and charges every host the union
  of every utility's dependencies.

## Open questions

- `Q_detector_home` — `ContextWindowDetector` stays in core as a utility bins call at boot, or
  moves to the gem with the throttle (then bins state their cap or show none).
- `Q_probe_at_boot` — probing in step 3 keeps a router from loading a model the conversation
  never uses, but then `status.next_model.modalities` is unknown before the first turn, so an
  attachment can fail only inside the turn (`TurnEnded(:failed, UnsupportedAttachmentError)`).
  Probe at `:booting` instead, cached per model?
- `Q_replay` — leaning to a pure `History#events` in core, usable with no agent; webui's
  `HistoryReplay` duplicates the dangling-call repair.
- `Q_listener_swap` — listeners are fixed at `Agent.new`; webui keeps a detached conversation's
  15 fps timer alive. A conversation-level listener swap is cheap (the gem owns the forwarder).
- `Q_confirmer_token` — pikuri-code's `Confirmer` should watch the cancel token as Puri's does, so
  `cancel` needs no host hook; a pikuri-code change, not the gem's.
- `Q_thread_hopping` — a conversation's turns hop pool threads; check `Subprocess`, `Finalizers`,
  the LSP client for `Thread.current` affinity.
- `Q_titler` — webui's and Puri's titlers side by side: prompt, when it fires (first turn end?),
  how it reports back.
- `Q_permit_scope` — `convs.limit` makes the permit registry per list, where
  `pikuri:D_rate_limiter_scope` says one per process, keyed by server: two lists against one
  llama.cpp would each hand out its slots. Keep the registry process-global inside the gem, or
  record why per-list is fine.
- `Q_book` — the chapter: lost cancels, stranded injections, a lock-order inversion around a
  synchronous core.

## Done when

- pikuri's `Agent` has the shape above, its bins and the workshop's bins follow, and pikuri's
  `D_llm_request_throttle` (done) and `D_deferred_cap_probe` say where those moved.
- `pikuri-conversations` holds the scheduler, the throttle, `HistoryFile`, `Store` and `Titler`; pikuri-tui
  (first — one conversation, the cheapest test), then pikuri-webui, then Puri drive their
  conversations through it, their own turn state machines and stores gone.
- The workshop's pitch (`README.md`, `AGENTS.md`'s "What this is") covers a gem that runs no
  foreign code and needs no cage, as pikuri-tasks already doesn't.
- The nuggets land in durable homes: the threading model and the conversation/agent split in the
  gem's `design/architecture.md`; why two layers, why the workshop, why one gem, why the
  scheduler is shaped so as `D_` entries; the chapter in `book/`. Then this file is deleted.
