# A slim `Agent` and `pikuri-conversations`: one design, two layers

Status: **shape settled; built: `HistoryFile`, `Store`, the scheduler (`Conversations`,
`Conversation`), the `Throttle` and the `Probe` with its `Detector`, moved here from core
(pikuri `76663ef`, `0e5882f`), and the `Titler`. What's left is the hosts moving onto the gem,
and graduation (see *Done when*).** pikuri has done its half: an `Agent` is one conversation, resumed through
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
  agent.
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
| `ServerPermits` + `RequestThrottle` | deleted from pikuri (`8d764bd`) | `Conversations::Throttle`, itself the `Agent.new(around_request:)` hook — **built** | only N concurrent trees need it |
| sizing permits from `/props` `total_slots` | pikuri's probe did it | `Conversations::Probe`, once per server+model, at a turn's start — **built** | pikuri's probe no longer seeds slots |
| `ContextWindowDetector`, `ChatTransport#with_detected_modalities`, `Event::ContextCap` | dropped from pikuri (`76663ef`, `0e5882f`) | `Conversations::Probe::Detector`, and `Conversations::Event::ContextCap` announcing what it learns — **built** | its future is more servers (vLLM's `max_model_len`, Ollama's `/api/show`), not explaining better; a bin states its cap or shows none |
| `History`, the value | pikuri-core | stays | `export_history` / `Agent.new(history:)` speak it |
| its JSON, `save(dir)` / `load(dir)`, `Attachment#stored_name` | dropped from pikuri (`5c87269`) | `Conversations::HistoryFile` — **built** (`D_history_file`) | storing is the host's; a deployment that never resumes shouldn't carry a format |
| the folder of conversations: ids, `meta.json`, list, retitle, delete, upload stash | webui `Store`, Puri `Store` | `Conversations::Store` — **built** | two copies of one format; a bin holds one conversation |
| the titler | webui, Puri `Core::Titler` | `Conversations::Titler`, fired by a `Conversation` opened `untitled: true` — **built** | the same class in both hosts; when to fire and what to drop after a delete are scheduling |
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
| Host-scheduled system injection + bare turn while idle (`/skill`) | | ✓ | | pikuri-code | `Conversation#submit(system:)` |
| Leftovers at turn end restart a turn — after a normal end only | ✓ (`D_interloper_mid_loop_input`) | ✓ | | — | turn task |
| Cancel keeps undelivered injections | ✓ keeps | re-sends as a turn | drops | — | `Conversation#cancel` + host choice |
| Cancel releases a parked confirmation | | ✓ (`cancel_pending!`) | ✓ (polls token) | — | the Confirmer watches the token |
| Model switch last-wins, re-pickable, applied between turns, never lost | ✓ | ✓ | — | — | `Conversation#switch_model` + `Agent#transport=` |
| Save before going idle ("idle means saved"), also after cancel/failure | ✓ | — | ✓ | — | `on_turn_end:` hook → `Store#save` |
| Saved conversations: list, open, retitle, delete; images on disk before the turn | ✓ | — | ✓ | — | `Store` |
| Delete: atomically refuse if busy (409), else retire; no save after | ✓ | — | cancel then delete | — | `Conversation#close`, then `Store#delete` |
| Clear refused while running | — | ✓ | — | pikuri-code | `Conversation#clear` |
| Errors reach the UI with their class (`UnsupportedAttachmentError`, other) | wants it | ✓ | ✓ | — | `TurnEnded` event |
| Turn thread named per conversation; per-turn thread priority | ✓ (`D_puma_thread_dump`) | | ✓ (−3, `R_gvl_main_loop`) | — | `Conversations` |
| Shutdown without waiting / with a timeout | ✓ no wait | quits | cancel+join | — | `Conversations#shutdown` |
| Side LLM calls (titler) off the turn, throttled | ✓ | | ✓ | — | `Titler` on a thread of the conversation's own |
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
agent.run_loop('and now?', transport: other)  # a switch, or the same model's newly learnt facts
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
| `run_loop(user_message = nil, attachments: [], transport: nil)` | one turn: drain the `Interloper`, append the message, `complete`; blank = bare turn | positional message; **returns the final assistant text** (replaces `last_assistant_content`, whose three callers read it right after) — not done in pikuri yet |
| `transport:` on `run_loop` | another model switches (`ModelSwitched`); the same model differing only in stated facts (cap, modalities) is adopted silently — **done** (`76663ef`, `0e5882f`). A `transport=` writer was rejected (`pikuri:D_deferred_cap_probe`): the gem validates attachments before the turn, so a switch is never lost | — |
| `export_history`, `close`, `trifecta` | as today | `clear_conversation` and `load_history!` **gone — done** (`a31c2eb`) |
| `tools`, `sub_agent_tools`, `extensions`, `cancellable`, `interloper`, `streaming` | readers, as today | — |
| `context_window_cap`, `modalities` | — | **dropped — done** (`76663ef`): `transport.context_window` / `transport.modalities` |
| `model`, `system_prompt`, `last_assistant_content` | — | **dropped**: no non-spec callers, or `run_loop`'s return |

