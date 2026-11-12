# pikuri-code — AGENTS.md

The coding-agent gem: the `bash` tool, its sandbox arms, the `GIT_REPO_RESEARCHER`
persona, and `bin/pikuri-code`, the in-repo agent that wires the file stack, tasks, plan mode, MCP
and LSP together. Owns the sandbox seam; the tool contract and the loop are `pikuri-core`'s, the
file and confirmation seams `pikuri-workspace`'s.

## Invariants

- **Sandbox seam.** `Code::Bash` takes a `Code::Bash::Sandbox` (default `NONE`) and wraps every argv via `#wrap`; it governs the bash subprocess's fs view, where Workspace governs what the LLM observes. `FullFsNoNet` raises rather than degrading, and masks the live session's IPC sockets *after* the root bind (`D_headless_os_agent`). See {Pikuri::Code::Bash::Sandbox}.
- **Consumed seams.** `Bash` takes the bare `Workspace::Filesystem` (**Workspace seam**) and a `Workspace::Confirmer` (**Confirmer seam**), both owned by `../pikuri-workspace/AGENTS.md`; only Bash is sandboxed. Its child is spawned over `Pikuri::BundlerEnv.clean_delta` per the root's **Environment is not a secret store** seam. See {Pikuri::Code::Bash}.

Maintenance: the root `AGENTS.md`'s rules; cap 10 KB.
