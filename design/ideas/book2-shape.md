# Book 2's shape: ending on a simple coding agent

Status: **running order agreed; chapter-by-chapter rewrite paused after three of ten
chapters (shell, OS assistant, memories). Next: audit "Your first MCP server"** (see
"Progress" below). Carried over from pikuri's
`pikuri-workshop.md` idea, which deferred it until this repo existed. `book/README.md` now
lists the chapters in the order below; the ones not yet revisited moved here as they were, so
their "What's next" links still follow pikuri's old order.

`Q_book2_shape`: book 2 ends on **a simple coding agent** (`pikuri-code`), the way pikuri's
book ends on a plain CLI personal assistant (`bin/pikuri-secretary`). The two climaxes pair
up: pikuri's is broken by construction; the workshop's is the agent people actually run, which
can't be, because it holds all three legs at full strength. So its chapter is about what each
defense (the sandbox, the confirmer, the passive-command detector) buys and where it stops,
which absorbs most of `security-revisited.md`.

## Bare first, completed last

`pikuri-code` can't *first appear* in the climax: `skills.md`, `mcp-revisited.md`, `lsp.md`
and `tasks.md` all wire into it or assume it exists. So the shell chapter starts a **bare**
`pikuri-code` (a shell, its cage, the file tools), each middle chapter bolts one piece onto it,
and the climax is the **completed** agent: assembled, then accounted for. That keeps the pairing
with the secretary and needs no per-chapter demo agent. `memories.md` and `wire.md` don't lean
on `pikuri-code` and need no change for this.

## The VM is the outer wall, not a second sandbox

One bash sandbox, Bubblewrap, stated honestly with its limits; lifting them (`--yolo`,
unattended runs, a repo you don't trust) means running the whole process inside a VM. No VM
implementation of the `Sandbox` seam. The promise in `AGENTS.md` says so.

What that does to the book:

- The shell chapter opens on Bubblewrap; book 2 asks for no VM before the climax.
- Every middle chapter's "where it stops" ends the same way. Skills' scripts, MCP servers
  in Docker on a shared kernel, and language servers evaluating a hostile `build.gradle` on
  your host are each closed by one wall: the VM.
- The climax's confirmer story runs out on `bundle exec rspec`. The passive-command
  detector can never approve a command that runs project code, which is the coding agent's
  daily loop (`bash-confirmer.md`). The VM is what makes not asking safe: attended means
  Bubblewrap plus the confirmer; `--yolo` or unattended means the VM.
- `security-revisited.md`'s outer-Docker section becomes an outer-VM section. Docker inside
  the VM is fine, since an escape lands in the VM, so the Docker-in-Docker warnings mostly
  go; outer Docker stays as the weaker option, on a shared kernel.
- A boot check that refuses or loudly warns on `--yolo` / `--no-sandbox` outside a VM would
  back the promise in code; it is already an entry in `security-open-questions.md`.

## Running order

1. **The shell and its cage**: bare `pikuri-code`, Bubblewrap, the sandbox seam. Harvests
   `code.md`'s sandbox half and `os-assistant.md` Part 1's seam introduction.
2. **The OS assistant**: the same seams, the opposite cut (`FullFsNoNet`). Its point is your
   host, so on the host its cage stays on; `--yolo` is for a VM, to compare how it feels.
3. **Memories**: mem0, automatic capture on a no-egress agent.
4. **Your first MCP server.**
5. **MCPs revisited.**
6. **Skills**: after MCP, since "why a skill needs a trigger and an MCP server doesn't"
   needs MCP already met.
7. **The wire chapter**: a debugging interlude, right after skills because its motivating bug
   is the withheld-skills injection. The one chapter not about power and its cage.
8. **Language intelligence.**
9. **Task tracking**: a short chapter, not folded into the climax. The climax is already
   `code.md`'s other half plus `security-revisited.md`, and tasks carries its own lesson
   ("the training prior always wins").
10. **The coding agent, completed**: the climax.

## How each chapter is revisited

In running order, one chapter per commit:

1. **Audit**: the chapter against its bin and the code it describes; what's wrong, stale, or
   badly illustrated by the bin.
2. **Decide**: a short findings list goes to the owner, each marked text-fix or code-fix.
3. **Rewrite + code**: the chapter, the bin, specs where code changes, `rake check`.
4. **Commit**: with the chapter's "What's next", its `book/README.md` line, and inbound links.
   Grep finished chapters for anything a code change touched.

Each finished chapter strikes its part of this file; after the climax the file graduates.

Habits that paid off on the first three chapters:

- **Run, don't just read.** Boot the bin (`< /dev/null` skips the TTY prompts and prints the
  trifecta report), probe the sandbox directly (`Code::Bash.run` with `AUTO_APPROVE`), bring
  a docker stack up and test from inside it. Each chapter had at least one claim the code
  contradicted, and two had a security gap only a run showed.
