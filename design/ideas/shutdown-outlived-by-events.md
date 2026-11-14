# `shutdown` returns while a conversation's events are still on their way

Status: **bug, found from Puri (2026-11-14); fixed in the workshop, waiting on Puri's
25-run check.** It made Puri's
`pikuri_core_spec.rb` flaky, failing about 2 runs in 25: `Dir.mktmpdir`'s cleanup, right
after `core.close` (which is `shutdown(timeout: 5)`), died with `Errno::ENOENT` on
`<conversation>/.meta.json.tmp`, because a title was being written into the folder it was
deleting. The failure lands on whichever example happens to be tearing down.

## What happens

`Conversations#shutdown` (`lib/pikuri-conversations.rb:129`) closes every conversation, then
waits with `wait_closed`, which watches `@agent_released` only. A conversation's other threads
are not waited for:

- **The title thread** (`Conversation#title`, `conversation.rb:624`) checks `!closed?` under the
  lock (line 637), queues `Event::Titled`, and emits it once the lock is released. A title that
  passes that check just before `close` is emitted after it, on the title thread, while
  `shutdown` has already returned. A host that stores the title from the listener, as the
  `Titled` doc tells it to (`Store#retitle`), then writes after `shutdown`.
- **The release thread** (`release`, `conversation.rb:662`) sets `@agent_released = true`
  *before* `emit(Event::Closed)` and `@on_closed&.call`, so even `Closed` can reach the
  listener after `shutdown` has returned true.
- **`Titled` can come after `Closed`.** Title thread passes its check → `close` on an idle
  conversation → the close thread emits `Closed` → the title thread emits `Titled`. That breaks
  `Titled`'s own doc ("never once the conversation is closing"), and a host that drops its
  per-conversation state on `Closed` gets a `Titled` for a conversation it already forgot.
  Waiting longer in `shutdown` alone would not fix the order.

Puri confirmed the first one: with a 0.2 s delay before `AgentSession#retitle`'s write,
`core.close` returned 1 ms after it started, and the write came later.

Outside specs the harm is small: a quit as a title lands may cut the write off, and
`Store`'s temp-file-and-rename keeps `meta.json` whole (and `Store#retitle` is a no-op once
`Store#delete` ran). But a host can't treat "`shutdown` returned true" as "nothing more
reaches my listener", which is what a spec's teardown and a process exit both assume.

- **A close landing as a turn ends released the agent twice.** `run_turns` set `:idle`, let
  the lock go, emitted `TurnEnded`, then released whenever it read `:closed`. A close in that
  window, from the `TurnEnded` listener (a one-shot host) or another thread, had already
  released: `TurnEnded … Closed Closed`, `on_closed` twice, `wait_closed` true before the
  second. Found in review after the first fix.
- **Any `locked` call's events could trail a close from another thread**: `switch_model`'s
  `ModelPending`, `clear`'s `Cleared`, a boot's `Ready`. `locked` emits after the lock drops.

## Fix: `Closed` is the last event, and `wait_closed` returns after it

Built, in `Conversation`; `shutdown`'s code is unchanged.

1. **`Closed` waits for events being heard, not for threads.** `locked` counts itself in
   `@emitting` in the critical section that queued its events and uncounts once the listener
   has heard them; the close thread waits on `@changed` while the count is positive. `Titled`
   and `TurnEnded` go through `locked` too. Joining the title thread was the first plan, but
   pikuri's `Cancellable` does not interrupt an in-flight LLM HTTP call (only `Throttle`'s
   permit wait), so `Closed` would have waited for the titler's whole answer, or a dead
   server's read timeout. A listener calling `wait_closed` now waits out its timeout; said
   in its yardoc.
2. **`@agent_released` is set after `emit(Closed)` and `on_closed`**, in an `ensure` so a
   raising `on_closed` can't strand a waiter.
3. **`discard_pending` answers `[]` once closing**, since it would otherwise emit
   `PendingChanged` on the host's thread after `Closed`.
4. **`run_turns` releases only a close it finished itself** (it saw `@closing`), never on
   reading `:closed` after the lock dropped.

`wait_closed` now means "every event has reached the listener"; `shutdown` inherits that, and
so does any host calling `wait_closed` directly. A title request still in flight may outlive
`Closed` but emits nothing; `wait_settled` waits that out too. Docs updated: `Closed`,
`Titled`, `wait_closed`, `discard_pending`, `shutdown`; a CHANGELOG line.

Why not the first draft (`shutdown` waits for `wait_settled`): it was safe — every `release`
runs on the thread that called `close` or inside a counted boot/turn thread before its count
drops, so `@threads` never touches zero between closed and released — but it left `Titled`
after `Closed`, and left `wait_closed` lying to hosts that call it.

## Aside: a turn thread that raises leaves `:running` forever

`run_turns` rescues `run_loop` and `on_turn_end`, but not `@agent.export_history` in `save`
(line 608). If that raises, `spawn` logs it, the state stays `:running`, the agent is never
released, and `wait_closed` waits out its whole timeout. Not this bug; worth a separate look.

## Done when

- ~~Specs in `conversation_spec.rb`~~ — done: "returns from shutdown only once the listener
  has heard Closed", "hears out a title that passed before the close…", "closes once when the
  TurnEnded listener closes…" and "holds Closed back for an event another thread's call…".
  Each failed on the code before its fix; the spec file ran 25 times clean after both.
- Puri bumps its pin, and its `pikuri_core_spec.rb` runs 25 times clean.

On graduation: the aside above becomes its own idea file; everything else already lives in
the yardoc, the `release` comment and the CHANGELOG.
