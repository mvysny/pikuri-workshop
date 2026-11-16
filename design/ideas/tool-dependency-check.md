# Tool dependency check

From the prior-art survey: grok-build's `requires_expr`, where a tool declares which other tools it
needs and the registry rejects an incoherent toolset at boot (`pikuri:R_available_tools`).

## The problem

Some tools are useless without a sibling, and nothing notices when the sibling is missing:

- `edit` without `read` → every call fails "has not been read this conversation"; the
  read-before-edit gate can never pass.
- `write` without `read` → it can create files but never overwrite one, for the same reason.
- `web_read_cached` without `web_search` → it takes only handles that `web_search` prints, so it
  has nothing to read.

It's a configuration fault, but nothing raises. The agent just does worse: it retries, works
around the problem, or gives up, and that's hard to trace back to the wiring. It gets more likely
as the workshop builds more toolsets by hand: the coding agent, the OS assistant, personas.

What already exists: `pikuri-subagents`' `Extension#configure` raises when a persona's
`tool_names` names a tool that isn't registered at all. That checks names, not dependencies: a
persona with `edit` and no `read` passes.

## Proposal

The check lives in the workshop, which sees every toolset it builds. The dependency knowledge is a
workshop-side table keyed by tool name (`'edit' => %w[read]`, …), checked once each toolset is
final, including each persona's child toolset. pikuri stays untouched, which is what the
feature-complete rule wants.

## Open questions

- `Q_declaration_home`: should the table live in the workshop, or should each tool declare its own
  needs (`Tool.new(requires: %w[read])`)? A declaration on the tool can't drift from the code, but
  it's a new seam in pikuri-core, and the rule allows that only for a feature that needs it now.
  The workshop table drifts silently when a pikuri tool gains a gate. A spec that wires each tool
  alone and checks that its first call can succeed would catch that, but it costs more than the
  table itself.
- `Q_raise_or_warn`: should it raise at boot, like the persona name check, or log a warning? A
  host might strip `read` on purpose to make `edit` inert, though dropping `edit` would do the
  same job more honestly.
- `Q_scope`: should it cover pikuri's own `bin/pikuri-*` demos? Probably not: they're small enough
  to read, and the workshop can't reach them without the pikuri-core seam anyway.
