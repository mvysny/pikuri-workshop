# pikuri-conversations architecture

How the gem's pieces compose: the threads, the one lock, and the flows a host sees. **Normative:
the code conforms.** Change this file first, then the code. Not here: why (the workshop's
`design/decisions.md`, cited `D_`), one symbol's behaviour (its YARD header), what the stored
files hold (`HistoryFile` and `Store`, `D_history_file`, `D_history_container`,
`D_history_attachments`). Cap 12 KB.

## Wiring

- **Two layers.** pikuri's `Agent` is one conversation, synchronous and thread-unsafe
  (`pikuri:D_agent_is_one_conversation`); this gem hosts many, asynchronously. What a host had to
  rebuild around `Agent` lives here once (`D_conversations_gem`). Dependencies point from the
  hosts (pikuri-webui, pikuri-tui, Puri) to this gem to pikuri-core, never back.
- **The list builds every agent.** `Conversations#build_agent` wires what the gem owns — the
  conversation's `Cancellable`, the `History` it resumes, its listener, `around_request:
  Throttle` — then hands the `Configurator` to the host's `configure:` for tools and extensions.
  A host never calls `Agent.new` for a conversation.
- **The parts don't know each other.** `Conversations` and `Conversation` never reference
  `Store` or `HistoryFile`: the host joins them in `on_turn_end:`, where it saves, and in its
  listener, where `Event::Titled` meets `Store#retitle`. Whether a conversation still wants a
  name is the store's to know, so the host says so with `open(untitled:)`.
- **`Throttle` and `Probe` are process-wide modules**, not a list's objects, keyed by server
  (and model, for `Probe`): what they describe is the server, which two lists share
  (`pikuri:D_rate_limiter_scope`). `Probe.props` feeds `Throttle.default` the server's
  `total_slots`; `Throttle.limit` from the host wins over it.
- **`Throttle` is the `around_request` hook itself**, one permit per HTTP request
  (`pikuri:D_llm_request_throttle`). Agents the list doesn't build take it explicitly — the
  `Titler`'s, an MCP `Thinker`'s through `Mcp::Catalog.build(around_request:)` — or they bypass
  the queue. pikuri's `SubAgentTool` passes it on to children.
- **`Agent` never probes** (`pikuri:D_deferred_cap_probe`). The gem hands it
  `Probe.facts(transport)` — the transport with the learnt cap and modalities filled in — at
  boot and at each turn's start, and announces the cap itself with `Event::ContextCap`.
- **One listener per conversation, fixed for its life**, hears both the agent's events and the
  gem's `Event`s. A host fanning out to several panes hands a `ListenerList`;
  `RateLimitedListener` paces streamed deltas and passes the gem's events straight through.

## Threads and the lock

Every public method of `Conversation` takes the lock, changes the state, and returns at once.
The work runs on plain threads the conversation starts — one per task, never a pool
(`D_conversation_turn_state`):

| Thread | Started by | Runs |
|---|---|---|
| `boot <id>` | `open(boot: true)`, `boot`, the first `submit` of a `:new` one, a `clear` | the modalities lookup, `Agent.new`, then the first turn on the same thread if a message waits |
| `turn <id>` | `submit` while `:idle` | `run_loop`, `on_turn_end`, then bare turns while injections arrived too late |
| `title <id>` | the turn that first has a user message, if opened `untitled:` | one `Titler#title_for` |
| `close <id>` | `close`, a forced close's unwinding turn, a failed boot under close | `Agent#close` (an MCP teardown may take seconds), then `Event::Closed` |

A turn may run on its boot thread, so nothing is confined to one thread; `Agent` asks only that
calls don't overlap, which the state machine guarantees. Sub-agents run inline on the turn's
thread, sharing its `Cancellable`. Every thread is counted from before it starts to after its
last event, which is all `wait_settled` waits on.

