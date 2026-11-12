# pikuri-skills

[Agent Skills standard](https://agentskills.io/specification)
support for the [pikuri](https://codeberg.org/mvysny/pikuri)
AI-assistant toolkit — plus its human-invoked counterpart, slash
commands.

Provides:
- `Pikuri::Skill::Catalog` — discovery + validation of skill folders
  under `.pikuri/skills`, `.claude/skills`, `.agents/skills` beneath
  each *search base* you supply (typically the project root and
  `Dir.home`).
- `Pikuri::Skill::SkillTool` — the loading tool the LLM uses to pull
  a skill's body into the conversation on demand.
- `Pikuri::Skill::Extension` — wires both into a `Pikuri::Agent` via
  the `c.add_extension(...)` block API.
- `Pikuri::Command::Registry` / `Pikuri::Command::Renderer` — slash
  commands: prompt templates *you* invoke by typing `/name`, scanned
  from `.pikuri/commands` and `.claude/commands` under the same search
  bases. Never shown to the model, so they cost nothing in the system
  prompt.

## Install

```ruby
# Gemfile
gem 'pikuri-skills'
```

## Usage

```ruby
require 'pikuri-core'
require 'pikuri-skills'

# Pass the directories to search under. The catalog scans
# .pikuri/skills, .claude/skills and .agents/skills beneath each base;
# missing subdirs are skipped. Earlier bases beat later ones on a
# name collision.
catalog = Pikuri::Skill::Catalog::Bundled.new(
  search_bases: [project_root, Dir.home]
)

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension(Pikuri::Skill::Extension.new(catalog: catalog, root: project_root))
end
```

When the catalog is non-empty, the extension's `configure` appends
`<available_skills>` to the system prompt (listing every discovered
skill) and registers the `skill` tool. The LLM invokes `skill` with a
name; the tool returns the skill's body wrapped with its base
directory so the LLM can resolve sidecar files via `read`.

## Skills that wait for the right project

A skill only some projects need can say so in its frontmatter, and stay
out of the prompt everywhere else:

```yaml
---
name: writing-rdoc
description: Writing Ruby doc comments — which level each fact belongs at.
paths:
  - "**/*.rb"
  - "**/*.gemspec"
when-to-use: >-
  About to write or edit a # comment, or a @param/@return tag.
---
```

Such a skill is withheld completely — no name, no description, and the
`skill` tool refuses it exactly as it refuses a name that exists nowhere.
The moment the agent reads, writes or edits a file matching one of the
globs, its description arrives in the conversation and it becomes
loadable. `/clear` hides it again.

Patterns are gitignore syntax, so a slash-less pattern matches at any
depth and a bare directory covers everything beneath it. Two things
worth knowing before you write one:

- **`paths: []` means *always advertised*, not "never"** — as does
  `paths: ["**"]`, and a bare `paths:` with nothing under it.
- **Give the agent an `interloper:`** (`Pikuri::Agent::Control::Interloper.new`).
  A promotion arrives as a mid-loop injection, so without one there is
  nowhere for it to land — pikuri then leaves every skill advertised and
  logs a warning, rather than hiding one it could never bring back.

## Slash commands

A command is one Markdown file. The model is never told it exists —
you invoke it by name, and what it expands to becomes *your* next
message:

```ruby
registry = Pikuri::Command::Registry.new(
  search_bases: [project_root, Dir.home]
)

# ~/.claude/commands/wh.md  ->  /wh
text = registry.expand('wh', arguments: 'swingai')   # nil if no such command
agent.run_loop(user_message: text)                   # it *is* your turn
```

`$ARGUMENTS` in the body becomes everything you typed after the name;
`$1`…`$9` are its whitespace-separated words. Both are left alone
inside backticks and fenced blocks, so a body that *writes about* its
own arguments survives expansion. If the body mentions neither, what
you typed is appended as `ARGUMENTS: …` instead of being dropped.

A file's path is its name: `commands/frontend/deploy.md` is
`/frontend:deploy`. Frontmatter is optional; `description` and
`argument-hint` feed a menu, everything else is ignored — except
`allowed-tools:`, which is refused, as is a body containing a
`` !`cmd` `` directive. pikuri will not run a shell command because
you typed a slash, and it will not silently *widen* a toolset an
author asked to narrow. Add
`Pikuri::Command::Extension.new(registry: registry)` to the agent so
the trifecta report knows the commands are there.

Try it in `bin/pikuri-code`: it lists the commands it found at boot
and dispatches a typed `/name`.

## Further reading

- **Narrative walkthrough:**
  [the skills chapter of the pikuri guide](../book/skills.md) —
  how skill folders are discovered, the `SKILL.md` format, and a
  worked drop-in example. (Currently a stub chapter; the API
  surface lives in the YARD docs below.)
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-skills> (once published), or
  run `bundle exec yard` in this directory for a local copy.
