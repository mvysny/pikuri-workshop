# Persona catalog: personas written as Markdown

Status: **deferred.** Moved here from pikuri's `subagent-deferrals.md` on
2026-11-16, when pikuri went feature-complete (`pikuri:D_gem_placement`).
Personas written by users are a feature, so they belong here.

Today a persona is a Ruby constant (`Pikuri::SubAgent::RESEARCHER`,
`FILE_MINER`) handed to `SubAgent::Extension.new(personas: [...])`. That's
enough while personas ship only with the code.

## The proposal

- A persona is a Markdown file with YAML frontmatter: `name`, `description`,
  `tools:` (the `tool_names`). The body is the `system_prompt`.
- Discovery under `.pikuri/personas/*.md`, `.claude/agents/*.md` and
  `.agents/personas/*.md`, the same three-root shape `Skill::Catalog::Bundled`
  scans for skills.
- A workshop gem (`pikuri-personas`?) with a `Catalog` that builds
  `SubAgent::Persona` records and an `Extension` that hands them to
  `SubAgent::Extension`. pikuri's `Persona` and `SubAgentTool` stay as they
  are: the catalog only produces records.
- Tool-name validation changes from raise to WARN-and-prune: a persona that names
  a tool this host didn't wire just disappears, because a user's persona
  folder outlives any one host's wiring.

## What would earn it

Three or more personas in use, and a user who wants to write their own.

## Open questions

- **Trifecta.** A persona file chooses its own toolset, so a cloned repo's
  `.claude/agents/` could name three legs. Validation has to check the persona
  against the map (at most two legs) and reject it, not prune it. This is
  the one place where pruning is the wrong reflex.
- **Folder trust.** Same gap as the skills catalog
  ([`borrowable-from-prior-art.md`](borrowable-from-prior-art.md) item 1). A
  repo-supplied persona's prompt is untrusted text reaching a child's system
  prompt, so the trust gate on the source should cover personas too.
