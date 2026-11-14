# A rate-limited listener for hosts that render a stream

Status: **workshop side landed (2026-11-14): `Pikuri::Conversations::RateLimitedListener`,
`Event::ALL`, `TurnEnded`'s thread promise.** The reasoning below now lives in the class's
yardoc. What's left is the three hosts' swaps, each in its own repo; graduate (delete this file)
once they're done.

## Why

pikuri-core dropped `Agent::Listener::RateLimited` (its CHANGELOG: nothing in pikuri wired it,
"pacing a renderer's repaints is the renderer's business"; a host keeps a copy). Every host that
renders Markdown from a stream does: a fast llama.cpp sends dozens of deltas a second, and
re-rendering on each is wasted work. Three copies exist:

- pikuri-tui `lib/shared/rate_limited_listener.rb` (`Shared::RateLimitedListener`), wired only in
  `lib/computer/app.rb`, behind a `FanoutListener` inside the listener `Conversations#open` takes.
- pikuri-webui `lib/pikuri_webui/web/rate_limited_listener.rb` (`PikuriWebUI::Web::RateLimitedListener`),
  in `agent_listeners`: `Agents::Runner#on_event` keeps the conversation's events to itself.
- Puri `lib/puri/core/turn_listener.rb` — not a decorator: the throttle is fused into the renderer
  (`@pending`, `@next_at = now + period`), so it shows the first delta at once, like the others.

The tui and webui copies are line-for-line identical bar the lock and `for_sub_agent`. Both
changed core's class the same way: core's `flush_pending_on_non_delta: false` dropped buffered
deltas on *any* non-delta event, which now loses streamed text when `Pikuri::Conversations` puts
`PendingChanged` on the same listener mid-reply. Both **drop a buffered delta only at its own
bookend** (`Assistant` / `Thinking`, which carry the whole text) and **flush ahead of any other
event**; neither has the knob any more.

## Where — pikuri-conversations (settled)

All three hosts depend on it. And the bypass rule below must know which events are
`Conversations::Event`s and which thread emits each — knowledge only that gem has. A one-class gem
would be overkill; pikuri-core has said no.

## Lock, or bypass — bypass, with `TurnEnded` as the one exception

pikuri-tui locks every `on_event`, `inner` call included, because conversation events from other
threads reach it. pikuri-webui has no lock, on purpose: a lock around `inner` would sit outside its
`BigAppLock`, which its "domain lock is outermost" rule forbids.

A **leaf lock** (buffers only, `inner` called outside it) is no way out: a UI thread's flush-ahead
could then hand `inner` an earlier chunk *after* a later one the turn thread already emitted.
Either the lock spans `inner`, or only one thread touches the buffers.

So: **only the agent's thread touches the buffers.** A `Pikuri::Conversations::Event::*` passes
straight to `inner` — **except `TurnEnded`, which flushes first.** Everything else — agent events
and an extension's own, both emitted on the agent's thread — is handled as today. The test is
"is a conversation event", not "isn't an agent event": an extension's event comes from the
agent's thread and should flush ahead. The inner listener then takes calls from two threads,
which every host's already does (they marshal and return).

**Why `TurnEnded` can't bypass — the failed turn.** `Agent#think` rescues only `Cancelled`
(`pikuri-core/lib/pikuri/agent.rb:490`, which emits `Event::Cancelled` — an agent event, so it
flushes). A ruby_llm error mid-stream emits **no** agent event: after the last delta come only
`TurnEnded(:failed)`, then the next turn's `TurnStarted`. Bypassing both leaves up to one
period's tail in the buffer, flushed ahead of the next turn's `UserTurn` — *after* the new user
message, into the wrong turn. pikuri-webui has this bug today: its runner never forwards
`TurnEnded` to the limiter. Puri gets it right (`ended` flushes).

**Why `TurnEnded` may touch the buffers without a lock.** `Conversation` emits it in exactly one
place, on the turn's own thread after the agent returned (`conversation.rb:518`), so it is
sequential with the agent's events. The limiter would then lean on that as a contract.

