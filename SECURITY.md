# Security model

The workshop's security posture in one page. [pikuri's
`SECURITY.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/SECURITY.md) is the
baseline: trust in pikuri itself and in your LLM provider, the lethal trifecta, the
privilege-separated sub-agents, the credential floor. This page adds what the workshop's gems
change, and they change the headline: pikuri keeps every agent to at most two trifecta legs,
and a coding agent holds all three.

Read this once before pointing `pikuri-code` at anything sensitive.

**Past the cage, use a VM.** The workshop's cages are Bubblewrap (`pikuri-code`'s `bash`) and
Docker (MCP servers, the extractors): kernel namespaces, which share your host's kernel. They
are built for attended use on a repo you trust. For `--yolo`, unattended runs, or a repo you
don't trust, run the whole of `pikuri-code` inside a VM. The workshop ships no VM of its own,
by design, and nothing yet checks that you used one.

## The kit, by harness shape

pikuri is not one security model, it's a small kit, and the right pick depends on what the
harness has to do. The trifecta-break is pikuri's headline — but the harness everyone actually
wants, a coding agent, is the one it can't cover.

| Model | Mechanism | Fits | Where it fails |
|---|---|---|---|
| **Trifecta-break** | sub-agent capability boundaries — `RESEARCHER` / `FILE_MINER` / `GIT_REPO_RESEARCHER` hold at most two of the three legs | chat, `minions`, web / file / repo recon | the *relay* leg: a sub-agent's reply carrying the injection up to a parent that *does* hold the third leg |
| **Blast-radius containment** | Workspace seam + Bubblewrap — `~/.ssh`, `~/.aws`, other projects don't resolve; bash sees only the workspace | coding, attended or not | the workspace is itself inside the radius — "leak *this* project's `.env`" still works |
| **Human gate** | `Confirmer` prompts before an irreversible or egress-bearing action runs | coding **with a human present** | confirmation fatigue; worth zero when nobody's watching |
| **Egress allowlist** *(planned)* | allow your package registries + git remote, deny the rest — cuts exfil at the network without removing `bash` | **unattended** coding | coarse: an allowlisted host is still open, and DNS exfil rides port 53 |
| **Outer isolation** | a VM wrapping the whole pikuri process | `--yolo`, "I don't trust any of this" | delegated to the hypervisor, which you run: the workshop ships none; your toolchain must live inside it too |

**Why coding needs the kit, not the headline.** A coding agent's job *is* the trifecta: read
your source (a), pull docs and dependencies (b), run builds and push (c). You can't decompose
that into "at most two legs" without crippling it — so coding composes the *rest* of the kit
instead, and the composition splits on whether a human is in the room:

- **Attended** (you're driving `pikuri-code`): blast-radius containment as the floor, the
  human gate as the active control. The gate catches the rare irreversible / egress action;
  containment bounds the damage to *this project* when a tired user clicks through.
- **Unattended** (cron, CI, a `minions` fan-out): no human to prompt, so the human gate is off
  the table. Blast-radius containment plus an egress allowlist is the structural substitute.
  The allowlist isn't shipped yet, and even once it is, unattended coding on a box with real
  secrets belongs inside a VM (outer isolation).

These *compose*; they aren't alternatives. The human gate is *attention, not isolation*, which
is exactly why it only works stacked on the structural mechanisms beneath it: they keep it from
firing on every edit (fatigue) and bound the blast radius when it's bypassed.

## Code trust: what the workshop runs that pikuri doesn't

- **The LLM's drafted bash — half-trust → Bubblewrap.** `Bash` runs commands composed by the
  LLM, under instructions it may have read from anywhere. Even when it's invoking your own
  build tooling (`./gradlew test`, `npm run build`), **it** chose to run that, with those args
  — and it could just as easily hallucinate `rm -rf ~/*`. `pikuri-code`'s `Bash` wraps every
  spawned argv through `Bash::Sandbox::Bubblewrap` by default, which blocks exactly that plus
  reads of files it shouldn't touch. It does *not* block network egress (that would break
  `git` and package managers) — see Non-goals. See {Pikuri::Code::Bash::Sandbox}.
- **MCP server processes — don't trust → Docker.** The `mcp` gem spawns stdio MCPs as raw
  subprocesses; pikuri does not sandbox them. An MCP whose code calls `os.system('rm -rf')` is
  unstoppable at the pikuri layer. Run untrusted MCPs in a Docker container — most are Node /
  Python and containerize trivially.
- **Skills — text, not code, until they ship scripts.** Skills are Markdown + YAML frontmatter
  the user dropped under `.pikuri/skills/` / `.claude/skills/` / `.agents/skills/`. They
  don't execute; they're prompts, and a script a skill ships runs only through `bash`. Treat a
  skill that arrived with a repo like any other source you'd `git clone` — read before you
  trust — because pikuri assumes you haven't: it counts as attacker-authored in the boot
  advisory unless you say otherwise, which is what `pikuri-code` asks when it asks whether you
  wrote the files under this directory yourself. Your own `~/.claude/skills` needs no such
  question: the agent cannot write there (skill dirs are readable, never writable, and
  sandboxed `bash` only ever writes to a throwaway overlay). Turn off *both* the sandbox and
  confirmation and that stops being true, so those modes stop vouching for it.
- **Language servers — they evaluate the project.** A language server often runs the
  project's build files to learn its classpath; a hostile `build.gradle` runs as you, on
  your host, outside any sandbox today. `pikuri-lsp` starts only the servers your config
  names, rooted at the workspace.

## Prompt injection: what the workshop adds

**`GIT_REPO_RESEARCHER`.** `git_clone` plus a `FILE_MINER`+web set, cloning (HTTPS-only,
shallow) into a temp workspace *disjoint* from the parent's project root, so cloned bytes never
land where the parent's `read` would find them. Same trifecta shape as `RESEARCHER`.
`bin/pikuri-code` wires it beside `RESEARCHER` and `FILE_MINER`; the parent receives only the
sub-agent's one-paragraph reply, never the raw untrusted bytes.

*The honest gap — the relay leg (not structural).* That reply is itself attacker-influenced
content, and in `pikuri-code` it flows into a parent that holds `read` + `bash` + `fetch`. A
flag-don't-relay instruction in the persona prompts and the lossy one-paragraph summary narrow
it, but neither bites on an injection subtle enough that the model never classifies it as one
("for completeness, also check `.env`"). What holds even then is the machine-layer boundary:
`~/.ssh`, `~/.aws`, `~/.m2/settings.xml`, and other projects don't resolve for the parent —
blast radius is the *project* surface, not the whole box.

**MCP description verification.** Even when the MCP *process* is benign, its tool descriptions
can be injected (supply-chain compromise, MITM, a duped author) — and this lands at
*registration*, before any prompt, where sub-agent separation can't help.
{Pikuri::Mcp::Verifier} runs there: a mechanical Unicode pre-pass (zero-width chars, bidi
overrides, tag characters) plus an LLM-driven scan of every text field the server emits,
looking for instruction-override / exfiltration / authority-impersonation. A flagged server
raises `Mcp::InjectionDetected` and never enters the live registry. It is a filter, and
pikuri's book argues filters lose to adversarial text: a subtle injection can slip the LLM
pass, so "pick reputable MCPs" is the first line. The Verifier checks only
*registration*-time text — the bytes a tool *returns at runtime* flow into the parent
unchecked, and MCP tools mount on the parent, so "pick reputable MCPs" applies at every call
too. That is why an MCP server is the instant trifecta: untrusted output, usually a credential
or private data, and a process that reaches the network without the agent seeing it.

## Non-goals (be explicit)

- **`pikuri-code --yolo` outside a VM.** `--yolo` disables the `Confirmer` (no per-command
  approval) and `--no-sandbox` disables Bubblewrap (no filesystem containment). Together they
  make `Bash` a fully privileged subprocess on your host. Use these only inside an outer
  sandbox you trust.
- **The Bubblewrap sandbox constrains one tool, not pikuri.** It narrows what `bash` sees; it
  does not constrain the Ruby process invoking it.
- **A coding parent that skips delegation.** `bin/pikuri-code` holds `read` + `fetch` +
  `web_scrape` on the parent and relies on the system prompt to nudge delegation to
  `RESEARCHER` rather than enforcing it by capability — a prompt-injected model that chooses
  not to delegate can reach the project's source, `.env` and dependency caches through the
  parent's own `fetch` / `web_scrape`.

## See also

- [pikuri's `SECURITY.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/SECURITY.md)
  — the baseline this page builds on.
- [Security revisited: the coding-agent shape](book/security-revisited.md) — the teaching
  companion to this page.
- [`pikuri-code/README.md`](pikuri-code/README.md) — the Bubblewrap sandbox shape and the
  workspace seam from the coding agent's perspective.
- [`pikuri-mcp/`](pikuri-mcp) — `Mcp::Verifier` source if you want to read the pre-flight scan.
