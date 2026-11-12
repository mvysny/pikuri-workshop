# A Claude Code backend for the researcher

Status: **brainstorm.** Nothing built. Raised 2026-10-04.

The `researcher` persona (`pikuri-subagents/lib/pikuri/sub_agent/researcher.rb`)
runs on pikuri's own loop with `web_search` / `web_scrape` / `fetch` over
whatever model the parent uses. The idea: a second backend that runs the
unmodified `claude` binary (`claude -p`, WebSearch + WebFetch only) inside a
Docker container, so a research task gets a Claude model, Anthropic's search, and
Claude Code's fetch path — **billed to the user's own Claude subscription**,
not an API key. The subscription is the point: an API key on the same volume
is far more expensive.

## Why the shape fits

- **The researcher is already a black box.** Contract: task text in, one
  paragraph + bare URLs out (`prompts/persona-researcher.txt`). `claude -p`
  with `--output-format json` is that contract; no turn loop needs mirroring.
- **Not `pikuri:R_subscription_transport`.** hermes-agent drives `claude` as a raw
  *model transport* and needs a loopback admission relay plus full-history
  replay to fight the CLI. Here `claude` is used *as an agent*: one prompt,
  one answer. None of that machinery.
- **Docker = no private-data leg by construction.** No host mount, so the
  child holds untrusted (web) + egress (WebFetch is `:attacker_reachable`),
  the same two legs the current researcher holds. `pikuri-extractors`
  already runs a one-shot container (networkless; this one is the inverse).
- **Spawned via `Pikuri::Subprocess.spawn`**, so it dies with the turn.

## Where it rubs against the promises

- **Privacy first** — "a feature that only works against a hosted one breaks
  the posture even when nobody turns it on." This backend is exactly that.
  hermes hit the same wall and moved the vendor transport out of tree.
  → ship outside `pikuri-subagents`: a separate gem or a downstream demo.
- **More bytes leave.** Today only search queries and chosen URLs leave.
  Here the whole task text (a `pikuri-code` parent folds stack traces, paths
  and snippets into it) plus every scraped page go to Anthropic. The opt-in
  must say that in concrete words.
- **Readable in an evening** — a moving third-party binary at the center.
  `-p --output-format json` is a far more stable surface than hermes'
  replay, but still "a version, not an API".
- **Not a `Persona` as personas stand.** A persona is a pikuri loop +
  `tool_names` + a prompt (`persona.rb`); the Claude child has none of
  those. It is a tool instead — see *Decided*.

## Billing and terms — researched 2026-10-04

- **Running `claude -p` on your own subscription is sanctioned.** The
  Claude Code legal page: OAuth is "designed to support ordinary use of
  Claude Code"; the ban is on *third-party developers* routing requests
  through Free/Pro/Max credentials or offering Claude.ai login in their
  own apps. It explicitly does **not** prevent "an end user from signing in
  to the unmodified Claude Code binary with their own Claude subscription,
  including where a platform hosts Claude Code". Advertised limits "assume
  ordinary, individual usage of Claude Code and the Agent SDK".
  <https://code.claude.com/docs/en/legal-and-compliance>