## Puri has the cross-thread race

`Puri::Core::AgentSession#on_event` (`agent_session.rb:149`) forwards `PendingChanged`,
`CancelRequested`, `ModelPending` to `TurnListener` from the submitting thread; there they hit
`else flush`, unlocked, against the turn thread's `delta` / `flush` on the same `@pending` /
`@reply` / `@stream`. A user typing mid-frame can open two `Reply` blocks, or append to one
`ReplyStream` from two threads at once. Wrapping its renderer in the shared limiter fixes it
(the bypass never lets those events near the buffers); `TurnListener` keeps only rendering.
Puri ignores thinking deltas, so it would pay for buffering them — trivially.

## Settled

- **No timer** (was `Q_stalled_tail`). Tick state advances only when an event arrives — core's
  design, no thread. A model that pauses mid-reply leaves up to one period's text invisible until
  its next delta or bookend; all three hosts accept that (Puri documents it). A host on a slow,
  bursty provider that minds can ask for a `tick_now` then.
- **Keep `for_sub_agent`** (was `Q_sub_agents`), wrapping the inner listener's variant. Free for
  webui; a sub-agent runs on its parent's turn thread, so a fresh limiter per sub-agent stays
  single-threaded.
- **Recognising a conversation event: `Pikuri::Conversations::Event::ALL`** (was
  `Q_bypass_test`), a frozen array the gem exports, computed from `Event.constants` so a new
  variant can't be left off it. pikuri-webui computes exactly this today (`Agents::Runner::
  CONVERSATION_EVENTS`, `runner.rb:58`) and deletes its copy. Not a marker module included in each
  `Data.define`: a line per variant to forget.
- **`TurnEnded`'s thread becomes a promise of `Conversation`** (was `Q_turn_ended_contract`):
  "emitted on the turn's own thread, after the agent's last event". Written on `TurnEnded`'s
  yardoc, where a change to its emit site sees it; the limiter's header points there. A spec pins
  it: record `Thread.current` at the last agent event and at `TurnEnded`, assert they match.
- **A failed turn's tail is flushed, not dropped** (was `Q_failed_tail`), the thinking tail too.
  It is what the model said before the failure, and the host's failure notice follows it, so a
  half sentence then "Can't reach the model" reads right; no `Assistant` bookend comes to show it
  whole otherwise. Puri already flushes.
- **Name: `Pikuri::Conversations::RateLimitedListener`** (was `Q_name`), flat beside `Throttle`
  and `Titler`; the gem has no `Listener` namespace and one class doesn't earn one. "Rate-limited"
  is what all three hosts and core's CHANGELOG call it, so it's what a reader searches for.
- **pikuri-webui routes `TurnEnded` both ways** (was `Q_webui_route`): through `agent_listeners`
  first, so the tail flushes, then to `conversation_event` — one `when` line in
  `Agents::Runner#on_event`. Sending every event through the limiter and dropping the split is
  cleaner but bigger (`conversation_event` feeds the status bar by another path than
  `SseListener`); not part of this.

Not counted on: pikuri-core emitting an `Event::Failed` beside `Cancelled` would make the
`TurnEnded` exception unnecessary, but core just said renderer concerns aren't its business.

## Done when

- ~~The class is in pikuri-conversations with core's old spec ported, plus: a conversation event
  bypasses the buffers; a bare `TurnEnded` after deltas flushes them first.~~ Done.
- ~~`Event::ALL` exported; `TurnEnded`'s yardoc states its thread, with the spec pinning it.~~
  Done (`conversation_spec.rb`, "ends a failed turn on the thread its agent's last event came on").
- pikuri-tui swaps its copy for it and drops its lock (keeping the fan-out).
- pikuri-webui swaps its copy, deletes `CONVERSATION_EVENTS` for `Event::ALL`, and routes
  `TurnEnded` through the limiter.
- Puri wraps its renderer in it, which ends its race; `TurnListener` keeps only rendering.
