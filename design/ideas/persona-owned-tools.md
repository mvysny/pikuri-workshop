# Persona-owned tools

Status: **deferred.** Moved here from pikuri's `subagent-deferrals.md` on
2026-11-16, when pikuri went feature-complete (`pikuri:D_gem_placement`).

The idea: a `SubAgent::Persona` carries its own tool *instances* instead of
naming tools the host registered. Today `SubAgentTool` filters
`parent.tools + parent.sub_agent_tools` by `persona.tool_names`, so a child
always gets the parent's instances, bound to the parent's `Filesystem`, sandbox
and caches.

## What would earn it

A child that needs a tool **configured differently** from the parent's, not
merely hidden from it: a `read` over a narrower `Filesystem`, a `bash` with a
tighter sandbox. Hiding alone is already solved: `add_sub_agent_tool` keeps a
tool away from the parent's LLM while a persona's `tool_names` still reaches it.

## Current state (2026-11-16)

The one such case shipped without this. `Code::GitRepoResearcher` is an
Extension whose tool builds its own child `Pikuri::Agent` over a fresh
`Paths.new_temp` folder, with its own file tools and `git_clone`. It skips
`Persona` entirely, and its yardoc says why: "a persona's tools are the
parent's instances, bound to the parent's workspace." pikuri once carried a
one-purpose version (`Persona#needs_temp_workspace` plus a `with_workspace` hook
on four file tools) and dropped it on 2026-11-15, because no pikuri persona used
it.

So the general shape earns its keep only if a **second** tool like this one
appears and the two hand-built child loops start to duplicate each other. Even
then it can probably live here: a workshop `Persona`-like record whose tool is a
factory `(root) -> [Tool]`, run by a workshop dispatcher. Asking pikuri's
`SubAgentTool` to change is the last resort, and it needs a pikuri-side case
(`pikuri:D_gem_placement`).

## Open questions

- Factory per call (a fresh folder each time, like `GitRepoResearcher`) or per
  persona (one narrowed tool reused across calls)? The only case so far wants
  per call.
- Trifecta placement: a persona's node currently reads its legs off the parent's
  instances. With owned tools it has to read them off the factory's output, the
  way `GitRepoResearcher#trifecta_contribution` hand-lists them.