- **Headless auth is first-class.** `claude setup-token` mints a one-year
  subscription OAuth token, passed as `CLAUDE_CODE_OAUTH_TOKEN`, documented
  "for CI pipelines and scripts where browser login isn't available".
  `--bare` mode does not read it. An `ANTHROPIC_API_KEY` in the env outranks
  it and `-p` always uses a present key, so the container must not inherit
  one. <https://code.claude.com/docs/en/authentication>
  - **Verified 2026-10-04 on 2.1.289:** a token from `claude setup-token`,
    run with nothing else to log in with
    (`env -u ANTHROPIC_API_KEY HOME=<empty dir> CLAUDE_CODE_OAUTH_TOKEN=…
    claude -p … --model sonnet --output-format stream-json --verbose`,
    cwd outside any project), answered with `init` reporting
    `apiKeySource: "none"` (subscription) and
    `model: "claude-sonnet-5-5"`.
  - **The container mirrors that run:** an empty `HOME` (no host
    `~/.claude` credentials or settings), a cwd with no project (on the
    host, `-p` loaded pikuri's `CLAUDE.md` from cwd), and the token passed
    as the only `-e`; `docker run` passes no host env by default, so
    `ANTHROPIC_API_KEY` cannot leak in.
  - The same run *without* the lockdown flags listed `Bash`, `Write`,
    `Edit`, `Task`, `Workflow` and more in `init.tools`: a bare `claude -p`
    hands the model everything it needs to read the token and send it out.
- **What would break the terms:** pikuri reading the CLI's
  `.credentials.json` or the token and calling the Messages API itself.
  The binary must stay the client.
- **Quota:** `-p` and the Agent SDK draw from the same 5-hour + weekly
  subscription limits as interactive use. A separate monthly "Agent SDK
  credit" for `-p` / SDK / third-party apps was announced 2026-05-26 for
  2026-06-15 and paused that day; Anthropic says a replacement is coming
  and will be announced first. <https://support.claude.com/en/articles/15036540>
- **"Counts more heavily"** — the only evidence is hermes' own measurement
  (plugin README, Pro plan, Sonnet 5 1M, 2026-09-09, 2 windows `-p`, 2
  interactive, meter readings): ~8.9 session points per list-price dollar
  for `-p` vs ~5.4 / 4.9 interactive. Same tokens, ~1.7× the quota per
  token, i.e. ~60% of the TUI's throughput per window. Not confirmed by
  Anthropic, n=2, one model. It is a *rate* difference, not more tokens.
  <https://github.com/NousResearch/hermes-plugin-claude-subscription-directsdk>

## Claude web tools vs the researcher's — researched 2026-10-04

| researcher | Claude Code (`claude -p`) | claude.ai chat |
|---|---|---|
| `web_search` | `WebSearch` — Anthropic's server-side search, titles + URLs only | "Web search" — same backend |
| `web_scrape` | `WebFetch` — fetched **locally** (in the container), HTML→Markdown, then a small model answers a prompt about the page; Claude sees that answer, not the page. Lossy by design; quotes capped | "Web fetch" — "the full content" of the page into context |
| `fetch` (PDF, JSON) | `WebFetch`; only HTML conversion is documented | API `web_fetch` server tool extracts PDF text; claude.ai not documented |

- Sources: <https://code.claude.com/docs/en/tools-reference> (WebFetch /
  WebSearch behavior), <https://support.claude.com/en/articles/10684626-enable-and-use-web-search>,
  <https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-fetch-tool>.
  Where claude.ai's fetch runs is not documented; the API tool runs on
  Anthropic's side and only fetches URLs the user gave or a search / fetch
  returned.
- Claude Code's WebFetch also asks `api.anthropic.com` whether each domain
  is blocklisted before fetching, and sends `User-Agent: Claude-User…`.
  Bot fences that block `web_scrape` likely block some of these too.
- **Raw pages (was `Q_raw_page`), decided:** the docs' own answer is
  `curl` via Bash, but Bash can read `CLAUDE_CODE_OAUTH_TOKEN` (env,
  `/proc/*/environ`) and send it out — an injected page could steal the
  subscription. The two-tool lockdown keeps the token out of the model's
  reach, so Bash stays out.
  - **v1: accept WebFetch's lossiness.** The reply is one paragraph
    anyway.
  - **v2: our own MCP server inside the container**, written by us on the
    `mcp` gem's server side (`pikuri-mcp` already depends on it as a
    client), exposing raw-page and PDF tools that reuse pikuri's
    `web_scrape` / `fetch` internals and the `Extractor` registry
    (`pikuri-pdf` for PDFs). Wired with `--mcp-config` +
    `--strict-mcp-config`, and `--disallowedTools "mcp__*"` loosened to
    that one server. Its tools return page text only — nothing reads env,
    so the token stays out of reach even if `claude` hands the server
    its own environment (unverified; an `env` block in the MCP config may
    be able to strip it). Costs: Ruby + the pikuri gems in the
    image, and a first MCP *server* in the repo. Legs unchanged
    (untrusted + `:attacker_reachable` egress).

