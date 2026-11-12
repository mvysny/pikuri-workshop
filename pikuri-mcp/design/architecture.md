# pikuri-mcp design notes

Audience: someone extending pikuri-mcp. The per-class contracts live in
YARD. Most of what would normally fill an MCP gem's design doc is already
homed elsewhere, and is deliberately **not** repeated here:

- **The threat model** — what wiring an MCP server does and doesn't
  protect against (pre-flight verification, `mcp_connect` gating,
  per-agent activation, container isolation; and the *doesn't*-protect
  list: server execution, LLM-judge fallibility, token blast radius,
  plain HTTP, poisoned runtime responses) — is `book/mcp-revisited.md`.
  The defense-kit synthesis is `book/security.md`; the shipped
  defenses are `SECURITY.md`.
- **The invariants** — the `Subprocess.spawn` stdio carve-out, why MCP
  tools bypass `Pikuri::Tool`, and the `env` credential channel — are
  this gem's [`AGENTS.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/AGENTS.md) seams whose authoritative text lives in the
  {Pikuri::Mcp::Servers} / {Pikuri::Mcp::ClientWrapper} /
  {Pikuri::Mcp::Registry} YARD.

What this file owns is the one cross-cutting thread none of those cover:
the **boot-time LLM-introspection subsystem** and the cancel/degrade
policy it runs under — a rule currently instantiated across several
classes, stated here once as the authority.

## Boot-time introspection: one Thinker shape, two consumers, one Cache shape

At boot, {Pikuri::Mcp::Extension}`#configure` builds a
{Pikuri::Mcp::Synthesizer} (the `<available_mcps>` description writer) and
a {Pikuri::Mcp::Verifier} (the injection pre-flight) from the
Configurator's *own* transport + cancellable — so both passes run against
the agent's own model and honor the same boot-time Ctrl+C flag. Each is
built from the same two collaborators:

- a **{Pikuri::Mcp::Thinker}** — a fresh, tools-free, listener-less
  {Pikuri::Agent} per call. Fresh-per-call so per-server prompts can't
  accumulate in one chat and cross-contaminate; the construction cost is
  noise next to the round-trip, and the cache short-circuits before a
  call fires anyway. Cancellation is polled once *before* each call
  (gentle-cancel: a flag flipped between calls raises promptly; the
  in-flight HTTP is never interrupted). The flag is deliberately kept
  *out* of the one-shot agent, whose `run_loop` would reset it at the
  turn boundary and erase a pending Ctrl+C.
- an on-disk **{Pikuri::Mcp::Cache}** — the two consumers write to
  *sibling* directories (`Cache::DIR` vs `Verifier::CACHE_DIR`), so a
  synthesized description and a verification verdict never collide despite
  sharing the same key-fingerprint shape. Each consumer also folds its
  own `PROMPT_VERSION` into that key, so editing a prompt self-invalidates
  the previous prompt's entries with no manual `rm`.

## The cancel / degrade policy

One rule governs every boot pass: **`Cancellable::Cancelled` propagates
to abort the *whole* startup (a boot-time Ctrl+C); any other
`StandardError` degrades exactly *one* server and never the boot.** The
per-consumer dispositions that implement it:

- **Synthesizer** — a flaky LLM or a cache-write failure is WARN-logged
  and returns `nil`, so {Pikuri::Mcp::Servers}`#resolve_description` falls
  through to `serverInfo.name`. A transient blip never drops a server from
  the `<available_mcps>` listing.
- **Verifier** — `InjectionDetected` (and any provider error) bubbles out
  of `Servers#start_one`, so a flagged server never enters
  `Servers#live_ids`.
- **`Servers#start_one`** — the boundary that enforces the split: it
  re-raises `Cancelled` and `InjectionDetected` (the user must see the
  reason, not a generic "Failed to start" warning) and WARN-logs-and-drops
  every other `StandardError` — including the "verifier passed but
  `resolve_description` / `log_audit` then raised" path.
