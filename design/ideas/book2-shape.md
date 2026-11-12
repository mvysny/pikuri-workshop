# Book 2's shape: ending on a simple coding agent

Status: **draft running order, nothing rewritten yet.** Carried over from pikuri's
`pikuri-workshop.md` idea, which deferred it until this repo existed. The chapters moved here
as they were, so `book/README.md` lists them in a provisional order and their "What's next"
links still follow pikuri's old order.

`Q_book2_shape`: book 2 ends on **a simple coding agent** (`pikuri-code`), the way pikuri's
book ends on a plain CLI personal assistant (`bin/pikuri-secretary`). The two climaxes pair
up: pikuri's is broken by construction; the workshop's is the agent people actually run, which
can't be, because it holds all three legs at full strength. So its chapter is about what each
defense (the sandbox, the confirmer, the passive-command detector) buys and where it stops,
which absorbs most of `security-revisited.md`.

Draft running order:

- the shell and its cage (harvests `code.md`'s sandbox half and `os-assistant.md` Part 1);
- the OS assistant (the opposite cut: `FullFsNoNet`);
- memories (mem0: automatic capture on the no-egress agents that can afford it);
- skills;
- the wire chapter;
- your first MCP server;
- MCPs revisited;
- language intelligence;
- the coding agent, as the climax.

"Simple" means checking whether plan mode, `git_clone` and `GIT_REPO_RESEARCHER` each earn a
place in it. `tasks.md` has no slot yet: a task list earns its keep on long multi-step work,
mostly coding, so it may fold into the climax.

The promise "power runs in a VM" asks the shell chapter to open on a VM, not Bubblewrap; today
the code doesn't have one (see `SECURITY.md`).