## Decided

- **Where it lives (was `Q_where_it_lives`):** a separate gem. Out of
  `pikuri-subagents` keeps the privacy promise: a host that never adds the
  gem has no hosted-only code.
- **Shape (was `Q_shape`): a plain `Pikuri::Tool`**, shipped by the gem's
  own `Extension`. pikuri's "subagent" means a pikuri loop with a narrower
  toolset; this has no loop pikuri owns — it is a tool that runs an
  external program, like `lsp` or the extractors container.
  - Zero change to any existing gem — the "grow by adding tools" path.
  - Legs declared on the tool like every other tool (precedent:
    `D_lsp_trifecta_legs`, a tool whose child goes online): untrusted +
    `:attacker_reachable` / `:unreviewed` egress (WebFetch reaches
    model-chosen hosts), no private data.
  - Cancellation via `wants_context: true` + `Subprocess.spawn`; the
    container must die on Ctrl+C (`docker run --rm --init`, killed with
    the process group). Answers a `Tool::Result` with display lines.
  - Wired to the main agent directly, or listed in a persona's
    `tool_names`. The parent may then see two ways to research (`agent` →
    researcher, and this tool); the host wires one or the other.
  - Rejected: **a loop-less persona behind the `agent` tool** — needs a
    dispatch seam in `pikuri-subagents` (`sub_agent_tool.rb` always builds a
    `Pikuri::Agent`) plus a second way to declare legs (`Extension#trifecta_contribution`
    reads `tool_names`), and everything a child inherits (transport,
    listeners, temp workspace, `for_sub_agent`) is dead weight. A seam for
    one hosted-only backend in an in-tree gem; revisit only when a *second*
    loop-less backend (Codex CLI, Gemini CLI) shows up. **A transport**
    (`claude` as the model behind the researcher's loop) is
    `pikuri:R_subscription_transport`, rejected there.
- **Name (was `Q_tool_name`): `claude_researcher`.** Names the vendor
  (the opt-in is visible in the tool list) and the job; a family prefix is
  not implied — there is one tool.
- **Model: always `--model <m>`**, so which model runs
  never depends on the plan's default (Opus 5.5 on Pro and Max today). `m`
  is an optional extension parameter, default `sonnet`, passed to `claude`
  verbatim; a bad value surfaces as `claude`'s own error in
  `Tool::Result.error`. Sonnet as the default because Opus burns the shared
  subscription quota faster.
  - `sonnet` is an alias, not a pinned id: it resolves to "the recommended
    version for your provider" (Anthropic: Sonnet 5.5 — on 2.1.289,
    `init` reported `claude-sonnet-5-5`, 2026-10-04), and the
    mapping is built into the Claude Code version. With the v1 version pin
    it moves only when the gem bumps the pin. A full id
    (`claude-sonnet-5-5`) pins the model as well.
    <https://code.claude.com/docs/en/model-config>
- **Image provenance (was `Q_image_provenance`):** opting in to this gem
  *is* the user's permission to build the Docker image and install
  `@anthropic-ai/claude-code` from npm inside it. The opt-in docs say so in
  those words; nothing is built until the user wires the gem.
- **v1 pins the Claude Code version.** The gem names one exact
  `@anthropic-ai/claude-code` version (2.1.289 today, the one the lockdown
  was verified on). The Dockerfile installs it as a build argument, and the
  image tag carries the version, so a bump means a new tag and pikuri
  rebuilds when that tag is missing. No stamp, no updater.
  `DISABLE_AUTOUPDATER=1` in the container: in a `--rm` container
  Claude Code's own updater would only download into a throwaway layer.
  - Why: the lockdown is verified per version. A pin means the version
    that runs is one somebody verified, and a bad npm release never lands
    unattended.
  - Bumping is a release chore: re-run the *Tool lockdown* check below on
    the new version, then bump the pin.
  - Cost: the CLI falls behind between bumps, and so does the `sonnet`
    alias. Whether Anthropic ever turns away old CLI versions is not
    known; if a pinned version stops working, the error surfaces as
    `claude`'s own, in `Tool::Result.error`.
