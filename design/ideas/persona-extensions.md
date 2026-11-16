# A persona that wires extensions into its child

Status: **deferred, no case yet.** Moved here from pikuri's
`subagent-deferrals.md` on 2026-11-16, when pikuri went feature-complete
(`pikuri:D_gem_placement`). MCP and Skills are the workshop's, so a child that
wants them is a workshop question.

Sub-agents inherit no extensions: `Extension#configure` runs once, on the
parent. Skills were then ruled out on purpose (`D_no_skills_in_sub_agents`).
MCP was never asked about.

## What would earn it

A persona that needs MCP-backed tools: say, a browsing persona whose
Playwright tools come from `pikuri-mcp`.

## Shape, if it comes

Start from scratch, not by re-adding inheritance. The likely shape is a
declaration of which extensions the child wires for itself. Two things already
point at how to do it:

- `GitRepoResearcher` shows that a workshop tool can build its own child
  `Pikuri::Agent`, and that child's `Agent.new` block can `add_extension`
  whatever it likes. A persona-shaped wrapper over that needs no pikuri change.
- `D_mcp_catalog_and_connections`: the catalog is built once per process, but
  every agent spawns its own servers. A child per `agent` call means a server
  start per call, which costs time and may be fine.

## Open questions

- Trifecta: an MCP tool's legs are known only after connect, so the persona's
  map node can't be placed at wiring time the way a fixed toolset's is.
