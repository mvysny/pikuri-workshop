# Borrowable from prior art — the workshop's share

Split out of `pikuri:design/ideas/borrowable-from-prior-art.md`, which keeps the items about
pikuri's own gems; these are the ones about the shell, skills, permissions, MCP and memory.
`design/research.md` (and `pikuri:design/research.md` for the general harness survey) records
what the others do; this file records what might be worth doing about it. Sorted by fit, from
"worth it" to "out of scope". Graduate an item the moment it is acted on — into a `D_` entry, a
convention line, or nothing — and delete this file once the live items are gone.

## B-tier — worth it but more invasive

1. **Folder-trust gate before repo-supplied config** (grok-build, Claude Code).
   `Skill::Catalog::Bundled` scans `.pikuri/skills`, `.claude/skills` and `.agents/skills` under the
   project root, so a cloned repository's skill names and descriptions reach the system prompt with
   no trust decision. The `skill` tool already classifies a skill body as `untrusted: :hard`; the
   gap is a gate on the *source*, resolved once per workspace. grok-build's refinement worth
   copying: a "there were no repo configs" allow is never cached, so a skill that appears after a
   `git pull` is re-checked.
2. **Per-segment display of chained shell commands in the confirm prompt** (grok-build). Split the
   command on `&&`, `||`, `;`, `|` and newlines and show the human the segments; refuse to split —
   and say so — on subshells, `$(…)`, backticks, or control flow. Pure presentation, lands where
   presentation belongs (pikuri-workspace's `Confirmer::Terminal` renders it, `Bash`'s tokenizer
   does the split), and directly serves the anti-fatigue argument in `pikuri:book/security.md`.
   Neighbours the deferred work in `bash-confirmer.md`.

## C-tier — only when scope changes

3. **Permission system with glob rules** (opencode, grok-build). The coding agent ships pikuri's
   `Workspace` + `Confirmer` as v1; the three-action `allow` / `deny` / `ask` glob model is the
   right next step once friction shows up. Tracked in `coding-agent.md`. grok-build is the richer
   reference — evaluation by severity rather than by source, per-segment matching, and a curated
   read-only command allowlist whose *exclusions* are the part worth reading before writing any
   auto-approval logic (`R_permissions`).
4. **Deferred MCP tool loading via search** (grok-build's `search_tool` / `use_tool`). Same goal as
   `mcp_connect` with a different lever; scales better when one server exposes a hundred tools.
5. **Markdown-plus-SQLite memory substrate** (grok-build). Arguably the more pikuri-shaped answer on
   privacy and auditability grounds; not worth churning a shipped gem over, but the no-LLM-call
   automatic save and the confirm-before-write review panel are separable and cheap (`R_memory`).
6. **Pluggable Operations interfaces** (pi). Lets the `bash` tool delegate to SSH / sandbox / cloud.
   pikuri-core's `Subprocess.spawn` is the seam where this would hook in; today it only spawns
   local, and widening it is a change on pikuri's side.

## Out of scope

7. **In-process kernel sandbox** (grok-build's Landlock / Seatbelt applied at startup). Strictly
   stronger than bubblewrap-around-`Bash`, but pikuri's file tools run in-process as the real user
   *on purpose*, so `File.writable?` is exact and backs the confirm-writable-writes posture
   (`pikuri:pikuri-workspace/AGENTS.md`). Adopting it would mean giving that up — a real fork,
   decided the other way.
