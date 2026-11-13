# MCPs revisited: containerised servers

[The MCP chapter](mcp.md) wired one low-stakes MCP and pointed
forward; [the security chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/security.md) gave the framing; chapters
[8](code.md) and [9](security-revisited.md) applied the kit
to the coding-agent shape. This chapter picks the MCP thread
back up at the harder end of the spectrum — the cases where the
verifier alone isn't enough, where you can't read the server's
*code* the way you skimmed the book-catalogue reader in the MCP chapter,
where the server holds a credential whose blast radius bites,
and where the cleanest answer is *a container as the boundary
between pikuri and the server*.

The worked example here is the **official GitHub MCP server**,
running in Docker. Two community shapes (npx-based, pip-based)
follow, plus the largest untrusted-content surface in common use
(Playwright). The chapter closes with the full threat-model
section for `pikuri-mcp` — what wiring an MCP server in does and
doesn't protect, mapped against the kit from the security chapter.

## Prerequisites

The [first-conversation](https://codeberg.org/mvysny/pikuri/src/branch/master/book/chat.md), [sub-agents](https://codeberg.org/mvysny/pikuri/src/branch/master/book/subagents.md),
[MCP](mcp.md), [security](https://codeberg.org/mvysny/pikuri/src/branch/master/book/security.md) and
[coding-agent](code.md) chapters. `llama-server` running;
`bundle install` done. Plus:

- **Docker** — set up (rootless) back in
  [the prerequisites chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/prerequisites.md) and first used as an MCP
  boundary in [the MCP chapter](mcp.md) with the book-catalogue
  server. Same tool, different image: the official GitHub MCP
  server is distributed as `ghcr.io/github/github-mcp-server` (a
  ready-made image you *pull* rather than build from source —
  itself part of this chapter's point). If you skipped those, the
  one-time setup is in the prerequisites chapter. The stance the MCP chapter introduced
  gently and this
  chapter makes the rule: **every MCP server you don't write
  yourself runs in a container** — see the threat-model section
  for why.
- **A GitHub Personal Access Token (PAT)** — the genuinely new
  piece here, and the first credential you've handed an MCP
  server in this guide. Create one at
  <https://github.com/settings/tokens>. Use a **fine-grained**
  token scoped to the repositories you want the agent to see,
  with read-only access to issues, pull requests, and contents.
  Anything broader hands the agent permissions the chapter's
  isolation can't claw back. Put it in
  `~/.pikuri-examples-config.yaml` (`chmod 600`) as
  `github_token: github_pat_…`, **not** in your shell's
  environment: an exported token reaches every process pikuri
  starts, and [the environment wall](shell.md#the-environment-walled-too)
  stands only around sandboxed `bash`. A PAT is required even for read-only access to
  public repos: the server refuses to start without one (no
  anonymous code path, same as the `gh` CLI), and GitHub's
  unauthenticated REST limit of 60 requests/hour per IP would be
  exhausted in a couple of turns anyway — an authenticated PAT
  gets 5000/hour.

(If you don't have a PAT and just want to read the chapter
through, that's fine — the conceptual material doesn't depend on
having a live server.)

## 1. Wire the GitHub MCP into `pikuri-code`

`pikuri-code` already wires `Mcp::Extension` into its `Agent.new`
block — you saw that as a four-extension stack in the coding-agent chapter's
wiring example. It also has an empty hand-edit slot for the
registry near the top of `bin/pikuri-code`. Configuring an MCP
server is just filling that slot in; everything else is already
plumbed.

Open `pikuri-code/bin/pikuri-code` and find the
`mcp_registry = Pikuri::Mcp::Registry.new(entries: [...])` block.
By default it's empty. Add the GitHub entry:

```ruby
mcp_registry = Pikuri::Mcp::Registry.new(entries: [
  Pikuri::Mcp::Registry::StdioEntry.new(
    id:      'github',
    command: [
      'docker', 'run', '-i', '--rm',
      '-e', 'GITHUB_PERSONAL_ACCESS_TOKEN',
      'ghcr.io/github/github-mcp-server'
    ],
    env:     { 'GITHUB_PERSONAL_ACCESS_TOKEN' => examples_config.fetch('github_token') },
    private: true
  )
])
```

The token takes the narrowest path to the one process that needs
it. It is read from the config file, and `env:` hands it to this
one child alone: not to pikuri's own environment, not to your
language servers, not to the other MCP servers. `-e` passes the
variable by *name*, so docker copies the value from its own
environment, and the token never shows up in argv, where `ps` and
pikuri's INFO log line for each server would print it. (The
github-mcp-server reads its token only from its environment, so an
environment is where it has to end up; the point is that it ends up in
just this one.) `private: true` tells the trifecta report what
the PAT can read: private repos are private data.

`cd` into a repo you have access to and run it:

```sh
cd /path/to/some-repo
/path/to/pikuri/pikuri-code/bin/pikuri-code
```

On a cold cache, the same two passes from the MCP chapter fire:

1. **The verifier** against the GitHub server's handshake + tool
   list.
2. **The synthesizer** if the server didn't ship a useful
   `instructions` field (GitHub's does, so this step gets
   skipped here).

When both pass, the standard `pikuri-code` banner appears. Try a
question that exercises the new surface:

```
> List the three most recently updated open issues in <your-org/your-repo>.
```

The same `mcp_connect` → `list_issues` → reply dance you saw in
the MCP chapter plays out. What's new is the *stakes*: this server
holds a credential whose blast radius is the next section.

## Why Docker?

[`SECURITY.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/SECURITY.md) §"Code trust" and the security chapter's
code-trust section both settle the general posture in one bullet:
MCP server processes are untrusted code you didn't write, so run
them in a container. This chapter adopts that across the board.
Three MCP-specific consequences are worth being explicit about:

- **Image distribution shape varies.** The GitHub server above
  ships as a vendor image — easy. Most community MCPs are
  `npx -y …` (Node) or `pip install …` / `uvx …` (Python)
  packages with no official image, which means *you* build the
  container. The next two sections work through one example
  of each shape.
- **Pin the image.** `ghcr.io/.../foo:latest` is a registry tag
  an attacker who compromised the upstream can repoint. For
  anything load-bearing, pin to a known version (`foo:1.4.2`)
  and ideally a digest (`foo@sha256:…`). Pinning trades
  automatic security updates for reproducibility; for an MCP
  holding your GitHub PAT, reproducibility is the right side
  of that trade.
- **The token is the real blast radius.** Container isolation
  protects your laptop from the server's *code*. It doesn't
  protect your GitHub account from the server's *actions* —
  the token's permissions are the agent's permissions. Use a
  fine-grained PAT scoped to specific repos and operations
  (issues:read, contents:read), never a classic full-access
  token. Restated in the threat-model section below.

Bubblewrap ([the shell chapter](shell.md)) is `pikuri-code`'s inner-process isolation
for `bash`; Docker is the outer-process isolation this chapter
uses for MCP. Different tools, different problems — bubblewrap
is lightweight and bind-mount-based, Docker is heavier and
image-based. MCPs ship as images-with-deps, so image-based fits.

One caveat for a harness shape this chapter doesn't otherwise
assume: if you're running `pikuri-code` *itself* inside a
container, don't also wrap MCPs in nested containers —
Docker-in-Docker needs either the host docker socket bind-mounted
in or a `--privileged` outer container, and either gives the
agent root access to your host OS. In that shape, MCPs run
alongside pikuri inside the same container, not in nested ones.
[The security-revisited chapter's "Wrapping pikuri in Docker"](security-revisited.md#wrapping-pikuri-in-docker)
covers this end-to-end.

## Running an npx-based MCP

Most community MCPs ship as npm packages and assume you'll invoke
them with `npx`. [`mcp-maven-deps`](https://github.com/Bigsy/maven-mcp-server)
is a good worked example — small, useful (it queries Maven
Central for current versions of Java artifacts), and entirely
unofficial. Exactly the case where "untrusted, containerise it"
applies. The GitHub repo slug (`maven-mcp-server`) and the
published npm package name (`mcp-maven-deps`) differ — a common
trap. Always check what `package.json` actually declares as
`"name"` before typing it into a command.

A side benefit of the container-per-MCP posture is that you don't
need `node` installed on the host *for anything* — including the
"what version should I pin?" lookup. The same image you'll run
the server in answers that question:

```sh
docker run --rm node:20-slim npm view mcp-maven-deps version
# → 0.2.0
```

(Or `npm view mcp-maven-deps versions --json` for the full list.)
Substitute the result for `<pin-version>` below.

The naive recipe — wrap `npx` in a bare `node` container per
spawn:

```ruby
Pikuri::Mcp::Registry::StdioEntry.new(
  id:      'maven',
  command: [
    'docker', 'run', '-i', '--rm',
    'node:20-slim',
    'npx', '-y', 'mcp-maven-deps@<pin-version>'
  ]
)
```

This works, but the first boot pays a full `npm install`
(~15 seconds for a small server, longer for big ones). The bind
mount on `~/.npm` persists the cache so subsequent boots are
fast — at the cost of sharing your host npm cache with a
container running untrusted code. Not the worst thing (npm
caches are inert artifacts), not airtight either.

The cleaner recipe is to bake an image once:

```dockerfile
# Dockerfile-maven-mcp
FROM node:20-slim
RUN npm install -g mcp-maven-deps@<pin-version>
ENTRYPOINT ["mcp-maven-deps"]
```

```sh
docker build -f Dockerfile-maven-mcp -t maven-mcp:<pin-version> .
```

```ruby
Pikuri::Mcp::Registry::StdioEntry.new(
  id:      'maven',
  command: ['docker', 'run', '-i', '--rm', "maven-mcp:<pin-version>"]
)
```

Every spawn is now fast, the npm cache stays on the host, and
the package version is pinned in the Dockerfile — an upstream
compromise can't ship you a new version without you rebuilding.
The same pattern generalises to any npx-published MCP: replace
the package name and pin, rebuild to upgrade.

## Running a Python-based MCP

Python MCPs follow the same shape — `pip install <package>` or
`uvx <package>` plays the role of `npx -y <package>`.
[`mcp-server-fetch`](https://github.com/modelcontextprotocol/servers/tree/main/src/fetch)
is the canonical worked example: it's one of Anthropic's
reference servers, published on PyPI, and does roughly what
pikuri's built-in `fetch` tool does — only inside a container.

(Why containerise `fetch` when pikuri ships one? Defence in
depth: the bundled `fetch` parses HTML inside `pikuri-code`'s
own process, so a Nokogiri / Faraday parsing bug could in
principle land in the agent itself. The MCP version moves the
parser somewhere it can't reach your filesystem. Not strictly
necessary; an extra notch of isolation if you want it.)

Bake an image once:

```dockerfile
# Dockerfile-fetch-mcp
FROM python:3.12-slim
RUN pip install --no-cache-dir mcp-server-fetch==<pin-version>
ENTRYPOINT ["python", "-m", "mcp_server_fetch"]
```

```sh
docker build -f Dockerfile-fetch-mcp -t fetch-mcp:<pin-version> .
```

```ruby
Pikuri::Mcp::Registry::StdioEntry.new(
  id:      'fetch',
  command: ['docker', 'run', '-i', '--rm', "fetch-mcp:<pin-version>"]
)
```

Same trade-off as the npx case: pinned versions, fast spawns,
no host install state shared with the container.

For Python servers that need filesystem access (a SQLite DB,
a project directory), bind-mount a single host path into the
container with `-v`. Keep the mount narrow — `-v ~/projects/foo:/work:ro`
gives the server a read-only window onto one project, not your
home directory. The "narrow bind mount per concern" pattern is
the Python-MCP analogue of the fine-grained-PAT pattern for the
GitHub server: minimise the surface the server can act on.

## Browser MCPs are a special case

[Playwright MCP](https://github.com/microsoft/playwright-mcp) is
where the chapter's threat model bites hardest. It hands the
agent a real browser pointed at URLs the agent picks — every
page loaded is an opportunity for attacker-chosen JavaScript to
land in the browser process. Every other MCP in this chapter
sees only text the model fed it; Playwright sees the open web.
It's the MCP with the largest untrusted-content surface in
common use, which is exactly why you most want it containerised.

The good news: Microsoft publishes `mcr.microsoft.com/playwright`
with the browsers pre-installed, so the "bake an image" step is
already done. The complication: Playwright is useful precisely
when the agent needs to *do something* visible — visit your local
dev server, take screenshots you review, drive a UI on
`localhost:3000`. Three usability questions stack on top of the
isolation question. (Everything below is Linux-specific; macOS
needs XQuartz for headed mode and Docker Desktop handles
`host.docker.internal` automatically; Windows is unsupported.)

### Headed vs. headless

Playwright supports both. Headless is the safer default — no UI,
no X11 socket exposure, the browser renders to memory and
exposes snapshots through the MCP protocol. The chapter
recommends headless for routine work.

Headed mode is genuinely useful when you want to *watch* what
the agent is doing: clicks land on visible buttons; you can
intervene. To do that from a container, bind-mount the host X11
socket:

```ruby
Pikuri::Mcp::Registry::StdioEntry.new(
  id:      'playwright',
  command: [
    'docker', 'run', '-i', '--rm',
    '-e', "DISPLAY=#{ENV.fetch('DISPLAY')}",
    '-v', '/tmp/.X11-unix:/tmp/.X11-unix',
    'mcr.microsoft.com/playwright:<pin-version>',
    'npx', '-y', '@playwright/mcp@<pin-version>', '--no-headless'
  ]
)
```

Bind-mounting `/tmp/.X11-unix` is a meaningful loosening of
isolation — anything that can talk to that socket can drive your
desktop. That's the price of headed mode; only turn it on when
you actively want to watch the browser, not as a default.

### Reaching your local dev server

If you want the browser to visit `localhost:3000`, the
container's `localhost` isn't your host's `localhost` — and with
[the prerequisites chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/prerequisites.md)'s rootless Docker, your host's
`127.0.0.1` is flatly unreachable from containers. That's the
same deliberate seal [the memories chapter](memories.md) met, and here
it's working *for* you: this is the chapter's
largest-untrusted-content surface, and attacker-chosen JavaScript
probing `127.0.0.1` for your loopback services is a classic move.
The advice you'll find online — `--network host`, or
`--add-host host.docker.internal:host-gateway` — quietly assumes
a root daemon; under rootless both dead-end inside the daemon's
own network namespace, nowhere near your host. (And don't reach
for `DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=false` —
the memories chapter explains how that daemon-wide knob un-builds this
chapter's whole boundary.)

What works — on rootless and rootful alike — is giving the dev
server an address the container can route to, scoped as tightly
as you like:

- **A host-only dummy interface** (tightest): an address that
  exists only on your host — containers can reach it, your LAN
  never sees it.

  ```sh
  sudo ip link add devsrv0 type dummy
  sudo ip addr add 192.168.255.1/32 dev devsrv0
  sudo ip link set devsrv0 up
  ```

  Bind the dev server to it (`--host 192.168.255.1`, or your
  framework's equivalent) and have the browser navigate to
  `http://192.168.255.1:3000`. The interface vanishes on reboot;
  persist it with a small systemd-networkd or netplan snippet
  once the setup sticks. Pick another subnet if your LAN already
  uses `192.168.255.x`.
- **Your LAN IP** (simplest): bind the dev server to it and
  navigate there. The cost is that the dev server is now on your
  network — fine on a trusted home LAN behind a router, worth a
  thought anywhere else.

(The memories chapter solved the same container-to-host problem with a
supervised socat relay over a unix socket — the engineered
version of this. Here the container is a hand-wired registry
entry and the Playwright image carries no relay half, so the
interface trick is the lighter lift.)

Bubblewrap doesn't enter into this — it sandboxes filesystem
access for `bash`, not network. A dev server `bash` started
listens on whatever address it binds; whether the Playwright
container can reach it is decided by the routing above. The two
sandboxes are independent; they don't fight.

### Seeing the screenshots

Playwright's MCP returns screenshots inline as image content in
the tool response, which the *agent* can see but `pikuri-code`'s
terminal renderer can't display. To view them yourself, configure
the server to write artifacts to a host-mounted directory:

```
'-v', "#{ENV['HOME']}/.cache/pikuri/playwright:/artifacts",
```

…then pass the server's output-directory flag pointing at
`/artifacts`. Screenshots land on your host at
`~/.cache/pikuri/playwright/`, viewable in any image viewer.

Putting all three pieces together gives a reasonable headed,
host-network, screenshot-readable Playwright invocation — but
each `-v` and `--network` flag is a notch of isolation traded
away. Default headless with no host network; turn knobs on only
when you need them, and turn them off again when you're done.

## A note on apt-shipped MCPs

The whole chapter assumes MCP servers are untrusted because
that's what `npx -y <package>` and `pip install <pkg>` *are* —
unreviewed code from a public registry. A different distribution
shape would change the calculus: a server packaged in Debian's
or Ubuntu's archives has been through maintainer review, is
built reproducibly from a pinned upstream, and signed by the
distribution. That's a real code-trust signal, the same one
that justifies `apt install ripgrep` without further
sandboxing.

As of 2026, no popular MCP server ships this way. The ecosystem
is ~18 months old; Debian's release cadence is slower than that.
So this section is forward-looking: *if* an MCP you want lands
in `apt`, the Docker wrapper becomes optional — `apt install` is
the code-trust story, and you can spawn the server directly.

Two caveats even then. First, apt-trust only addresses the
code-trust axis. The server can still ship prompt injection in
its tool descriptions or be tricked by attacker-controlled
inputs at runtime; the verifier still runs and is still useful.
Second, you still want to scope any tokens the server uses the
same way you would for the GitHub container — the action blast
radius is independent of code trust.

Until then, the realistic shapes are vendor-image (the GitHub
example), npx-Dockerised, Python-Dockerised, and Playwright.
The chapter covers all four.

## Threat model — what `pikuri-mcp` actually protects against

This page's view, in the same spirit as the security-revisited chapter's threat-model
section for the coding agent — what wiring an MCP server in does
and doesn't cover. The security chapter is the synthesis behind it (the
trifecta, the kit, the worked attacks); this section maps that
synthesis onto the MCP-specific surface.

What the default configuration *does* protect:

- **Pre-flight injection detection.** The verifier (the MCP chapter)
  runs before any tool from the server is callable: hidden
  Unicode payloads are rejected mechanically, LLM-judged
  injection attempts are rejected with reasoning, and the server
  never enters `live_ids`. A flagged server is one you see and
  investigate, not one you discover after the fact.
- **No tools in context until you ask.** `mcp_connect` gates the
  schema surface — tools that slipped the verifier still aren't
  in context unless the model explicitly activates them.
- **Per-agent activation.** Sub-agents can't reach the MCP
  surface at all: the privilege separation from the sub-agents chapter
  carries through, so a `FILE_MINER` reading a malicious file
  can't `mcp_connect` to anything.
- **Container isolation (when you wrap in Docker).** A malicious
  server can't read your `~/.ssh` or write to your home
  directory.

What it *doesn't* protect:

- **Execution of the server itself.** The verifier reads text,
  not executable code. A server that emits *clean* descriptions
  but does something hostile when its tools run still activates
  if the LLM calls `mcp_connect`. The container is your real
  defence here, not the verifier.
- **The LLM judge is an LLM.** The verifier's second pass uses
  the same model class your agent talks to; a crafted injection
  might fool it the same way it fools the agent. The Unicode
  pre-pass is deterministic and catches one whole class
  outright; the LLM pass is best-effort and catches *most* of
  the rest, not all.
- **Token blast radius.** A GitHub MCP given a classic
  full-access PAT can do anything that token can — open issues,
  comment, push to repos with `contents:write`. Scope the PAT
  tightly; treat it as the real boundary on what the agent can
  do on GitHub.
- **HTTP MCP servers and TLS.** `HttpEntry` accepts any URL.
  Wire in an `http://` endpoint instead of `https://` and you're
  trusting the network path; the gem doesn't refuse plain HTTP —
  that's your call.
- **Cached "OK" results.** A server whose surface hasn't changed
  doesn't re-run the verifier. The cache key is the full surface
  fingerprint, so any change re-triggers verification; to clear
  a long-running cache, delete
  `~/.cache/pikuri/mcp_verifications/`.
- **Poisoned tool *responses* at runtime.** This is the structural
  gap the security chapter named: the verifier checks the server's surface
  at registration, but tool *outputs* during a conversation flow
  into the parent's context unchecked. MCP tools mount on the
  parent agent, so there's no sub-agent boundary between the
  model and a poisoned response. The security chapter's attack 4 walks this
  through end-to-end.

In short: **assume MCP servers can take any action their token
allows, scope the token accordingly, and wrap the server in a
container.** The verifier is a useful belt, not the whole
belt-and-suspenders story — and a server clean at handshake can
still ship a poisoned response on a later call.

## What's next

[Language intelligence](lsp.md) closes the code track by giving the
agent the one thing grep cannot supply: a parser with a project-wide
index, borrowed from the language server your editor already runs. It is
also the sharpest study in the book of a foreign process answering an
agent's question with a well-formed lie — and of keeping "I cannot
answer" from rendering as "there is nothing there".

The vocabulary you have now (`Pikuri::Agent`, `Tool`, listeners,
the Extension protocol with its worked examples, configure/bind,
sub-agent privilege separation, MCP's verifier + synthesizer +
per-agent `mcp_connect`, Docker as the MCP boundary) is enough
to read the [`pikuri-mcp`](../pikuri-mcp/README.md) sources
directly.
