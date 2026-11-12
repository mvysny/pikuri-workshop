# Security open questions: the shell and MCP

Status: **open-questions log**, split from pikuri's `design/ideas/security-open-questions.md`
when the shell and MCP moved here. The committed model is [`SECURITY.md`](../../SECURITY.md).
Promote an entry into its own idea file, or a fix, when the friction shows up.

## Unsandboxed Bash modes

`Code::Bash::Sandbox::Bubblewrap` constrains `Bash` to the workspace's
readable/writable roots + an OS-runtime baseline, and is the default in
`bin/pikuri-code`. The residual concern is `--no-sandbox` / `--yolo`:
there `cat ~/.ssh/id_rsa`, `env | grep -i key`,
`curl --upload-file ~/.aws/credentials ...` all run as the user, and
the per-command Confirmer is the only line of defense (`--yolo`
disables that too). The help text says "use only with an outer
sandbox" but nothing enforces it. Worth considering: detect a
container / VM at boot and refuse `--no-sandbox` outside one, or at
least surface a louder warning than the current `LOGGER.warn`.

## MCP — open ergonomic / supply-chain questions

The committed MCP story is split across [`../SECURITY.md`](../../SECURITY.md):
the §"Code trust" bullet covers the Docker-for-untrusted-process
recommendation (suggested, not automatic); §"Defense: MCP
description verification" covers the `Mcp::Verifier` pre-flight
scan, with user-curation as the first line of defense. Open:

- **Per-tool first-use consent** (opencode-style sticky approval)
  is probably the right ergonomics shape — first invocation of
  the Gmail-MCP fetch tool is also the first consent prompt.
  Composes with the skill-gated lazy-add design.
- **First-class "wrap MCP in Docker" option** would close the
  supply-chain gap without leaving containerization to the user.
  Hard part: the wrapped MCP's egress / LLM-endpoint reachability
  re-opens the trifecta inside the container, so the egress
  policy of the inner Docker becomes the new question.

