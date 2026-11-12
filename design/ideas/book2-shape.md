# Book 2's shape: ending on a simple coding agent

Status: **running order agreed, nothing rewritten yet.** Carried over from pikuri's
`pikuri-workshop.md` idea, which deferred it until this repo existed. The chapters moved here
as they were, so `book/README.md` lists them in a provisional order and their "What's next"
links still follow pikuri's old order.

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
2. **The OS assistant**: the same seams, the opposite cut (`FullFsNoNet`); the one agent that
   never lifts its cage, because its whole point is your host.
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
