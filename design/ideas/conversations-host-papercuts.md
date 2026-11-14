# pikuri-conversations: papercuts from the first host migration

Status: **collected from pikuri-webui's move onto the gem (2026-11-14); the first five are
fixed, these are what is left.** Each
is small, and each cost the host a workaround or a paragraph. The bigger find from the same
migration has its own file: `injection-overtakes-turn-message.md`.

## `clear` answers `:busy` while the agent boots

`close` closes a boot no message waits on; `clear` still refuses every boot. A conversation
opened with `boot: true` sits in `:booting` for its probe — a connect timeout against an
unreachable server — so a `/clear` typed then is refused, and pikuri-tui logs "clear
conversation ignored: a turn is in progress" for a turn that does not exist. Not a guard
away: the boot thread would still install an agent built from the old history, so the fix
needs the boot to learn it was superseded (a generation counter it checks before installing,
say) and a fresh boot started behind it.

## From pikuri-tui's move onto the gem (2026-11-14)

Three more, from moving pikuri-tui's three shells (`Chat` / `Code` / `Computer::App`) off their
own turn loop.

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
