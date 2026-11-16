# A cheaper model per persona

Status: **deferred.** Moved here from pikuri's `subagent-deferrals.md` on
2026-11-16, when pikuri went feature-complete (`pikuri:D_gem_placement`). It's
an efficiency feature, so it belongs here.

PI runs cheap models on cheap tasks: haiku for its scout, sonnet for its planner
(`pikuri:design/research.md` `R_sub_agents`). pikuri's `SubAgentTool` spawns
every child on `parent.transport`, read at spawn time so that a model switch on
the parent carries over.

## Why it's weaker here than in PI

pikuri's default is a single local llama.cpp server. Usually one model is
loaded, and switching per child means a load or unload measured in seconds,
plus VRAM the iGPU may not have for two models. The win is real only with a
router serving several models at once, or with a hosted provider, which is an
explicit opt-in.

## Shape, if it comes

- Workshop only: a child built by a workshop tool (the `GitRepoResearcher`
  shape) passes whatever `ChatTransport` it likes to `Agent.new`, so no pikuri
  change is needed.
- Through pikuri's `agent` tool, it would need a `transport:` (or a
  `ChatTransport` override) on `Persona`, used instead of `parent.transport`.
  That's a pikuri seam, and it's asked for only when a workshop persona needs
  it (`pikuri:D_gem_placement`).

## Open questions

- Does a cheaper child cost answer quality the parent then spends turns fixing?
  Measure on the local models before building anything.