Errors unchanged: `Cancellable::Cancelled`, `UnsupportedAttachmentError` (from the
transport's stated modalities; unknown goes out).

**The throttle seam is `Agent.new(around_request:)`** (shipped, `pikuri:D_llm_request_throttle`):
`call(api_base, cancellable) { request }`, run by `Agent::RequestInstrumenter` around exactly one
`request.ruby_llm` event. `around`, not a `before`/`after` pair: a permit must be released when a
request raises, is cancelled, or streams for 20 s. On the agent rather than the transport, so a
model switch can't drop it and a fresh lambda can't break `ChatTransport#==`; `api_base` is
handed per call because a switch may change server. The throttle is one process-wide module,
`Conversations::Throttle`: it looks up its permits by `api_base`. Not inherited by itself: `SubAgentTool` passes
`parent.around_request`. The MCP boot passes take it from the host:
`Mcp::Catalog.build(registry, transport:, around_request:)` hands it to each `Thinker`'s one-shot
agent (`D_mcp_catalog_and_connections`); a host's titler must do the same.

**Recovering the old throttle**: `ServerPermits` and `RequestThrottle` are deleted from pikuri;
`git show 5c87269:pikuri-core/lib/pikuri/agent/server_permits.rb` (likewise
`request_throttle.rb`, `spec/pikuri/agent/{server_permits,request_throttle,throttle_integration}_spec.rb`,
and `D_probe_when_unknown` in pikuri's `design/decisions.md`, the reasoning for re-seeding slots
from the probe). pikuri's probe no longer seeds slots and is skipped once cap + modalities are
stated; it leaves core next, for the gem (see Settled).

**Stays**: the `Interloper` — not only host plumbing: `Skill::Extension#schedule_load_skill`
queues through it in pikuri-code's single-threaded REPL. `Extension`, `Configurator`,
listeners — unchanged; listeners stay read-only.

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
  streaming: true, priority: 0)
