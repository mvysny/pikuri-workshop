# A message sent at a turn's start overtakes the turn's own message

Status: **bug, reproduced from pikuri-webui (2026-11-14); fix not chosen.** Found while moving
pikuri-webui onto `pikuri-conversations`; its runner spec had to wait for the turn to park in a
`Testing::Gate` before sending the second message, or the assertion saw the two swapped.

## What happens

`Conversation#submit` from `:idle` moves the conversation to `:running` under the lock and
spawns the turn thread. From that moment a second `submit` answers `:injected` and goes into the
agent's `Interloper`. But the turn thread has not reached `run_loop` yet — it first emits
`TurnStarted` and runs `probe(transport)` — and `Agent#run_loop` **drains the Interloper ahead
of its own `user_message`** (`drain_interloper`, then append; the comment there says "ordered
ahead of the user message appended below").

So for `submit('one')` then `submit('two')` landing in that window, the model receives
`two`, then `one`, and the transcript shows them in that order:

```
UserTurn("two", mid_loop: true)
UserTurn("one")
Assistant(...)
```

The window is not microseconds in practice: `probe` calls `Probe.props`, which on a router
with a cold model **loads the model** (seconds to tens of seconds) — exactly when a user, seeing
nothing happen, types a follow-up.

## Why it slipped through

The drain-ahead order is right for both callers pikuri-core had in mind — a host-scheduled skill
block (`inject_system`), and the gem's own boot case, where messages that waited for the agent
are injected *before* the last one becomes the turn's message, so they really are earlier. It is
wrong only for an injection that arrived *after* the turn's message was accepted.

## Options

- **(a) Deliver the turn's own message through the Interloper too**: `start_turn` injects it
  and the thread runs a bare `run_loop`. Order is then FIFO by construction. Cost: the first
  message of every turn renders as `UserTurn(mid_loop: true)`, which hosts may style
  differently — or the flag's meaning narrows to "arrived after the turn began".
- **(b) Hold late messages in `@waiting` until `run_loop` has started**: a `:starting`
  sub-state between `:running`'s claim and the drain. Keeps `UserTurn` flags as they are, but
  needs a signal from inside `run_loop` (a listener seeing the turn's own `UserTurn`?) to
  release them, and the gem never sees inside a turn.
- **(c) A pikuri-core change**: `run_loop(user_message:, drain_first: false)` or appending the
  message before the drain when the caller says so. Smallest diff, but leaks a scheduling
  concern into core, which `pikuri:D_gem_placement`'s rule argues against.

(a) looks like the cleanest; check what pikuri-tui and Puri render for `mid_loop: true` first.

## Done when

A spec in `conversation_spec.rb`: hold the probe (stub `Detector.detect` on a `Queue`), submit
twice, release, and assert the history's user messages are `one, two`.
