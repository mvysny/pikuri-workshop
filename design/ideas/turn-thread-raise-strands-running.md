# A turn thread that raises leaves the conversation `:running` forever

Status: **suspected bug, found reading the code (2026-11-14) while fixing
`Closed`-is-last; not reproduced.**

`Conversation#run_turns` rescues `run_loop` and `save` rescues `on_turn_end`, but nothing
rescues `@agent.export_history` at the top of `save`. If it raises:

- the exception leaves `run_turns`; `spawn` logs it and drops the thread count;
- the state stays `:running`: every `submit` injects into a turn nobody runs, `close` answers
  `:busy`, and `close(force: true)` sets `@closing` and cancels a turn that is already gone;
- nothing calls `release`, so no `Closed`, no `on_closed`, the agent is never closed, and
  `wait_closed` / `shutdown(timeout:)` wait out their whole timeout and answer false.

`save`'s yardoc already promises the opposite: "`@return` … `nil` when taking it raised",
and `run_turns` reads it that way (`title(history) if history`). The rescue it describes is
missing.

The same holds for anything else between `run_loop`'s rescue and the restart lock: `title`
(its `history.messages.find` runs on the turn thread) and `probe` (rescued, since it runs
inside the `begin`, so not this). The boot thread is covered: `run_boot` rescues the probe
and the build, and `boot_failed` releases on a close.

## `Q_how_likely`

How does `export_history` raise in practice? It snapshots pikuri's in-memory `History`; a bug
there, or a message a serializer can't take. Rare, but the cost is a conversation that can
never close and a shutdown that always times out, which is the failure the last fix was about.

## Fix sketch

Rescue in `save` around `export_history`: log at error, return `nil`, as its yardoc says.
The turn then goes `:idle` (or `:closed` and releases) as any failed save would. Wider net:
an `ensure` in `run_turns` that, on an exception escaping the loop, moves to `:idle` or
`:closed` under the lock and releases if closing, so no future raise between the rescues
strands the state.

## Done when

- A spec whose agent's `export_history` raises: the turn ends (`TurnEnded`, `:failed` or as
  decided), the conversation goes idle, and `shutdown(timeout: 5)` returns true.
- `save`'s yardoc matches what it does.
