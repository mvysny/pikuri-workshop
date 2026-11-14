# pikuri-conversations: papercuts from the first host migration

Status: **collected from pikuri-webui's move onto the gem (2026-11-14); none scheduled.** Each
is small, and each cost the host a workaround or a paragraph. The bigger find from the same
migration has its own file: `injection-overtakes-turn-message.md`.

## `close` answers `:busy` while the agent boots

A host deleting a conversation calls `close` and refuses the delete on `:busy`. But boot
includes `Probe.modalities`, a network lookup, so against an unreachable server a freshly
viewed conversation sits in `:booting` for the length of a connect timeout, and a delete there
is refused for a turn that does not exist. pikuri-webui works around it with a state read and a
`close(force: true)`, which races a boot that turns into a turn in between (harmless there: a
forced close never saves). Options: `close` without `force` closes a booting conversation that
has no waiting message — nothing would be lost — and answers `:busy` only for a real turn.

## The first events arrive before `open` returns

`Conversations#open` calls `conv.boot` before returning, and `Booting` is emitted on the
caller's thread during that call. A listener that reads the conversation back (a status bar
calling `conv.status`) has no conversation yet: pikuri-webui's runner guards a `nil` and
broadcasts once more after `open`. Either document it on `open` ("your listener may hear
`Booting` before this returns"), or let the listener reach the conversation — `Booting` and
`Ready` carrying it, or `open` assigning before `boot`.

## Hosts' specs need two things the gem could ship

- **The probe dials `Testing.fake_transport`'s server** unless its key is sized:
  `fake.invalid` states its cap and modalities, but `probe` also wants `Throttle.sized?`. Every
  host's `spec_helper` grows `Throttle.limit('http://fake.invalid', nil)` plus the `reset!`
  pair, or its specs wait on DNS. A `Probe` that skips a server whose transport states both
  facts — or the gem's own spec helper, required by hosts — would remove it.
- **Waiting for a turn to finish** is the other: with no executor to swap for an inline one,
  pikuri-webui polls until the state is not `running`/`booting` *and* no thread named
  `turn <id>` / `boot <id>` / `title <id>` is alive (the state check alone passes before the
  `TurnEnded` listener has run). It cannot cover the title: the turn spawns `title <id>` on its
  way out and the thread names itself only once it runs, so a host spec waits for the title by
  its effect instead (this flaked ~1 in 5 runs before it did). A public
  `Conversation#wait_idle(timeout)` beside
  `wait_closed` — returning once `TurnEnded` has been emitted and any title asked — would make
  that one call, and stop hosts depending on thread names.

## From pikuri-tui's move onto the gem (2026-11-14)

Three more, from moving pikuri-tui's three shells (`Chat` / `Code` / `Computer::App`) off their
own turn loop. pikuri-tui stubbed the probe's `Detector` in its `spec_helper` for the
fake-transport point above.

### `open` takes one listener, but a host has several panes

`open(listener:)` is the only way to hear the conversation's own events (`Booting`,
`TurnStarted` / `TurnEnded`, `PendingChanged`, `ContextCap`), and in a TUI four components want
a slice of both streams: the transcript, the status rule, the task pane, the skill palette.
pikuri-tui wrote a `Shared::FanoutListener` — a `ListenerList` plus `on_event` /
`for_sub_agent` — which is pikuri-core's `ListenerList` all but in name. Options: `open` takes
`listeners:` (an Array, wrapped the same way), or — smaller and in core — `ListenerList` itself
answers `on_event` and is a listener. The second also helps any host that composes listeners
without the gem.

A host that rate-limits the transcript meets a second effect: the conversation's events now
cross the delta stream from other threads (a `PendingChanged` from the UI thread mid-reply), so a
copy of the removed `Listener::RateLimited` needs a lock, and its `flush_pending_on_non_delta:
false` drops streamed text whenever such an event lands. pikuri-tui's copy drops a delta only at
its own bookend.

### `Booting` doesn't say why — `Q_booting_reason`

A host that starts its transcript over when a new agent boots (the only signal a `/clear` has
landed, ordered with the stream, is that agent's `Booting`) also wipes it on the *first* boot
(harmless) and on a *retry after `BootFailed`* — where it erases the error line the user just
read. pikuri-tui accepts that. Options: `Booting(reason: :open | :clear | :retry)`, or a
`Cleared` event `clear` emits before `Booting`.

### No way to send a skill and a message as one turn — `Q_system_with_message`

`/<skill> rest` should put the skill's body ahead of `rest` in one turn. `inject_system` from
`:idle` starts a bare turn at once, so `inject_system(body)` then `submit(rest)` runs the skill
alone and injects `rest` mid-turn (or, per `injection-overtakes-turn-message.md`, ahead of it).
pikuri-tui branches on `status.state`: idle or running, it schedules through the current
agent's `Skill::Extension` (which it must track per agent) and `submit`s; otherwise it
`inject_system`s and `submit`s into the boot queue, where order holds. Options:
`submit(text, system: [body])`, or `inject_system(text, run: false)` that only queues, so the
following `submit` carries it.