Pikuri::Conversations::Throttle.limit('http://localhost:8080', 1)  # process-wide, ex-ServerPermits.limit
conv = convs.open(id:, transport:, listener:, history: nil, boot: true)
conv.submit('how do I keep an avocado?')               # => :started
conv.submit('also, ripe?')                              # => :injected
```

**`Conversations`**

| Method | Behaviour |
|---|---|
| `new(system_prompt:, configure:, on_turn_end: nil, streaming: true, priority: 0)` | the gem builds every `Agent` itself, wiring what it owns — `cancellable:`, `history:`, the conversation's listener, `around_request: Throttle` — then calls `configure`. `priority` is each turn thread's |
| `open(id:, transport:, listener:, history: nil, boot: true)` → `Conversation` | a conversation. `listener` hears the agent's events and the conversation's, fixed for its life. `boot: false` leaves it in `:new` until the first `submit` (Puri) |
| `[](id)`, `each` | lookup |
| `limit`, `around_request` | not on the list: `Throttle.limit(server, permits)` and `Throttle` itself, process-wide (see Settled) |
| `executor` | dropped (see Settled): the titler runs on a thread of the conversation's own like everything else |
| `new(titler:)`, `open(untitled:)` | a `Titler` for the list; `untitled: true` for a conversation that still wants a name (a fresh one, or a resumed one still carrying its start stamp — the host asks `Store#stamp_titled?`) |
| `shutdown(timeout: 0)` | cancel every turn; running turns unwind, run `on_turn_end`, close their agents; waits at most `timeout`, never on a host lock. `0` returns at once (webui's Puma `:state` hook) |

**`Conversation`** — every method is thread-safe, returns at once, never calls out under the
gem's lock.

| Method | Behaviour |
|---|---|
| `submit(text = nil, attachments: [], system: [])` | `:new`: boot, queue it → `:started`. `:booting`: queued → `:started`. `:idle`: start a turn → `:started`. `:running`: inject → `:injected`. Blank: a bare turn delivering pending injections, `:ignored` when none are (always while running). `:closed` → `:discarded`. Raises `UnsupportedAttachmentError` synchronously when the next model's modalities — stated, or learnt by the `Probe` — refuse one |
| `submit(text, system: [block])` | reference blocks ahead of the message, in one step (tui/pikuri-code `/skill rest`); with no text, a bare turn delivers them |
| `cancel` | `:booting`: cancels construction (the token reaches MCP synthesis). `:running`: `cancel!`. Undelivered injections **stay** (webui's `D_interloper_mid_loop_input`) — the host decides: a blank `submit` re-sends them (tui), `discard_pending` takes them (Puri shows what it took) |
| `discard_pending` | take-and-clear of the undelivered `Interloper::Item`s; their count is `status.pending`. No snapshot: pikuri dropped `Interloper#peek`, as no host read it |
| `switch_model(transport)` | last-wins; re-picking the current model clears the pending one. Applied at the next turn's start through `run_loop(transport:)`. → `:selected` / `:discarded` |
| `clear` | `:idle` → close the agent and build a fresh one, extensions and all (`pikuri:D_agent_is_one_conversation`) → `:cleared`; running → `:busy` |
| `close(force: false)` | idle or `:new` → close the agent (off-thread), `:closed`. Booting or running → `:busy`, or with `force` cancel, `:closing`, close once it unwinds. The cut turn still runs `on_turn_end` — the gem can't keep a delete off a save it calls outside its lock, so `Store#delete` wins over every later write instead. `Closed` follows the save and the agent's release; `wait_closed(timeout)` blocks for it |
| `status` → `Status` | frozen snapshot: `state`, `pending` count, `busy?` (running, or booting with a message waiting — a host's "working", re-read on every event), `model` (what the agent is on), `next_model` (pending or current) — each a transport with what the `Probe` learnt filled in, so its `modalities` / `context_window` ride along. Readable under the host's lock |
| `history` | the last snapshot — from `open`, or the last `on_turn_end` |
| `trifecta` | `nil` until booted |
| `id`, `listener` | as opened |

**State machine**, guarded by the gem's lock:
`:new → :booting → :idle ⇄ :running → :closed`; a failed boot returns to `:new`, keeping its
messages, and the next `submit` boots again. A message arriving in `:new`/`:booting` waits in
the gem: the agent builds its `Interloper` itself, so it can't be the agent-to-be's. After boot
the last waiting user message is the first turn's message and the earlier ones go into the
`Interloper`, which `run_loop` drains ahead of it — order kept, and the common case (one
message) is an ordinary turn, not a `UserTurn(mid_loop: true)`.

**The turn task**, on a pool thread:

1. Under the lock, whoever moves the conversation to `:running` — `submit` on the caller's
   thread, or the restart in step 6 on the worker — resets the `Cancellable` in the same critical
   section, so no cancel can fall between (`pikuri:D_host_resets_cancel`).
2. Name the thread `turn <id>`, set its priority.
3. Take the pending model switch; emit `TurnStarted`; `Probe.props` the turn's transport (cached
   per server+model, seeds `Throttle.default` from `total_slots`; skipped when cap and
   modalities are stated and the server is sized), and emit `ContextCap` if the cap is news.
   Here, not at boot, for `pikuri:D_deferred_cap_probe`'s reason: on a router it loads the model.
4. `agent.run_loop(user_message:, attachments:, transport: Probe.facts(transport))` — a picked
   model switches, newly learnt facts are adopted silently — rescuing `Cancelled` and
   `StandardError` into an outcome.
5. `on_turn_end.(conv, agent.export_history)` — on the worker, off the lock, before going idle,
   for every outcome, a turn a forced close cut short included.
6. Under the lock: completed **and** `interloper.pending?` and not closing → stay `:running`,
   reset, loop as a bare turn; else `:idle` (or `:closed`). Then emit `TurnEnded`.

**Conversation events** (alongside the agent's, on the conversation's listener, never under the
gem's lock): `Booting`, `Ready(trifecta:)`, `BootFailed(error:)`,
`TurnStarted(user_message:, attachments:)` (before the probe, so a UI shows the message during a
cold model load), `ContextCap(cap:)` (at boot, then when a turn's probe or a picked model changes
it — pikuri's core announces none), `PendingChanged(count:)` (the gem owns `Interloper#on_change`),
`ModelPending(transport:)` (`nil` = cleared), `CancelRequested`,
`TurnEnded(outcome: :completed|:cancelled|:failed, error:, restarting:)` (after `on_turn_end`),
`Closed`.

**`Store`** (built): one folder per conversation under a root — pikuri's `history.json` and
`attachments/` beside the store's `meta.json`, schema 1, the format webui and Puri already
write. Webui's shape, as the reference host: a `Store::Entry` value, `find` through the listing,
an unreadable envelope listed as `supported: false`, the upload `stash`. From Puri: `history`, and
`extra:` keys on `meta.json` (its `last_question`, `asked_at`).

**`Titler`** (built): webui's class, which Puri had ported verbatim — prompt, `<opener>` wrapper,
word and character caps, the `</think>` strip, the reasoning canary — plus `around_request:
Throttle` and a cancel token. A conversation opened `untitled: true` asks it once, from the first
`role: user, kind: user` message with text, after the first turn whose history has one ends —
completed, cancelled or failed — on a thread `title <id>`, and reports `Titled(title:)`. A title
landing once the conversation is closing is dropped, and `close` cancels its request. A failure
is logged and not retried; reopening the conversation `untitled: true` asks again.

## How each host reads

- **webui**: `Runner` and `claim_running`/`finish_turn` go; `Registry` keeps conversations;
  `on_turn_end` persists through `Store` (idle still means saved); `discard!` is `close` →
  `:busy` → 409; `status_data` is `conversation.status`; the titler is the gem's, fired after the
  first turn (closing `titler-first-turn-permit.md` and its `Q_titler_restore`: a restored
  stamp-titled conversation is opened `untitled: true` and titled at its next turn end, so one
  only read is never titled); its listener lands `Titled` through `Store#retitle` and its own
  entry; `ServerPermits.limit` is `Throttle.limit`. Its
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
  `UserTurn(mid_loop: true)` as a block; cancel takes the pending messages via `discard_pending` and shows them; `core.close` becomes
  `shutdown(timeout:)` instead of a thread kill. Its `Core::Titler` goes for the gem's, and its
  title now arrives after the first answer rather than while it streams — `D_titler_model`'s
  "beside the answer" is superseded and needs rewriting. Its dummy backend (`turns:` strategy)
  stays outside the gem — the GTK specs keep their own fake.
- **bins**: unchanged in shape, slightly simpler — `run_loop(message)` returns the answer, a
  model switch is `agent.transport =`; with no probe in core, a bin's cap and modalities are what
  its transport states — otherwise `ctx=8.4k` with no denominator, and an attachment the model
  can't take reaches the server, which refuses it.

## Settled

- **Sub-agents stay plain `Agent#run_loop` calls, inline on the parent's thread**, sharing the
  parent's cancel token — never submitted to the pool and awaited, which deadlocks a bounded pool.
- **Unbounded: a plain thread per boot, per turn task, per agent release** — no pool, no
  concurrent-ruby. A turn holds its thread through waits that aren't load — a `Confirmer` on a
  human, a long `bash` (`pikuri-webui:D_serial_turn_executor`) — so a bound is wrong, and a
  thread's start cost is nothing beside a turn's seconds. A thread per task also names itself
  (`boot <id>`, `turn <id>`, `close <id>`) and is the one `wait_closed` needs nothing to join.
- **Turns may hop threads**: `Agent`'s header says nothing is confined to a thread, and no
  `lib/` in pikuri or the workshop reads `Thread.current` (was `Q_thread_hopping`).
- **The gem never lets a host hook strand it**: a listener or `on_turn_end` that raises is
  logged at error, and the state machine moves on.
- **Load is bounded per request by the throttle**, never per turn (`pikuri:D_llm_request_throttle`).
- **The gem never calls out under its own lock** — no listener, no hook, no host code; webui's
  listeners take its global monitor (`pikuri-webui:D_global_monitor`). It owns
  `Interloper#on_change` for the same reason: `enqueue` fires it on the injecting thread, which
  holds the gem's lock during a mid-turn `submit`.
- **A plain state machine, not `Concurrent::SerializedExecution`.** With `submit` injecting, no
  second turn ever queues, so per-key serialization only duplicates the `running` flag — and
  once anything queues behind a turn, a reset at post time wipes the running turn's cancel.
- **No idle eviction**: an agent lives until `close`. Closing and rebuilding from `History` loses
  state outside it (Tasks' list, Skill activations, what an MCP server held — its tools come
  back, its logged-in browser does not), and webui rejected
  reaping already.
- **`Agent` stays thread-unsafe**; the two `Control`s remain the only doors in from another thread.
- **The `/props` probe moves here** (was `Q_detector_home`). It fails pikuri's placement test —
  llama.cpp-only, router re-probes, a bearer key, and its future is more servers. Inside the
  workshop the gem is its only caller. It bends the gem's rule ("refuses anything one bin
  needs") only if a bin needs it, and it doesn't: the detector calls the cap a cosmetic readout,
  pikuri's overflow note argues the curve is in absolute tokens with no knee, and an unknown
  modality already goes out. `D_context_window_sources` still holds: a bin without a stated cap
  shows none rather than ruby_llm's registry guess.
- **The permit registry and the probe's cache are process-wide**, keyed by server (and model):
  what a permit protects is the server, and two lists against one llama.cpp would each hand out
  its slots (`pikuri:D_rate_limiter_scope`). So `Throttle` is a module, not a list's object, and
  is the `around_request` hook itself (was `Q_permit_scope`).
- **Two probes, at two moments** (was `Q_probe_at_boot`): at boot the cheap lookup, which never
  loads a model (`/v1/models` on a router), so `status` and `submit` know the model's inputs
  before the first turn; at a turn's start the full `/props`, which may cold-load the model and
  so waits for a turn that uses it. A failed answer is retried after 60 s, not every turn. A
  model picked with `switch_model` learns its inputs only at its first turn.
- **A title is asked for after the first turn, not beside it** (was `Q_titler`). Beside it, on
  a server with one slot, the title's request wins the permit and the answer waits for it —
  measured at ~2 s in pikuri-webui's `titler-first-turn-permit.md`; after it, the turn's
  requests are done before the title asks, so the race is gone rather than rarer. The cost is
  cosmetic: the start stamp shows until the first answer is in. Puri took the delay on purpose
  (`puri:D_titler_model`) to show the title while the answer streams; one rule for every host
  wins over that.
- **The gem fires the title, the host stores it.** A `Conversation` can't tell a stamp-titled
  conversation from a named one without the `Store` it never references, so the host says so
  with `open(untitled:)`, and lands `Event::Titled` through `Store#retitle`.
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

## What the build taught

Built against pikuri `3aed7e2` with no pikuri change:

- **A model switch doesn't need `Agent#transport=`.** The gem passes `run_loop(transport:)` only
  when a pick is pending, and validates attachments first — the only thing `run_loop` does ahead
  of applying the switch — so the switch can't be lost.
- **`run_loop` returning the answer isn't needed**: the gem reads `export_history`.
- **Moving the detector needed one pikuri change**, now done (`76663ef`, `0e5882f`): a transport
  differing only in stated facts is adopted silently rather than switched to, so the gem hands
  the agent `Probe.facts(transport)` at boot and at each turn's start; `Agent` never probes, and
  core announces no cap — `Conversations::Event::ContextCap` does.
- **A small duplication**: `submit`'s synchronous `UnsupportedAttachmentError` re-states
  `Agent`'s private MIME-family → modality table (three entries). A public
  `ChatTransport#refusal(attachment)` in pikuri would remove it; not worth a pikuri change alone.
- **What a host sees**: the first message after a cold boot is an ordinary `UserTurn` only when
  it's the one waiting; earlier waiting messages arrive `mid_loop: true`.

## Open questions

- `Q_overflow` — moved here 2026-11-15 as [`context-overflow.md`](context-overflow.md) and
  [`context-budget.md`](context-budget.md). Compaction is *not* close-and-rebuild: pikuri core
  swaps the messages in place via `Configurator#replace_compacted_history`, because a rebuild
  drops session state and can lose MCP tools (`pikuri:D_compaction_in_place`). What is left for
  a `Conversation` is the trigger: between turns, or reacting to `TurnEnded(:failed)` from
  overflow. Reactive compaction needs no cap; proactive compaction and the late warning take it
  from the probe. The per-turn budget-line refusal has no pikuri `D_` yet; it lives in
  `context-budget.md`.
- `Q_replay` — two hosts turn a saved `History` into a transcript, two ways. (The dangling-call
  repair is no longer duplicated: core's public `History#repair_interrupted_tool_calls` is what
  webui calls.)
  - **webui's `HistoryReplay`** (145 lines) synthesizes the live `Agent::Event` stream and feeds
    it through the live listener — one renderer, live or reloaded. To fake the stream it mirrors
    pikuri-core's private knowledge: the `<system-reminder>` envelope (the constant is private
    upstream; only webui's live-vs-replay spec catches a rename), the emit order (a `ToolResult`
    right after its own `ToolCall`, not in stored order), the emit-path filters (empty thinking,
    empty assistant text), and no `Tokens` (`HistoryLoaded` reseeds `TokenLog`).
  - **Puri's `Core::Replay`** (34 lines) builds its own blocks straight from messages — the
    "second place block kinds are decided" webui's header warns against — and already differs
    from Puri's live view: a `/skill` (`kind: 'reference'`) vanishes on reload, an interrupted
    call shows nothing (no repair), and thinking is dropped (unchecked whether Puri shows it live).
  - tui never resumes, so needs none.
  - **A. `History#events` in pikuri-core** — the envelope, order and filters stay private to
    the code that emits; the live-vs-replay spec moves into pikuri, failing in the commit that
    changes emission; Puri drops `Replay` and feeds the events through its `TurnListener`.
    Against: no pikuri caller, as no bin resumes — `D_history_file`'s argument, though that one
    is about carrying a format, and this is a pure function over core's own value.
  - **B. `Conversations::Replay` in pikuri-conversations**, beside `HistoryFile`: every caller
    is here, but the mirrored private knowledge moves rather than goes.
  - **C. Leave it**: two callers, webui's spec catches the worst drift; Puri's reload stays
    unlike its live view.
  - Follow-on, A or B: should `Conversations#open(history:)` replay into the listener itself?
    Not yet — webui replays per browser tab into that tab's SSE stream.
- `Q_confirmer_token` — pikuri-code's `Confirmer` should watch the cancel token as Puri's does, so
  `cancel` needs no host hook; a pikuri-code change, not the gem's.
- `Q_book` — the chapter: lost cancels, stranded injections, a lock-order inversion around a
  synchronous core.

## Done when

- pikuri's `Agent` has the shape above, its bins and the workshop's bins follow, and pikuri's
  `D_llm_request_throttle` and `D_deferred_cap_probe` say where those moved (both done).
- `pikuri-conversations` holds the scheduler, the throttle, the `/props` probe, `HistoryFile`,
  `Store` and `Titler`; pikuri-tui
  (first — one conversation, the cheapest test), then pikuri-webui, then Puri drive their
  conversations through it, their own turn state machines and stores gone.
- The workshop's pitch (`README.md`, `AGENTS.md`'s "What this is") covers a gem that runs no
  foreign code and needs no cage, as pikuri-tasks already doesn't.
- The nuggets land in durable homes: the threading model and the conversation/agent split in the
  gem's `design/architecture.md`; why two layers, why the workshop, why one gem, why the
  scheduler is shaped so as `D_` entries; the chapter in `book/`. Then this file is deleted.