- **Scraping quality (was `Q_measure_scraping`): no measurement.** Trust
  WebFetch on the strength of Claude Code's and claude.ai's research in
  practice. The caveat: that quality is mostly search + model, and the
  agent quietly routes around a failed fetch (in the session that wrote
  this file, 1 of ~8 WebFetch calls came back as a site's newsletter
  shell). Fences that block `web_scrape` will block some WebFetch calls
  too; for a one-paragraph answer that is fine. Watch for it in use.

## Deferred to v2

- **Quota contention (was `Q_quota_contention`):** the researcher and the
  user's own interactive Claude Code share one 5-hour window, at the worse
  `-p` rate. Show remaining quota? Fall back to the local researcher when
  exhausted? v1 just surfaces `claude`'s own limit error as the tool's
  `Tool::Result.error`.
- **Daily updates instead of the pin.** A daily npm update is only safe if
  every run re-checks the lockdown, because an update that changes what
  `--tools` means could hand the model Bash, and Bash can read
  `CLAUDE_CODE_OAUTH_TOKEN`. The two come together:
  - *Per-run lockdown check:* `--output-format stream-json`; before
    trusting the result, require the `init` event's
    `tools == ["WebFetch","WebSearch"]` and `mcp_servers == []`, otherwise
    kill the container and answer a loud `Tool::Result.error` naming what
    showed up.
  - *Updater:* the image holds only Node; the CLI lives in a named volume
    (npm prefix), mounted `:ro` for research runs. When a call finds the
    stamp under `Paths.cache` older than one day (hard-coded, no knob), it
    first runs `npm install -g @anthropic-ai/claude-code@latest` into the
    volume through `Subprocess.spawn`, with a display line. A missing
    binary means install whatever the stamp says. A `flock` on the stamp
    serializes parallel calls and processes (`P_shared_locked`). A failed
    update logs a warning, keeps the old binary and leaves the stamp
    stale, so the next call retries.
  - The opt-in docs then add "and re-downloads Claude Code from npm once a
    day".

## Tool lockdown — verified 2026-10-04 on Claude Code 2.1.289

```
claude -p --tools "WebSearch,WebFetch" --disallowedTools "mcp__*" \
  --strict-mcp-config --setting-sources "" --disable-slash-commands \
  --no-session-persistence --permission-mode dontAsk \
  --allowedTools WebSearch WebFetch --output-format json "<task>"
```

The `stream-json` `init` event reported `tools: ["WebFetch","WebSearch"]`,
no MCP servers, no skills, no slash commands, `apiKeySource: none`
(subscription). Why each flag:

- `--tools` is the one that *removes* built-ins from the model's context;
  `--allowedTools` only pre-approves, it restricts nothing. `--tools` does
  not touch MCP tools, hence `--disallowedTools "mcp__*"` +
  `--strict-mcp-config`.
- `--permission-mode dontAsk` + `--allowedTools` for the two: nobody can
  answer a prompt in a container.
- `--setting-sources ""` ignores user/project/local settings (hooks,
  permissions, MCP); harmless belt-and-braces in an empty container.
- `--model <m>` (see *Decided*) is added to this; it was not part of the
  verified run.
- Not `--bare`: it ignores `CLAUDE_CODE_OAUTH_TOKEN`, so no subscription.
- Subagent *types* still show in `init.agents`, but without the `Agent`
  tool they cannot be spawned. Built-in plugins (telemetry etc.) still
  load; `--restricted` was not needed.
- WebFetch returns a small model's answer about the page, not the raw
  page — the researcher never sees full page text, which suits the
  one-paragraph contract.
