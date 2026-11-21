# Injection tripwire: the shell, and what to do on a repeat

Status: **idea, not built.** The workshop's half of the injection
tripwire, split off on 2026-11-21. Pikuri's
[`warn-human-directly.md`](https://github.com/mvysny/pikuri/blob/master/design/ideas/warn-human-directly.md)
owns the rest: the delivery channel — an alert event the LLM never
authors, rendered as chrome — and, in its §"The injection tripwire", the
insight (a `Pikuri::Sanitizer` flag on bytes the LLM *authored* — bidi
override, zero-width, control byte, mixed-script homoglyph — is a
prompt-injection signal, where the same flag on bytes it merely
*relayed* is display safety) and the first producer, `ComposeGuard`'s
fail-close on a mail body. That is pikuri's own work for its secretary;
this note rides it and asks pikuri for nothing more. Until the alert
event ships, the shell producer below has nowhere to emit to.

## `bash` as the second producer

A bidi or zero-width byte in a command the LLM wrote is the same
hide-from-the-reviewer move as one in an email body it composed. Today
`Code::Bash.visible` sanitizes the command for the observation echo and
drops the `Sanitizer::Warning`s, because they surface at the
confirmation prompt before the user approves. That holds only while
there *is* a prompt: under `--yolo` (or any session grant that skips the
confirm) the warning goes nowhere. An alert is information, not a
decision, so it must fire even when the gate is off — the ask-vs-tell
split pikuri's note makes.

- Where is the shared chokepoint? A helper both confirmers call when the
  flagged text is LLM-authored, or the alert emitted from `Bash` itself
  before it reaches the confirmer? Provenance stays at the call site,
  which already knows the argv is LLM-authored; `Sanitizer` does not
  grow a provenance flag.
- Does the tripwire block the command, as `ComposeGuard` blocks the
  draft, or only alert? A blocked command the model can retry with
  plain bytes is the same "symptom treated, disease in-context" problem.

## Escalating on a repeat

The first trip is an alert and advice, never an automatic teardown:
false positives exist (the user asked it to quote a message that carries
such bytes), a crafted input that kills every session is an availability
lever, and tearing down loses the user's working session. A *second*
trip in the same session, after the warning, is near-conclusive, and a
harder default is defensible then — auto-clearing the context, still
short of killing the process.

- Who counts? A listener on the alert events, per session; which host
  owns it (`bin/pikuri-code`'s REPL, the OS assistant)?
- Clearing the context is not enough when the poison lives in a durable
  store: re-running the same search re-reads the hostile message. The
  clear has to come with the source named ("don't re-open that
  message"), never a silent wipe that lets the user walk straight back
  in.

## A one-step "start fresh"

The advice pikuri's alert gives ("drop this conversation, the message it
just read may be hostile") wants an affordance, not homework: one key or
command that starts a clean session, offered right in the alert. That is
a host's UI — each workshop binary with a REPL, and pikuri-tui — rather
than anything an agent or a gem owns.