- **Check pikuri's book before renaming or cutting.** pikuri's chapters link into this repo
  (`~/work/my/pikuri/book`, `grep pikuri-workshop/blob`); they link files, plus one anchor.
- **Prefer the book's own question over the old text.** "What can this cage reach, and
  where does it stop?" found the mem0 store's open network, which the chapter never asked.
- **The dev box has no `socat`** and the llama.cpp router isn't always up: say what went
  untested rather than skip the run.

## Progress

| # | Chapter | Source files | State |
|---|---|---|---|
| 1 | The shell and its cage | `shell.md` (from `code.md`'s first half, `os-assistant.md` Part 1 seams) | done, `828ad36` |
| 2 | The OS assistant | `os-assistant.md` | done, `d660655` |
| 3 | Memories | `memories.md` | done, `7932dc7`; end-to-end recall untested |
| 4 | Your first MCP server | `mcp.md` | — |
| 5 | MCPs revisited | `mcp-revisited.md` | — |
| 6 | Skills | `skills.md` | — |
| 7 | The wire | `wire.md` | — |
| 8 | Language intelligence | `lsp.md` | — |
| 9 | Task tracking | `tasks.md` | — |
| 10 | The coding agent, completed | `code.md` (rest), `security-revisited.md` | — |

What the three done chapters changed beyond their text:

- **Shell:** new `book/shell.md`; `code.md` lost its first half; `bin/pikuri-code` asks the
  skills trust question only when the project ships bundles, and points `--yolo` at a VM.
- **OS assistant:** Part 1 cut to what differs from `shell.md`, plus "Lifting the cage, and
  where" (`--yolo` is for trying it in a VM). The flags stay, by the owner's call; both OS
  bins point them at a VM. The promise now says the OS assistant keeps its cage on the host.
- **Memories:** the mem0 stack has no route out (`internal: true` network, a socat
  `front-door`, `MEM0_TELEMETRY=false`), verified from inside the container; `Mem0Server`
  lost `container_router_url:` and `qdrant_port:`. New section "…and neither can the store".

### Carried forward

- **Memories, end to end.** Store-and-recall through the new network cut is untested: it needs
  `socat` on the host and the llama.cpp router up. Run `pikuri-memory/bin/pikuri-memory`, tell
  it a fact, quit, rerun, ask.
- **Your first MCP server (next).** Already spotted: `mcp.md`'s opening assumes pikuri's old
  order ("the security chapter explains why", "up to the memories chapter every tool … was
  bundled"). Ask the book's question of its container too: what can the Open Library server
  reach, and does it need more than that one host?
- **MCPs revisited.** Opens with ordinals ("[8](code.md) and [9](security-revisited.md)"),
  which the book bans; it wires the GitHub MCP into `pikuri-code`, which the bare-first plan
  allows.
- **The coding agent, completed.** `code.md`'s wiring block is stale: it shows `add_tool` per
  file tool and `Bash`, where the bin now uses `Workspace::Extension` + `Code::Extension`
  (which also adds `git_clone` and plan mode) plus `Command` and `Lsp`; "four extensions" and
  "six tools take `workspace`" are wrong. The private-repo boot question and the trifecta
  banner get one line in `shell.md`; their full story is pikuri's trifecta chapter. pikuri's
  `book/security.md` links `security-revisited.md#wrapping-pikuri-in-docker`, the one anchor pikuri
  holds into this repo: renaming that section to the outer VM means fixing pikuri too. The
  accounting should also count the mem0 API: unauthenticated on `127.0.0.1:8888`, so the
  coding agent's sandboxed `bash` (shared network) can read every memory. The fix, a
  unix-socket front door, is in `pikuri-memory/design/architecture.md`.
- **Language intelligence.** `lsp.md` cites "a rule from the coding agent chapter" for its
  walked-path note; that rule (credential denylist on walked paths) lives in neither chapter
  now. Find its home when that chapter is revisited.

## Open for the climax

"Simple" means checking whether each candidate earns a place:

- **No automatic memory, and saying why.** The coding agent holds all three legs, so
  auto-capture would make one injection come back every session; the memories chapter's own
  argument, run backwards. A strong lesson for "simple".
- **`GIT_REPO_RESEARCHER` / `git_clone`**: its lesson (cloned bytes land in a workspace the
  parent never reads) is real but secondary, since pikuri's book already teaches the
  trifecta-break via a sub-agent. Leaning sidebar.
- **Plan mode**: earns a place only as a security lesson, approving one plan instead of forty
  commands, and then the paragraph on why an approved plan doesn't constrain execution.
