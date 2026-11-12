# pikuri-skills — AGENTS.md

The Agent Skills standard, slash commands, and the shared `Bundle::*` vocabulary
both search over. Owns the catalog, the path-activation gate, the `skill` tool and the command
registry; how a loaded body reaches the model is the root's Interloper injection seam.

## Invariants

- **Bundle-surface seam (skills vs. commands).** A skill is *model*-invoked and advertised; a **command is never advertised** — no prompt snippet, no tool, and its expansion lands as a `:user` turn, never `:system`. Both take `Bundle::Base(dir:, trusted:)` bases; a refused command never taints. Typed `/name` resolution is the host's: **host built-in > command > skill**. See {Pikuri::Command::Registry}, `design/decisions.md` `D_slash_commands`.
- **Skill path gate.** *A `paths:` skill is not in play until its path fires*: withheld from the prompt block entirely and refused by `SkillTool` / `schedule_load_skill` like a name that exists nowhere. `Skill::Activation` holds the per-conversation set; `Catalog` stays unfiltered. See {Pikuri::Skill::Activation}, {Pikuri::Skill::PathActivationListener}, `design/decisions.md` `D_skill_path_activation`.
- **Sub-agents get no skills.** `SkillTool#for_sub_agent` hands a child a sealed `Skill::Activation`, and no bundled persona names `skill`; the rule is the **Sub-agent propagation** seam in `../pikuri-subagents/AGENTS.md`. See {Pikuri::Skill::Activation::Sealed}, `design/decisions.md` `D_no_skills_in_sub_agents`.
- **Host-driven skill loading** is the enqueue-only, main-agent-only `Skill::Extension#schedule_load_skill`, riding the interloper's `:system` kind (root Interloper injection seam).

Maintenance: the root `AGENTS.md`'s rules; cap 10 KB.
