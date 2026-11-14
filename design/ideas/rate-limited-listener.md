# A rate-limited listener for hosts that render a stream

Status: **requested by pikuri-tui (2026-11-14); not scheduled.** Two hosts carry near-identical
copies today; this file is about moving one into the workshop so they can delete theirs.

## Why

pikuri-core dropped `Agent::Listener::RateLimited` (its CHANGELOG: nothing in pikuri wired it,
"pacing a renderer's repaints is the renderer's business"; a host keeps a copy). Every host that
renders Markdown from a stream does: a fast llama.cpp sends dozens of deltas a second, and
re-rendering on each is wasted work. Both hosts copied it, and both changed it the same way:

- pikuri-tui `lib/shared/rate_limited_listener.rb` (`Shared::RateLimitedListener`)
- pikuri-webui `lib/pikuri_webui/web/rate_limited_listener.rb` (`PikuriWebUI::Web::RateLimitedListener`)

The shared change: core's `flush_pending_on_non_delta: false` dropped buffered deltas on *any*
non-delta event. Now that `Pikuri::Conversations` puts its own events on the same listener
(`PendingChanged` when the user types mid-reply, from the UI or request thread), that loses
streamed text until the final `Assistant`. Both copies instead **drop a buffered delta only at
its own bookend** (`Assistant` / `Thinking`, which carry the whole text) and **flush ahead of
any other event**, and neither has the knob any more.

## Where — `Q_which_gem`

pikuri-conversations looks right: both consumers already depend on it, and the one thing that
makes the class non-trivial now — events arriving from more than one thread — is that gem's
doing. A one-class gem would be overkill; pikuri-core has said no.

## Lock, or keep conversation events out — `Q_lock_or_bypass`

The two copies disagree, and the shared class must pick:

- **pikuri-tui locks** every `on_event`, inner call included, because it puts the limiter inside
  the one listener `Conversations#open` takes (behind a fan-out), so conversation events from
  other threads reach it.
- **pikuri-webui has no lock**, on purpose: its runner keeps the conversation's events to itself,
  so only agent events — emitted from one thread at a time — come through. A lock would also sit
  outside its `BigAppLock`, which its "domain lock is outermost" rule forbids.

Proposal: **bypass, no lock.** An event that isn't `Pikuri::Agent::Event::*` passes straight to
`inner` without touching the buffers, so the buffers stay single-threaded (the agent's) and no
lock is needed, satisfying webui's rule. Ordering stays right: a conversation event never needs
the buffered text ahead of it — `TurnEnded` comes after the bookend that already cleared it. The
inner listener must then take calls from two threads, which both hosts' already do (they marshal
and return). pikuri-tui would drop its lock and keep its fan-out.

## Also worth deciding

- `Q_stalled_tail` — no timer: tick state advances only when an event arrives (core's design, so
  `cancel!`-style simplicity and no thread). A model that pauses mid-reply leaves up to one
  period's text invisible until its next delta or bookend. Fine at 15 fps for local models; a
  host on a slow, bursty provider might notice. A timer would need a thread or the host's own
  loop (`tick_now` for the host to call from its timer?).
- `Q_sub_agents` — keep `for_sub_agent` wrapping the inner listener's variant (pikuri-tui's copy
  has it; webui's doesn't, since its runner never hands the limiter to a sub-agent's listeners).

## Done when

The class is in the gem with core's old spec ported (pikuri-tui's
`spec/shared/rate_limited_listener_spec.rb` already has the bookend and flush-ahead cases), plus
one spec that a conversation event bypasses the buffers; pikuri-tui and pikuri-webui swap their
copies for it and delete them.
