# MCPs revisited: containerised servers

[Your first MCP server](mcp.md) ran one server you could read, with nothing of yours wired in,
and left two questions open: what about a server you *can't* read, and what about one that
holds a credential? This chapter takes both, at the harder end of the spectrum. The verifier
alone isn't enough there, a token's reach bites, and the cleanest answer is a container as the
boundary between pikuri and the server, narrowed further than the MCP chapter dared.

The worked example is the **official GitHub MCP server**, an image you pull rather than build,
wired into `pikuri-code` and holding your token. This time the box's network gets narrowed to
the one host the server needs. Two community shapes follow (an npm package and a PyPI one),
then the largest untrusted-content surface in common use, a browser. The chapter closes on the
threat model for `pikuri-mcp`: what wiring an MCP server in does and doesn't protect.

## Prerequisites

pikuri's [first-conversation](https://github.com/mvysny/pikuri/blob/master/book/chat.md),
[sub-agents](https://github.com/mvysny/pikuri/blob/master/book/subagents.md) and
[security](https://github.com/mvysny/pikuri/blob/master/book/security.md) chapters, and
this book's [shell](shell.md) and [MCP](mcp.md) chapters. `llama-server` running; `bundle
install` done. Plus:

- **Podman**, or rootless Docker, as set up in
  [the MCP chapter](mcp.md#podman-or-rootless-docker). Every command here is podman; docker
  takes the same arguments, but this chapter was run on podman 5.7 only. Image names are fully
  qualified (`docker.io/library/node:26-slim`, not `node:26-slim`): podman resolves a short name
  through a list of registries, and the first one that answers wins. The rule the MCP chapter
  introduced gently, this chapter makes firm: **every MCP server you didn't write runs in a
  container**.
- **A GitHub Personal Access Token (PAT)**, the first credential you've handed an MCP server in
  this book. Create a **fine-grained** one at
  <https://github.com/settings/personal-access-tokens/new>: a short expiry, and either
  "Public repositories" (read-only, no permissions to pick) or only the repositories you want the
  agent to see, with *Contents*, *Issues* and *Pull requests* set to read-only. A fine-grained
  token starts with `github_pat_`; a `ghp_` one is the classic kind, with scopes far broader
  than this needs. Put it in `~/.pikuri-examples-config.yaml` (`chmod 600`) as
  `github_token: github_pat_…`, **not** in your shell's environment: an exported token reaches
  every process pikuri starts, and [the environment wall](shell.md#the-environment-walled-too)
  stands only around sandboxed `bash`. The server refuses to start without a token, even for
  public repositories, and GitHub's anonymous limit of 60 requests an hour would run out in a
  couple of turns anyway.

(Without a PAT you can still read the chapter through: the ideas don't depend on a live
server.)

## Wire the GitHub MCP into `pikuri-code`

`pikuri-code` already wires `Mcp::Extension` into its agent, with an empty registry near the
middle of `bin/pikuri-code`. Configuring a server is filling that registry in. The commented
examples above it hold the entry this chapter builds; the bare version first:

```ruby
mcp_registry = Pikuri::Mcp::Registry.new(entries: [
  Pikuri::Mcp::Registry::StdioEntry.new(
    id:      'github',
    command: ['podman', 'run', '-i', '--rm',
              '--cap-drop=all', '--security-opt=no-new-privileges', '--read-only', '--tmpfs', '/tmp',
              '-e', 'GITHUB_PERSONAL_ACCESS_TOKEN',
              'ghcr.io/github/github-mcp-server:v2.1.0', 'stdio', '--read-only'],
    env:     { 'GITHUB_PERSONAL_ACCESS_TOKEN' => examples_config.fetch('github_token') },
    private: true
  )
])
```

The token takes the narrowest path to the one process that needs it. It is read from the config
file, and `env:` hands it to this one child alone: not to pikuri's own environment, not to your
language servers, not to the other MCP servers. `-e` passes the variable by *name*, so podman
copies the value from its own environment, and the token never shows up in argv, where `ps` and
pikuri's INFO log line for each server would print it. (The server reads its token only from its
environment, so an environment is where it has to end up; the point is that it ends up in just
this one.) `private: true` tells the trifecta report what the PAT can read: private repositories
are private data.

The flags before the image are the three cheap ones from
[the MCP chapter](mcp.md#what-the-box-can-reach), plus a writable `/tmp` in memory. The two
words after it are the server's own: `stdio` is how it talks, and `--read-only` (the *server's*
flag, not podman's) drops every tool that writes. Of its 46 tools, 27 remain, all reads: no
`merge_pull_request`, no `push_files`, nothing in the model's context that a read-only token
would refuse anyway.

`cd` into a repository and run it:

```sh
cd /path/to/some-repo
/path/to/pikuri-workshop/pikuri-code/bin/pikuri-code
```

On a cold cache, the verifier from the MCP chapter reads the server's handshake and tool list
first; on the test box that took about a minute against a local model. The synthesizer stays
idle, because GitHub's server ships its own `instructions`. Then the usual banner, and a
question that exercises the new surface:

```
> List the two most recently updated open issues in github/github-mcp-server: number and title only.
→ McpConnect(github)
= Connected, 27 tools
→ Github::ListIssues(repo=github-mcp-server owner=github state=OPEN fields=nu…)
= Returned 390 bytes
```

The same `mcp_connect` → tool → reply dance as the MCP chapter. What's new is the stakes: this
server holds a credential, and the rest of the chapter is about what it can do with it.

## Why a container?

[pikuri's `SECURITY.md`](https://github.com/mvysny/pikuri/blob/master/SECURITY.md)
§"Code trust" settles the general posture in one bullet: an MCP server is untrusted code you
didn't write, so it runs in a container. Three consequences specific to MCP:

- **How a server ships varies.** GitHub's ships as a vendor image: easy. Most community servers
  are `npx -y …` (Node) or `pip install …` / `uvx …` (Python) packages with no image, which
  means *you* build the container. The next sections work through one of each.
- **Pin the image.** `:latest` is a tag, and whoever controls the upstream (or compromised it)
  can repoint a tag. Pin a release (`:v2.1.0`), and for anything that holds a token, the digest
  as well: `podman image inspect --format '{{.Digest}}' <image>` prints the one you pulled, and
  `ghcr.io/github/github-mcp-server@sha256:…` runs exactly that. Pinning freezes security fixes
  along with everything else, so a pin is a promise to come back: rebuild or re-pull when the
  upstream ships a fix, and before the base image's runtime reaches end of life.
- **The token is the real blast radius.** The container protects your machine from the server's
  *code*. It doesn't protect your GitHub account from the server's *actions*: the token's
  permissions are the agent's permissions. The server's `--read-only` keeps write tools out of
  the conversation; the read-only token is what makes a write impossible.

Bubblewrap ([the shell chapter](shell.md)) is `pikuri-code`'s cage for `bash`; a container is
the cage for each MCP server. Different tools for different problems: Bubblewrap bind-mounts
your own tools into a narrowed view of your machine, while a server ships its own dependencies,
so an image fits it better.

If you run `pikuri-code` inside a container instead of a VM, don't also run MCP servers in
containers nested inside it: that takes the host's podman socket or a `--privileged` outer
container, and either hands the agent your host. Lifting the cage is what a VM is for, and
inside one, podman runs these recipes unchanged; see
[the coding agent, completed](code.md#lifting-the-cage-the-outer-vm).

## Narrowing the box to one host

[The MCP chapter](mcp.md#what-the-box-can-reach) measured what a container on podman's default
network reaches: the whole internet, your host's services that listen beyond loopback, and your
LAN. It called that acceptable for a server that holds nothing of yours. This one holds a token
and reads private repositories: all three trifecta legs in one process. An injection in an issue
body is content an attacker controls; the token reads your private code; the open internet is
the way out. GitHub's server needs exactly one host, `api.github.com`, so give it exactly one.

The shape is two networks and a proxy between them:

- **An internal network** (`podman network create --internal`) has no route out at all. The
  server sits on it alone with the proxy.
- **An egress proxy** sits on that network and on an ordinary one. It is
  [tinyproxy](https://tinyproxy.github.io/), Debian's package, built from
  `pikuri-mcp/containers/mcp-egress-proxy.Containerfile`. It answers `CONNECT` only on port 443,
  and only for the hosts baked into the image at build time.
- **`HTTPS_PROXY`** on the server tells its HTTP client where the one way out is.

Built once, from the workshop's checkout:

```sh
podman build -f pikuri-mcp/containers/mcp-egress-proxy.Containerfile \
             --build-arg ALLOW=api.github.com -t mcp-egress-proxy:github pikuri-mcp/containers
podman network create --internal mcp-github
podman network create mcp-egress
podman run -d --name mcp-github-proxy --network mcp-github --network mcp-egress \
           --cap-drop=all --security-opt=no-new-privileges --read-only mcp-egress-proxy:github
```

After a reboot, `podman start mcp-github-proxy`; until then the server starts and every call
fails. The entry gains two arguments, the network and the proxy:

```ruby
command: ['podman', 'run', '-i', '--rm',
          '--cap-drop=all', '--security-opt=no-new-privileges', '--read-only', '--tmpfs', '/tmp',
          '--network=mcp-github', '-e', 'HTTPS_PROXY=http://mcp-github-proxy:8888',
          '-e', 'GITHUB_PERSONAL_ACCESS_TOKEN',
          'ghcr.io/github/github-mcp-server:v2.1.0', 'stdio', '--read-only'],
```

Probed from a container on `mcp-github`, on the test box:

- Every direct connection fails with *network unreachable*: `1.1.1.1`, GitHub's own address, the
  LAN's `llama-server`, the host. There is no route to fail through.
- Through the proxy, `api.github.com:443` connects. `github.com`, `raw.githubusercontent.com` and
  `example.com` get `403 Filtered`; `api.github.com:22` and the LAN address get `403 Access
  violation`.
- The real server worked behind it for every call tried (search, `get_file_contents`,
  `list_issues`), and `podman logs mcp-github-proxy` showed it asking for nothing but
  `api.github.com:443`. The log is also how you find the host a new server needs: run it behind
  a proxy that allows nothing, and read the refusals.

Two things the build had to work around, both in the Containerfile's header. The proxy's outside
network is a network you create, not podman's default one, because the default has no DNS and
the proxy has to resolve `api.github.com`. And Ubuntu's AppArmor profile for
`/usr/bin/tinyproxy` attaches by path even inside a rootless container: it refused the proxy's
config, and every signal from the container runtime, so `podman rm -f` hung. The image moves the
binary off that path.

**Where it stops.** The proxy narrows the way out to GitHub, and GitHub is still a way out:
anything the token can write is a channel. A read-only token closes that one. The trifecta
report can't see the proxy and still counts the server's egress leg, which is the honest count:
the narrowing lives in a command line pikuri doesn't read.

The same pattern fits any server that talks to a few fixed hosts. For one that only reads files
you mount, skip the proxy: `--network=none` takes the network away entirely. For one whose job
is the open web, there is nothing to narrow.

## Running an npx-based MCP

Most community servers ship as npm packages and assume you'll run them with `npx`.
[`mcp-maven-deps`](https://github.com/Bigsy/maven-mcp-server) is a good worked example: small,
useful (it asks Maven Central for the current versions of Java libraries), and entirely
unofficial, which is exactly the case for a container. The repository's name
(`maven-mcp-server`) and the package's (`mcp-maven-deps`) differ, a common trap: check the
`"name"` in `package.json` before typing it into a command.

A side benefit of a container per server: you don't need `node` on your host at all, not even
to look up a version. The image the server will run in answers that:

```sh
podman run --rm docker.io/library/node:26-slim npm view mcp-maven-deps version
# → 0.2.0
```

Node 26 is the current LTS as of this writing; look the current one up at
<https://nodejs.org/en/about/previous-releases> rather than copying it from here.

You could wrap the README's `npx -y mcp-maven-deps` in `podman run … node:26-slim`, and every
spawn would pay for it twice. With `--rm`, the container's npm cache dies with it, so each
start downloads and installs the package again. And `npx` resolves the package's dependency
tree on every spawn, unlocked, so the code you run can change between Monday and Tuesday
without a version number moving. Mounting your `~/.npm` to keep the cache is no fix: `npx` runs
code *from* that cache, so a container that can write to it can plant code your own `npx` will
run on the host later.

Bake an image once instead:

```dockerfile
# maven-mcp.Containerfile
FROM docker.io/library/node:26-slim
RUN npm install -g --ignore-scripts mcp-maven-deps@0.2.0 && npm cache clean --force
USER node
ENTRYPOINT ["mcp-maven-deps"]
```

```sh
podman build -f maven-mcp.Containerfile -t maven-mcp:0.2.0 .
```

```ruby
Pikuri::Mcp::Registry::StdioEntry.new(
  id:      'maven',
  command: ['podman', 'run', '-i', '--rm', '--cap-drop=all', '--security-opt=no-new-privileges',
            '--read-only', '--tmpfs', '/tmp', 'maven-mcp:0.2.0']
)
```

The dependency tree is now resolved once, at build time, and frozen in the image; each spawn
starts in about a second. `--ignore-scripts` keeps every package's install script from running
during the build: this one needs none, and a package that does needs reading first. Rebuild to
upgrade, and when Node 26 reaches end of life (April 2029).

This server talks to one host, `repo1.maven.org`, so it fits the egress proxy too: an image
built with `--build-arg ALLOW=repo1.maven.org`, its own internal network, `HTTPS_PROXY`. Whether
a server honours `HTTPS_PROXY` depends on its HTTP client. This one does on its own; Node's
built-in `fetch` needs `NODE_USE_ENV_PROXY=1` as well. Either way, on an internal network a
server that ignores the proxy fails closed, and the proxy's log names the host it wanted.

## Running a Python-based MCP

Python servers follow the same shape: `pip install <package>` or `uvx <package>` plays the role
of `npx -y <package>`.
[`mcp-server-fetch`](https://github.com/modelcontextprotocol/servers/tree/main/src/fetch) is the
canonical example: one of the protocol's reference servers, published on PyPI, doing roughly
what pikuri's built-in `fetch` tool does, only inside a container.

(Why containerise `fetch` when pikuri ships one? Defence in depth: the bundled `fetch` parses
HTML inside `pikuri-code`'s own process, so a parser bug could land in the agent itself. The
server moves the parser somewhere it can't reach your files. Not necessary; one more notch if
you want it.)

```dockerfile
# fetch-mcp.Containerfile
FROM docker.io/library/python:3.14-slim
RUN pip install --no-cache-dir mcp-server-fetch==2026.11.11
USER nobody
ENTRYPOINT ["python", "-m", "mcp_server_fetch"]
```

```sh
podman build -f fetch-mcp.Containerfile -t fetch-mcp:2026.11.11 .
```

```ruby
Pikuri::Mcp::Registry::StdioEntry.new(
  id:      'fetch',
  command: ['podman', 'run', '-i', '--rm', '--cap-drop=all', '--security-opt=no-new-privileges',
            '--read-only', '--tmpfs', '/tmp', 'fetch-mcp:2026.11.11']
)
```

Same trade as the npm case: a version you chose, a dependency tree resolved once, fast spawns.
Python 3.14 rather than the newer 3.15, because a package's compiled dependencies tend to reach
a new Python release months after it ships. This server's job is the open web, so it gets no
proxy; its egress is the point.

For a server that needs files (a SQLite database, a project directory), mount one host path
with `-v`, and keep it narrow: `-v ~/projects/foo:/work:ro` is a read-only window onto one
project, not your home directory. Such a server rarely needs the network, so add
`--network=none` too. A narrow mount is the file-shaped version of a fine-grained token: the
less the server can touch, the less a bad day costs.

## Browser MCPs are a special case

[Playwright MCP](https://github.com/microsoft/playwright-mcp) is where the threat model bites
hardest. It hands the agent a real browser pointed at URLs the agent picks, and every page it
loads is a chance for an attacker's JavaScript to run in that browser. Every other server in
this chapter sees text the model sent it; this one sees the open web.

Microsoft publishes a ready image, `mcr.microsoft.com/playwright/mcp`, tagged to match the npm
package (`v0.0.85` here). It already runs `tini` as its first process, so podman's `--init` adds
nothing. It does start Chromium with **`--no-sandbox`**: Chromium's own sandbox, the wall between
a page's JavaScript and the rest of the browser, is off by default, and the container is the
only cage left. It can come back:

```ruby
Pikuri::Mcp::Registry::StdioEntry.new(
  id:      'playwright',
  command: ['podman', 'run', '-i', '--rm',
            '--cap-drop=all', '--cap-add=SYS_CHROOT', '--security-opt=no-new-privileges',
            '--read-only', '--tmpfs', '/tmp', '-e', 'HOME=/tmp',
            'mcr.microsoft.com/playwright/mcp:v0.0.85', '--isolated', '--sandbox']
)
```

- **`--sandbox`** after the image overrides the image's `--no-sandbox`. Chromium's sandbox builds
  its own namespaces and needs one capability for it, `SYS_CHROOT`; with all of them dropped, it
  fails to start. With the one added back, `chrome://sandbox` inside the container says "You are
  adequately sandboxed"; without, "You are NOT adequately sandboxed".
- **`-e HOME=/tmp`**: Chromium's crash handler wants a writable home, and `--read-only` took
  `/home/node` away, so the home moves to the in-memory `/tmp`.
- **`--isolated`** keeps the browser profile in memory, so no cookie or login outlives the run.

Headless, as here, is the safer default: no window, no display socket, the browser renders to
memory and reports snapshots through the protocol. Everything below is Linux-specific.

### Headed, when you want to watch

Headed mode lets you watch the clicks land and step in. The vendor image carries everything
Chromium needs for it; only the `--headless` its entrypoint passes has to go, and your display
has to come in:

```ruby
command: ['podman', 'run', '-i', '--rm',
          '--cap-drop=all', '--cap-add=SYS_CHROOT', '--security-opt=no-new-privileges',
          '--read-only', '--tmpfs', '/tmp', '-e', 'HOME=/tmp',
          '-e', "DISPLAY=#{ENV.fetch('DISPLAY')}", '-v', '/tmp/.X11-unix:/tmp/.X11-unix',
          '--entrypoint', '["/usr/bin/tini","-s","--","node","/app/cli.js","--browser","chromium"]',
          'mcr.microsoft.com/playwright/mcp:v0.0.85', '--isolated', '--sandbox']
```

The test box had no display, so this is the one recipe in the chapter not run as written: the
same entrypoint drove a headed Chromium against a virtual display inside the container, but not
against a desktop. Your X server may also want its authority cookie (`$XAUTHORITY`) mounted in.
Mounting `/tmp/.X11-unix` is a real loosening: anything that can talk to that socket can read
your keystrokes and drive your desktop. Turn it on when you want to watch, not as a default.

### Reaching your local dev server

You want the browser on `localhost:3000`, but the container's `localhost` is its own. Measured
on the test box, under rootless podman's default network (pasta):

- **Your host's loopback is closed.** A dev server on `127.0.0.1` is out of reach. That seal
  works *for* you here: attacker JavaScript probing `127.0.0.1` for your local services is a
  classic move, and this is the chapter's largest untrusted surface.
- **`host.containers.internal`** reaches a host service bound to your LAN address or to
  `0.0.0.0`. Bind the dev server to your LAN address and point the browser at
  `http://host.containers.internal:3000`. The cost: the dev server is now on your network too.
- **Your LAN address itself does not work** from inside the container. pasta gives the container
  your host's own address, so a connection to it lands back in the container.
- **`--network=host` opens your host's loopback**, every service on it. The advice you'll find
  online reaches for it first. Don't.

The tightest option is an address that exists only on your host, on a dummy interface:

```sh
sudo ip link add devsrv0 type dummy
sudo ip addr add 192.168.255.1/32 dev devsrv0
sudo ip link set devsrv0 up
```

Bind the dev server to `192.168.255.1` and have the browser navigate to
`http://192.168.255.1:3000`; your LAN never sees it. Not run on the test box, since it needs
sudo; the interface is gone after a reboot. Under rootless Docker the host answers at its LAN
address instead, as [the MCP chapter](mcp.md#what-the-box-can-reach) measured, and its
daemon-wide loopback switch is one [the memories chapter](memories.md) says to leave alone.

Bubblewrap doesn't enter into this: it cages `bash`, and a dev server `bash` started listens
wherever it binds. Whether the browser's container can reach it is decided by the list above.

### Seeing the screenshots

The server returns screenshots inline, which the agent sees and `pikuri-code`'s terminal
doesn't. To look yourself, have it write them to a host folder:

```ruby
'--userns=keep-id:uid=1000,gid=1000', '-v', "#{Dir.home}/.cache/pikuri/playwright:/artifacts",
# … the image, then:
'--isolated', '--sandbox', '--output-dir', '/artifacts'
```

Create the folder first. `--userns=keep-id` makes the container's `node` user you, so it can
write there and the files come out owned by you; without it, rootless podman maps `node` to a
stranger's ID and nothing gets written.

Each `-v`, `--network` and display flag is a notch of isolation traded away. Start headless,
with no host network and no mounts; turn a knob on when you need it, and off again after.

## A note on apt-shipped MCPs

The chapter treats MCP servers as untrusted because that's what `npx -y <package>` and `pip
install <package>` *are*: unreviewed code from a public registry. A server packaged in Debian's
or Ubuntu's archive would change that: maintainer review, a reproducible build from a pinned
upstream, a distribution signature. That's the same signal that lets you `apt install ripgrep`
without a sandbox, and the egress proxy above leans on it for tinyproxy.

As of 2026 no popular MCP server ships that way; the ecosystem is younger than Debian's release
cycle. *If* one you want lands in `apt`, the container becomes optional for the code-trust
question. Two caveats even then: the server can still carry prompt injection in its tool
descriptions or be steered by what it reads, so the verifier still runs; and a token it holds
still needs scoping, since what the token can do doesn't depend on who wrote the code.

## Threat model: what `pikuri-mcp` actually protects against

The same exercise [the completed coding agent](code.md#the-accounting) does for the whole agent, mapped onto the MCP
surface. [pikuri's security chapter](https://github.com/mvysny/pikuri/blob/master/book/security.md)
is the synthesis behind it: the trifecta, the kit, the worked attacks.

What the default configuration *does* protect:

- **Pre-flight injection detection.** The verifier runs before any tool from the server is
  callable: hidden Unicode payloads are rejected mechanically, LLM-judged injection attempts are
  rejected with reasoning, and the server never goes live. A flagged server is one you see and
  investigate, not one you discover after the fact.
- **No tools in context until asked.** `mcp_connect` gates the schemas: a tool that slipped the
  verifier still isn't in context unless the model activates its server.
- **Per-agent activation.** Sub-agents can't reach MCP at all. The privilege separation from
  pikuri's sub-agents chapter carries through, so a `FILE_MINER` reading a malicious file can't
  `mcp_connect` to anything.
- **The container, once you add one.** A malicious server can't read your `~/.ssh` or write to
  your home directory; with the egress proxy, it can't reach anything but its one host.

What it *doesn't* protect:

- **What the server does when it runs.** The verifier reads text, not code. A server with clean
  descriptions that does something hostile when its tools run still goes live. The container is
  your defence there, not the verifier.
- **The LLM judge is an LLM.** The verifier's second pass uses the same kind of model your agent
  talks to; a crafted injection may fool it the same way. The Unicode pass is deterministic and
  catches one whole class; the LLM pass catches *most* of the rest, not all.
- **The token's reach.** A GitHub server given a classic full-access PAT can do anything that
  token can: open issues, comment, push. The token, not the server, is the boundary on what the
  agent can do on GitHub; scope it.
- **HTTP servers and TLS.** `HttpEntry` accepts any URL. Wire in `http://` instead of `https://`
  and you're trusting the network path; the gem doesn't refuse plain HTTP.
- **Cached "OK" results.** A server whose surface hasn't changed doesn't re-run the verifier.
  The cache key is the whole surface, so any change re-triggers it; to clear the cache, delete
  `~/.cache/pikuri/mcp_verifications/`.
- **Poisoned tool *responses*.** The structural gap pikuri's security chapter named: the
  verifier checks the surface at registration, but tool *outputs* during a conversation flow
  into the parent's context unchecked. MCP tools mount on the parent agent, so no sub-agent
  boundary stands between the model and a poisoned response. That chapter's attack 4 walks it
  through.
- **The shared kernel.** Every container flag in this chapter is a rule your kernel enforces,
  so a kernel bug the server can reach turns into your account. For a server you can't read,
  or one you let run unattended, the wall is a virtual machine around the whole process.

In short: **assume an MCP server can take any action its token allows, scope the token to
match, put the server in a container, and narrow its network to the hosts it needs.** The
verifier is a useful belt, not the whole outfit, and a server clean at the handshake can still
ship a poisoned response on a later call.

## What's next

[Agent Skills](skills.md) are the other way to hand an agent new abilities: a folder of
instructions, and sometimes scripts, that the model loads when it needs them. An MCP server's
tools are announced every session and get used off a one-line description; a skill is a body
of text the model has to decide to read, which is why
[a skill needs a trigger and an MCP server doesn't](skills.md#why-a-skill-needs-a-trigger-and-an-mcp-server-doesnt).

The vocabulary you have now (`Pikuri::Agent`, `Tool`, listeners, the Extension protocol,
configure, sub-agent privilege separation, MCP's verifier, synthesizer and per-agent
`mcp_connect`, a container as the MCP boundary) is enough to read the
[`pikuri-mcp`](../pikuri-mcp/README.md) sources directly.
