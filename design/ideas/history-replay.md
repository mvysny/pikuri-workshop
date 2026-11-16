# Redrawing a saved conversation: one `History` → events, not one per host

Graduated out of the conversations idea, undecided. Background: a host's transcript is rendered
from the agent's *event stream*, lossily, so it can't be rebuilt from the `History`; redrawing a
stored conversation means synthesizing events (or blocks) from the messages. See
`book/conversations.md`, "A conversation is a thing you store and switch".

## The problem

Two hosts turn a saved `History` into a transcript, two ways. (The dangling-call repair is not
duplicated: core's public `History#repair_interrupted_tool_calls` is what webui calls.)

- **webui's `HistoryReplay`** (145 lines) synthesizes the live `Agent::Event` stream and feeds it
  through the live listener — one renderer, live or reloaded. To fake the stream it mirrors
  pikuri-core's private knowledge: the `<system-reminder>` envelope (the constant is private
  upstream; only webui's live-vs-replay spec catches a rename), the emit order (a `ToolResult`
  right after its own `ToolCall`, not in stored order), the emit-path filters (empty thinking,
  empty assistant text), and no `Tokens` (`HistoryLoaded` reseeds `TokenLog`).
- **Puri's `Core::Replay`** (34 lines) builds its own blocks straight from messages — the "second
  place block kinds are decided" webui's header warns against — and already differs from Puri's
  live view: a `/skill` (`kind: 'reference'`) vanishes on reload, an interrupted call shows
  nothing (no repair), and thinking is dropped (unchecked whether Puri shows it live).
- pikuri-tui never resumes, so needs none.

## Options

- **A. `History#events` in pikuri-core** — the envelope, order and filters stay private to the
  code that emits; the live-vs-replay spec moves into pikuri, failing in the commit that changes
  emission; Puri drops `Replay` and feeds the events through its `TurnListener`. Against: no
  pikuri caller, as no bin resumes — `D_history_file`'s argument, though that one is about
  carrying a format, and this is a pure function over core's own value.
- **B. `Conversations::Replay` in pikuri-conversations**, beside `HistoryFile`: every caller is
  here, but the mirrored private knowledge moves rather than goes.
- **C. Leave it**: two callers, webui's spec catches the worst drift; Puri's reload stays unlike
  its live view.

## Open questions

- `Q_replay_home` — A, B or C.
- `Q_replay_on_open` — with A or B, should `Conversations#open(history:)` replay into the
  listener itself? Not yet: webui replays per browser tab into that tab's SSE stream.
- `Q_puri_thinking` — does Puri render thinking live? If so, its reload dropping it is a third
  difference rather than a choice.
