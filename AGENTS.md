# pikuri-workshop — AGENTS.md

## What this is

The power tools for [pikuri](https://codeberg.org/mvysny/pikuri), a small Ruby AI assistant:
a shell, a coding agent, language servers, MCP servers, Agent Skills, durable memory and an
OS assistant, plus what a chat app needs to host many conversations and save them. Each is a
gem you wire à la carte. The tools that run code you didn't write run in a cage, and the book
says what the cage buys and where it stops.

## Promises

- **Powerful, yet simple enough to teach.** Every gem does real work and still teaches a lesson the book can tell; a gem that stops teaching has stopped belonging here.
- **Lifting the cage takes a VM.** Some gems run dangerous material in a cage, which runs on your host and says where it stops; `--yolo`, unattended runs and code you don't trust go inside a virtual machine around the whole process, since a shared kernel is a thin wall. The OS assistant is no exception, but its point is your host, so there it keeps its cage: a network the kernel has cut.
- **The code may be complex.** pikuri's "readable in an evening" does not hold here: a gem carries the complexity the real world forces on it, and the book explains the hard parts rather than every line.

## Design docs

| File | Owns | Loaded |
|---|---|---|
| `README.md` | the pitch, install, routing onward | — |
| `AGENTS.md` (this) | promises, invariants, the module map, conventions, commands | every turn |
| `design/decisions.md` | why this and not that — `D_` entries, FAQ-shaped | lazy |
| `design/research.md` | what other harnesses do about sandboxes, skills, commands, MCP, memory — `R_` entries | lazy |
| `design/ideas/` | not yet decided — one file per idea, `ls` is the index, deleted on graduation | transient |
| `<gem>/design/architecture.md` | that gem's own cross-symbol picture + its threat model | lazy |
| yardoc (source headers) | what one symbol does, why it is shaped so | at the symbol |
| `book/` | book 2, "the workshop": a learner reading in order, after pikuri's book | — |
| `SECURITY.md` | what the workshop adds to pikuri's threat model, and where the promise and the code disagree | — |
| `CHANGELOG.md` | what changed and what you must do about it | — |

Every fact lives in exactly one of these; the others link to it. pikuri's own docs are the
home of everything about pikuri; a cite into them is qualified, `pikuri:D_<slug>`.

## Invariants

- **Dependencies point from the workshop to pikuri, never back.** Nothing in pikuri may require a workshop gem; a change that needs one belongs here. See `D_separate_repo`.
- **pikuri's invariants hold here.** Every seam in pikuri's `AGENTS.md` binds workshop code too — the loop, connection, subprocess, teardown, interloper and history seams above all; `tasks/tripwires.rake` re-checks the five that break silently.
- **Every tool declares `trifecta_legs`**, and an agent holding all three legs runs in a cage — the cage, not a filter, is the defense. See `pikuri:D_egress_axis_shape`.
- **A long-lived child is de-bundlerized** and gets credentials only through its per-child `env:`. See `pikuri:D_de_bundlerized_children`.

## Module map

Rails-shape monorepo: each gem owns its `lib/`, `spec/`, gemspec, entry file, and where relevant
its `bin/`, `prompts/` and `design/`. The root `Gemfile` wires every gem via `gemspec path:` and
pikuri's gems from its repo at one pinned commit; the `Rakefile` fans out `rake test` and orchestrates
`rake release`.

- `pikuri-code` — `Bash` + sandbox + `bin/pikuri-code`, the in-repo coding agent. Rules: `pikuri-code/AGENTS.md`
- `pikuri-os` — offline, network-severed OS-helper agent + `bin/pikuri-os`; hosts the `bin/pikuri-computer` demo.
- `pikuri-lsp` — LSP client for read-only code navigation: the `lsp` tool + `bin/pikuri-lsp-check`. Rules: `pikuri-lsp/AGENTS.md`
- `pikuri-mcp` — Model Context Protocol support + `bin/pikuri-openlibrary`, the one-MCP demo. Rules: `pikuri-mcp/AGENTS.md`
- `pikuri-skills` — Agent Skills standard, slash commands, the shared `Bundle::*` vocabulary. Rules: `pikuri-skills/AGENTS.md`
- `pikuri-tasks` — in-memory per-agent task list + four `task_*` tools.
- `pikuri-memory` — durable cross-conversation memory backed by mem0 + `bin/pikuri-memory`.
- `pikuri-extractors` — office/EPUB/RTF/PDF → Markdown for pikuri's `Extractor` registry via a one-shot networkless docker container.
- `pikuri-stemmers` — a stemmer per language for pikuri-rag's `stemmer:` (Finnish via Voikko); each takes its library as a host-opened handle and requires none.
- `pikuri-conversations` — host many live conversations (`Conversations`, `Conversation`: an agent each, turns on own threads; `Throttle`, requests in flight per server; `Titler`; `RateLimitedListener`, streamed deltas at a frame rate) and store them: `HistoryFile`, the stored form of pikuri's in-memory `History`, and `Store`, a folder per conversation.
- `book/` — book 2, "the workshop"; `book/README.md` is the ToC and the single source of truth for chapter order.
- `version.rb` — the workshop's lockstep version and the pikuri release it requires; read by gemspecs only.

## Conventions

- **A gem lives here if it fails either of pikuri's placement tests**: its future is more features rather than explaining better, or it isn't safe on your host as-is. A gem that passes both may move back.
- **Ruby, no Rails.** Plain classes, `Data.define` value objects, Faraday for HTTP, Rainbow for color; ruby_llm is the only LLM transport, reached only through pikuri-core.
- **Linux-first; macOS may work; Windows is unsupported.** POSIX shell, GNU `timeout`, XDG cache layout, SIGTERM process-group cleanup.
- **`# frozen_string_literal: true`** atop every Ruby file (`lib/`, `spec/`, `bin/*`).
- **YARD on every public module/class/method** in `lib/`: concrete `@param` / `@return` types, `@raise` for expected exceptions, one-line summary then tags, and the local *why*.
- **pikuri is pinned by commit.** The `Gemfile`'s `PIKURI_REF` names a commit already pushed to pikuri's repo — never a branch, never a local override — so the Gemfile says which pikuri the workshop was built against and CI can always fetch it.
- **A gemspec's runtime dependencies are what its `lib/` requires.** Workshop siblings pin `= Pikuri::Workshop::VERSION`, pikuri's gems `Pikuri::Workshop::PIKURI`; a gem only a `bin/` or a spec uses comes from the root `Gemfile`.
- **Per-gem Zeitwerk loaders**, eager-loading at boot; no `require_relative` inside a gem's `lib/`. One constant per file at the Zeitwerk path, everything under `Pikuri::`, acronyms need an `inflector.inflect` entry, no top-level constants.
- **Tests: rspec-core with minitest-style asserts.** `describe` / `it` but `assert_equal` / `assert` / `refute`, no RSpec matchers, no rspec-mocks (stub with `define_singleton_method` in `before`, restore in `after`). Pattern: `pikuri-code/spec/pikuri/code/bash_spec.rb`.
- **Diagnostics go through `Pikuri.logger_for('Name')`**, never `puts` / `warn` / `$stderr`; listener rendering on stdout via `Terminal` is not logging.
- **Cache & temp paths go through `Paths`**; never read `ENV['XDG_CACHE_HOME']` or hardcode `~/.cache`.
- **Errors are loud.** Unexpected internal state raises with the offending data; failures the LLM can react to answer `Tool::Result.error(message)`.
- **Every tool declares a sharing posture**, a `Sharing:` yardoc line naming `P_stateless` / `P_shared_locked` / `P_shared_benign` / `P_one_agent`. See `pikuri:D_tool_sharing_postures`.
- **Tool descriptions follow opencode-shape:** one-line summary, blank line, `Usage:` bullets; per-arg constraints go in the *parameter* description with an example value.
- **Tool naming: a prefix marks a family, a universal verb goes bare.** `foo_*` = a family sharing one backing resource; `bash`, `lsp`, `skill` stay bare. See `pikuri:D_directory_listing`.
- **No tool names in a main/binary system prompt.** `prompts/<bin>.txt` names no wired tool; persona prompts are the carve-out.
- **A `bin/` script is simple on purpose**, so its simplifications are not policy — never cite one as evidence of how a gem behaves.
- **Book chapters are named, not numbered** — never an ordinal, anywhere. A new concept is one `book/<slug>.md`, one line in `book/README.md`, and fixed neighbouring "What's next" links.
- **A chapter's claim is measured, not read off the code**: boot the bin, probe the sandbox, bring the stack up; what went untested is said in place. Every chapter revisited so far had a claim a run contradicted.
- **pikuri's book links into this one**, by file and sometimes by heading anchor: renaming or cutting a chapter or a heading needs a pikuri-side fix too (`grep pikuri-workshop/blob` in its `book/`).
- **Podman over docker** in commands, chapters and bins when it's installed; docker stays the fallback.
- **A CHANGELOG entry is one sentence**, new work under `[Unreleased]`, a shipped section closed.
- **The seam checks in `tasks/tripwires.rake` are a closed set of five.** A new invariant is a line here and stays unchecked. See `pikuri:D_tripwire_bar`.
- **User-facing docs: prefer concrete over abstract.** "Delete your home folder" beats "filesystem mutation outside the workspace".

## Commands

- `bundle exec rake check` (also the default task) — specs across every gem, then `tripwires`, then `design_tripwires`; what CI runs on push and pull request (`.github/workflows/ci.yml`).
- `bundle exec rake tripwires` — the five seam checks. A failure is as often a stale expectation as a real violation — read the lines before "fixing" the code.
- `bundle exec rake design_tripwires` — the doc layer (`design/verify_design_tripwires.sh`); same rule about stale expectations.
- `cd pikuri-code && bundle exec rspec spec/pikuri/code/bash_spec.rb:42` — one test; run from the gem dir, whose `.rspec` loads its `spec_helper`.
- `bundle exec rake release VERSION=x.y.z` — every workshop gem in lockstep, one OTP window (`pikuri:D_release_one_otp`); set `Pikuri::Workshop::PIKURI` to a released pikuri first.

## Skills this project follows

- **Component-oriented:** self-sufficient components that reach their data directly, no MVC layers; inherit to *be* a thing, never to share code. The `cop` skill has the rules.
- **Yardoc is browsed standalone on rubydoc.info**, so each header carries the complete local what *and* why, deferring only the book-wide narrative. The `writing-rdoc` skill has the rules.
- **An idea file is temporary:** it lives in `design/ideas/`, one per file, `ls` is the index, and graduation is not done until the file is gone and its nuggets are in the durable homes the table above names. The `ideas-folder` skill has the procedure.
- **This doc layer** — the loaded file, the lazy `design/` files, the tripwire — is the `design-docs` skill's shape.

## Maintenance of this file

Loaded every turn; cap 34 KB. Over it, in this order:
delete what has no home — status, history, class lists, what the code already says; trim
each line to its fact plus one clause and send the explanation home — why →
`design/decisions.md`, how across symbols → `<gem>/design/architecture.md`, how in one symbol →
its doc comment, what upstream does → `design/research.md`; only then a module's own
`AGENTS.md`, peripheral modules first, never the core. Never paraphrase a lazy entry into a
line here. `design/verify_design_tripwires.sh` checks the cap and the cites.