**The one rule: nothing outside the gem is called under its lock** — no listener, no
`on_turn_end`, no `Agent#close`, no `Titler`. A critical section queues its events and its
threads (`Conversation#locked`'s `@effects` and `@spawns`), and they go out after the lock drops.
So a host may hold its own lock in a listener and read `status` under that same lock
(`pikuri-webui:D_global_monitor`). The order is **host lock → conversation lock → the agent's
`Interloper` lock**. The gem owns `Interloper#on_change` for the same reason: a mid-turn `submit`
injects under the conversation's lock, so the count change is queued like any other event.

**Whoever moves a conversation to `:running` resets its `Cancellable` in the same critical
section** — `submit` on the caller's thread, a boot that found a message waiting, a turn
restarting for late injections — so no cancel can fall between the move and the reset
(`pikuri:D_host_resets_cancel`).

**A host hook never strands the state machine.** A listener or `on_turn_end` that raises is
logged at error, and the transition goes on.

## The states

```
         boot / submit           built            submit
  :new ───────────────▶ :booting ─────▶ :idle ◀──────────▶ :running
   ▲  ◀─── boot failed ───┘   │           │   turn ended      │
   │                          └───────────┴──── close ────────┴──▶ :closed
```

- **Messages before the agent exists wait in the conversation**, since the agent builds its
  `Interloper` itself. Once built, the last waiting user message becomes the first turn's message
  and the earlier ones go into the `Interloper`, which `run_loop` drains ahead of it: the order
  holds, and the common case of one message is an ordinary turn, not a `UserTurn(mid_loop:
  true)`.
- **A failed boot returns to `:new`** keeping its messages; the next `submit` boots again.
- **`clear` builds a fresh agent** — the old one closed first, on the boot thread, so two never
  hold one MCP or language server at once. A clear landing mid-boot bumps a generation, and the
  boot builds again from the empty history.
- **`close` is refused while a turn runs**, or while a boot has a message waiting; `force: true`
  cancels and closes once the turn unwinds. The cut turn still runs `on_turn_end` — a quitting
  host keeps what was said, and a deleting host needs no guard, since `Store#delete` wins over
  every later write.

## Flows

**A turn** (the host calls `submit('hi')` on an `:idle` conversation):

1. Under the lock: `deliver` moves to `:running`, resets the `Cancellable`, queues a `turn <id>`
   thread; `submit` answers `:started`. An attachment the next model's stated or learnt
   modalities refuse raised `UnsupportedAttachmentError` before any of it.
2. The turn thread takes the pending model pick, if any, and emits `TurnStarted` — before the
   probe, so a UI shows the message through a router's cold load.
3. `Probe.props` once per server and model, unless cap, modalities and the server's permits are
   all known; `ContextCap` if the cap is news.
4. `agent.run_loop(user_message:, attachments:, transport: Probe.facts(transport))`. A picked
   model switches the chat; newly learnt facts are adopted silently. `Cancelled` and any
   `StandardError` become the outcome.
5. `export_history`, then `on_turn_end.(conv, history)` — off the lock, before going idle, for
   every outcome: "idle" means "saved". The first turn with user text asks the `Titler` on a
   `title <id>` thread.
6. Under the lock: completed **and** the `Interloper` still holds something **and** not closing →
   stay `:running`, reset the `Cancellable`, loop to 2 as a bare turn. Otherwise `:idle` (or
   `:closed`). Then `TurnEnded(outcome:, error:, restarting:)`.

A `submit` while `:running` injects into the `Interloper` (`:injected`); the running turn reads
it after its current tool batch, or step 6 starts a bare turn for it. A `cancel` keeps
undelivered injections; the host decides whether a blank `submit` re-sends them or
`discard_pending` takes them (`D_submit_injects`).

**Shutdown** (`Conversations#shutdown(timeout:)`): `close(force: true)` on each, then wait for
each `Event::Closed` within the one deadline. `timeout: 0` returns at once, for a host whose
shutdown hook may not block (Puma's `:state` hook).

## Where to start reading

`lib/pikuri-conversations.rb` — the list, its `build_agent` and `shutdown`, forty lines that show
what the gem wires into every agent. Then `Conversation#deliver`, `#run_boot` and `#run_turns`,
which are the state machine.

## What is deliberately absent

- **No idle eviction** — an agent lives until `close` (`D_no_idle_eviction`).
- **No thread pool and no concurrent-ruby** (`D_conversation_turn_state`).
- **No UI, HTTP server or database, and nothing a single bin needs** (`D_conversations_gem`).
- **No title stored by the gem** — the host lands `Event::Titled` (`D_title_after_turn`).
