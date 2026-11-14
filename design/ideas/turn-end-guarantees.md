# What a host can count on when a turn, a boot or the list ends

Status: **found moving Puri onto `pikuri-conversations`** (Puri `master`, gem `8baedfd`). Puri
works around each gap below in a few lines; every host will hit the same three, so they belong in
the gem. Puri was the last host in `conversations.md`'s *Done when*; this is what it learned.

## 1. `close(force: true)` can still race `on_turn_end` — `Q_close_vs_save`

`Conversation#close` promises: "Once closing, the turn in flight ends without `on_turn_end` —
so a host deleting the conversation from disk never races a save." `run_turns` does

```ruby
history = save unless locked { @closing }
```

so the check and the call are two steps: a `close(force: true)` landing between them (the host's
delete, on the UI thread) sets `@closing` while `on_turn_end` is already writing. A host that
calls `Store#delete` right after `close` returns can then have the folder written back, or
`HistoryFile.save` fail half-way inside a folder being removed.

Puri guards it itself: a per-conversation mutex around its save and its delete, and a `persist`
flag the delete clears (`Puri::Core::AgentSession`). Options for the gem:

- **Say so, and point at `Closed`**: the turn thread finishes `on_turn_end` before it releases
  the agent, so a host that deletes on `Event::Closed` (or after `wait_closed`) never races. Cheap,
  but the delete becomes asynchronous, which webui's 409-or-gone answer doesn't want.
- **Mark the save in flight under the lock** (`@saving = true` with the `@closing` check) and
  have `close` report it (`:closing` even when idle-ish), so the host knows to wait.
- Recommended: the first, plus fixing the doc sentence, unless webui wants the synchronous form.

## 2. A cancelled boot ends with no event saying so — `Q_cancelled_boot_event`

`cancel` during `:booting` sets `@cancelled_boot`; `run_boot` then goes `:idle` and emits only
`Ready`. No `TurnEnded` follows, so a host that showed "working" since `submit` has nothing that
says the work stopped. Puri infers it: on `Ready`, `status.state == :idle` means a cancelled boot
(with `boot: false` every boot has a message waiting). That inference holds only for
`boot: false` hosts, and reads state that may have moved on.

Proposal: emit `TurnEnded(outcome: :cancelled, error: nil, restarting: false)` from a boot that
was asked to run and was cancelled — the host's "the work I started is over" is the same event
however far the work got. Or a `BootCancelled`, if `TurnEnded` must mean a turn ran.

## 3. `shutdown` saves nothing that was running — `Q_shutdown_saves`

`shutdown` closes with `force: true`, and a closing conversation skips `on_turn_end`, so a turn
cut by quitting is lost: the user's last message and the partial answer. Puri wants "idle means
saved" across a quit too, so its `close` cancels every conversation, polls `status` until none
is `:running` (bounded), and only then calls `shutdown`.

Proposal: `shutdown(timeout:, save: true)` — cancel, let `on_turn_end` run, then close; or make
that the default and let webui's Puma hook pass `save: false` for its instant return.

## Smaller notes

- `on_turn_end` hands the host `(conversation, history)` but not the transport the turn ran on;
  Puri reads `conversation.status.model` for `Store#save`'s `model:`/`server:`. Passing it would
  make "what the agent is *on*" (`Store#save`'s own doc) true by construction.
- Puri now shows a message a `cancel` drops (`discard_pending`'s items) instead of dropping it
  unseen; `conversations.md`'s *How each host reads* says Puri drops them, which is half right.
