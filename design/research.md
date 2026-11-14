# Research — the agent-harness field, on the workshop's ground: sandboxes, skills, slash commands, MCP, memory

What the things we don't own actually do, where it bears on the workshop's gems. About *them*,
never us: a sentence starting "we chose" is a `D_`. One claim per bullet, one provenance marker
per claim — **[docs]**, **[src]**, **[verified &lt;date&gt;, &lt;version&gt;]**, **[unverified]**
(a hypothesis; a design built on it says so). Every **[src]** resolves through pikuri's
`pikuri:R_sources`, which names the tree and the revision each entry was read against; these
entries were read alongside pikuri's and moved here with their gems. Cite by slug, `R_<slug>`; an
entry of pikuri's is `pikuri:R_<slug>`. When you have written an entry, re-read it against the
one above for consistency; a marker already says where a claim came from, so the prose doesn't
repeat it. The **pikuri** column of a comparison table and a closing **Takeaway** carry no marker:
they are what the survey was for.

---

## R_permissions — What each project does about permissions and sandboxing

The pikuri entry is the reference column; everything else carries its provenance.

- **pikuri**: three seams. `Workspace::Filesystem` is one concrete class with explicit
  `project_root:` / `readable:` / `writable:` / `temp:`, routing every coding tool's paths through
  `#resolve_for_read` / `#resolve_for_write` and rejecting `..`-escapes and symlinks that resolve
  outside a declared root; `Filesystem::AllowAll` is the `--yolo` variant, same accessor surface
  but accepting any path *except* a hardcoded credential denylist (`~/.ssh`, `~/.aws`, `~/.gnupg`,
  `~/.kube`, `~/.docker`, `~/.netrc`, `/etc/shadow`, …). `Workspace::Confirmer` gates
  state-mutating tools through `#ask(request:, cancellable:)`, all presentation owned by the confirmer.
  `Code::Bash::Sandbox` is the third seam, governing the bash subprocess's filesystem view rather
  than what the LLM observes: `Sandbox::Bubblewrap` composes a `bwrap` argv from
  `workspace.readable` / `writable` plus a curated `/etc` baseline and per-toolchain *content-only*
  ephemeral overlays, so credentials in `~/.gradle/gradle.properties`, `~/.m2/settings.xml` or
  `~/.cargo/credentials.toml` never appear in the sandbox and writes vanish at process exit. Its
  threat model is blast-radius containment and cross-project contamination, not malware resistance;
  construction refuses if any workspace root contains a container/VM control socket. Every
  subprocess in any `pikuri-*/lib/` goes through `Pikuri::Subprocess.spawn`, one entry point that
  creates a process group per invocation and SIGTERMs everything tracked at exit. Opencode-style
  glob rules are deferred (`design/ideas/coding-agent.md`).
- **ruby_llm**: nothing — out of scope for an SDK. **[src]**
- **langchainrb**: nothing. `Tool::FileSystem` reads and writes anywhere the host process can, and
  `Tool::RubyCodeInterpreter` uses `safe_ruby`, a whitelist-based sandbox the README itself notes
  is "in need of a better solution". **[src]**
- **pi**: a `beforeToolCall` extension hook can return `{ block: true, reason: "..." }`; no built-in
  UI prompt, safety delegated to the host or an extension. **[src]**
- **opencode**: declarative, glob-aware rules (`src/permission/index.ts`) with three actions —
  `allow` / `deny` / `ask`. On `ask`, execution pauses via a `Deferred`, the bus emits a request,
  and the UI replies "once" / "always" / "reject"; denial returns a typed error to the
  model. **[src]**

  ```ts
  {
    "*": "allow",
    question: "deny",
    plan_enter: "deny",
    repo_clone: "deny",
    read: { "*": "allow", "*.env": "ask", "*.env.example": "allow" },
    external_directory: { "*": "ask", ...whitelistedDirs: "allow" },
  }
  ```

- **grok-build**: the most developed of the six on both axes, and the only project here whose OS
  sandbox covers the *agent's own process* rather than just its shell subprocess. **[src]**

**Takeaway.** Pikuri's three seams are the v1 answer for an interactively supervised agent.
opencode's three-action glob model is the obvious next step on the *permission* axis once friction
shows up; the seams are already in place to swap implementations without touching tool internals.
Bubblewrap is not malware-resistant — network egress stays open by design and in-project mutation
is on the table — so adversarial isolation still needs a container or VM around pikuri, with
bubblewrap as the inner layer. langchainrb is the cautionary tale: `FileSystem.read_file` /
`write_to_file` take arbitrary paths from the LLM with no validation.

### Pikuri vs. Claude Code: structural vs. operational defense

Claude Code is not in the project table (it is closed-source), but it is the reference coding agent
the others are shaped after, and its security model is the instructive contrast.

- **Claude Code's main agent holds all three legs of the lethal trifecta at once** — private data,
  untrusted content, egress — across `Read` / `Write` / `Edit`, `Bash`, `WebFetch` / `WebSearch`
  and MCP. It does not attempt a trifecta-break. **[verified 2026-08, CLI 2.1.220–2.1.247]**
- **Its defense is operational, in three layers**: (1) human-in-the-loop permission gating
  (`allow` / `deny` / `ask` rules, permission modes); (2) an OS sandbox (`sandbox-exec` /
  bubblewrap) plus working-directory confinement and a trust-this-folder gate; (3) model-level
  injection resistance plus platform-side monitoring. **[docs]**

**Takeaway.** Pikuri defends *structurally* — remove a leg per agent, so the agent that touches
untrusted content cannot act on an injection, a property of the capability graph that holds even
against a fully injected model. The asymmetry worth recording is that Claude Code's first two
defenses were never primarily injection defenses: the human gate is a *mistake* control (it catches
the hallucinated `rm -rf` whether or not an attacker is involved) and the sandbox is a
*code-execution* control (it bounds blast radius regardless of cause). They blunt injection as a
side effect, so they survive the threat model shifting. Pikuri's trifecta-break is *specifically*
an anti-injection bet, which makes it the one defense that goes obsolete if data-vs-instruction
separation is ever solved — the lethal trifecta is lethal only because injection exists. The flip
side in pikuri's favour: a model's own injection resistance is the one leg living *inside* the
component an injection compromises, so it cannot be leaned on alone, and neither project does.

Where they converge: pikuri cannot break the trifecta for its own coding agent either —
`bin/pikuri-code` holds `read` + `bash` + `fetch` on the parent and falls
back to system-prompt nudging plus the `Confirmer` (SECURITY.md "Non-goals"). Coding is the harness
where the structural model runs out and the operational one takes over. And Claude Code's visible
investment in reducing confirmation fatigue is the same conclusion driving pikuri's
confirmer-as-last-line-of-defense framing (`book/security.md` §"The human gate, and why fatigue is
the enemy"): for an *attended* coding agent the human gate is the load-bearing control, and its
whole value rides on not inducing fatigue. The shared nuance is deployment shape — the human gate
is worth zero *unattended* (cron, CI, a `minions` fan-out), where only structural defense or an
egress allowlist survives.

### Prior art deep-dive: PI's two isolation weights, opencode's permission system

The deeper survey of *how*, done while scoping pikuri's own security posture.

Common ground:

- **Neither has prompt-injection defenses.** No provenance markers on tool output, no "treat
  results as data" language in system prompts, no separate channels. **[src]**
- **Both cap tool output** at ~2000 lines / 50 KB, with the overflow spilled to a tempfile whose
  path is returned to the LLM. **[src]**
- **Both validate sub-agent privilege separation as the right shape** — PI via a `--tools`
  allowlist on the spawned child
  (`packages/coding-agent/examples/extensions/subagent/index.ts:267`), opencode via inherited
  parent-denies plus per-preset deny baselines
  (`packages/opencode/src/agent/subagent-permissions.ts`, `agent/agent.ts:178-220`). **[src]**

PI:

- **PI ships nothing security-related in core.** No permission system (only a 30-line example
  extension regex-matching `rm -rf` / `sudo` / `chmod 777`), no workspace constraint (paths resolve
  absolutely with `~` expansion, no `..` rejection — `core/tools/path-utils.ts:54-93`), bash
  unrestricted, no MCP, no provider warnings, no Dockerfile. **[src]**
- **The README's stance is one line: "Run in a container yourself."** **[docs]**
- **The lighter isolation extension is `sandbox`**: it wraps the `bash` tool only — bubblewrap on
  Linux, `sandbox-exec` on macOS — driven by `~/.pi/agent/extensions/sandbox.json`, with a default
  policy of network *on* behind an npm/pypi/github allowlist, deny-read for `~/.ssh` / `~/.aws` /
  `~/.gnupg`, and deny-write for `.env*` / `*.pem` / `*.key`
  (`packages/coding-agent/examples/extensions/sandbox/index.ts`). **[src]**
- **Only `bash` is wrapped** — `edit` / `write` / `read` execute outside the sandbox, so an
  injection that prefers `edit` over `bash sed` walks past it. **[src]**
- **Sub-agents spawn as separate `pi` child processes that do not inherit the `-e ./sandbox`
  flag** — no recursion. **[src]**
- **The heavier isolation story is Gondolin** (github.com/earendil-works/gondolin, a separate
  Apache-2.0 project from the same org): lightweight Linux micro-VMs (QEMU by default, experimental
  `krun` backend), explicitly stronger isolation than containers or namespaces, and the PI-side
  extension runs the *whole toolset* inside with the project mounted at `/workspace`. **[docs]**
- **Gondolin ships a programmable HTTP/TLS egress proxy with allowlists** — a real proxy that
  inspects what is leaving, not iptables. **[docs]**
- **Its VFS mounts are JS-configurable**: the host decides what filesystem the guest sees. **[docs]**
- **Its secret-placeholder pattern is genuinely novel prior art.** Guest env vars hold
  placeholders, not real values; the egress proxy substitutes the real secret only on outbound
  requests to allowlisted hosts, so `echo $STRIPE_KEY > attacker.com` fails twice — the env does not
  contain the real key, and `attacker.com` is not allowlisted. **[docs]**
- **Gondolin is also the substrate for `pi-chat`** (a Discord/Telegram → Claude bridge from the
  same org), one micro-VM per channel for multi-tenant isolation — though pi-chat's own docs say
  *"All outbound HTTP/TLS open by default"*, so the egress policy is available but not aggressively
  configured in that product. **[docs]**

opencode:

- **A three-action `allow` / `deny` / `ask` system keyed on `(permission-name, glob-pattern)`**,
  last-match-wins, default-`ask`, persisted to per-project SQLite for `always` approvals
  (`permission/evaluate.ts:11`, `permission/index.ts:140-145`). **[src]**
- **A tree-sitter bash parser derives sticky-approval prefix patterns** like `git status *`
  (`tool/shell.ts:261-265, 308-333`). **[src]**
- **Its `SECURITY.md` is explicit at the top**: *"OpenCode does not sandbox the agent. The
  permission system exists as a UX feature... it is not designed to provide security
  isolation."* **[docs]**
- **The workspace is soft**: out-of-tree access triggers an `external_directory` prompt rather than
  a denial, with no realpath or symlink resolution
  (`project/instance-context.ts:18-23`). **[src]**
- **MCP servers spawn as raw subprocesses inheriting `process.env`, with schemas loaded eagerly**
  (`mcp/index.ts:412-445, 513-549`). **[src]**
- **Sub-agent presets `general` / `explore` / `scout` use `"*": "deny"` with selective allows**, and
  parent denies propagate into the child. **[src]**
- **Skills load from arbitrary URLs with no signature or integrity check**
  (`skill/discovery.ts:54-104`). **[src]**
- **No egress controls, no provider warnings.** **[src]**

**Takeaway.** Five things are worth borrowing or considering: disk spillover for over-cap output
(per-tool byte caps already exist in `Bash` / `Read` / `WebScrape`; the missing piece is writing the
overflow to a tempfile and returning the path — cross-cutting version in
`design/ideas/security-open-questions.md`); sub-agent toolset narrowing, already shipped via
personas (`pikuri:R_sub_agents`); opencode's `(permission-name, glob-pattern)` ruleset shape if `Confirmer`
ever expands beyond binary approve/deny; PI's credential-dir deny-read defaults, partially shipped
already as `Filesystem::AllowAll`'s denylist; and Gondolin's secret-placeholder pattern, which is a
structural defense against exfil-via-injection rather than "an approval prompt the user is no longer
reading" — heavyweight, needing an HTTP/TLS interceptor, and flagged as future thought. opencode's
"this is UX, not security" framing is the honest baseline pikuri's `SECURITY.md` borrows under
"Non-goals".

The mental model worth recording: PI ships no isolation in core and offers *two extensions of
different weights* — bash-only bubblewrap, and a full micro-VM. That makes it prior art for "ship
the sandbox primitive separately, let the user opt in at the weight they need", a different shape
from opencode's explicit "we're not a sandbox, run it in Docker yourself".

### Prior art deep-dive: grok-build's authorization pipeline and in-process sandbox

The strongest prior art in this file for pikuri's two deferred security threads — glob permission
rules (`design/ideas/coding-agent.md`) and agentic review of bash commands.

- **The authorization pipeline is ordered and documented.** Every tool call walks five stages: (1)
  `PreToolUse` hooks, which may deny but whose *allow* only declines to deny; (2) permission rules
  from every config source, merged and evaluated **by severity, not by order or file** — `deny` >
  `ask` > `allow`, so a global deny cannot be overridden by a project allow; (3) remembered
  per-command grants, scoped to the git repository root; (4) built-in auto-approvals for read-only
  tools and a curated read-only shell-command list; (5) the permission mode's prompt policy. **[src]**
- **Six modes span the range** from `default` (ask) through `acceptEdits`, `auto`, `dontAsk`
  (deny-by-default allowlists for CI) to `bypassPermissions` (`--yolo`). **[docs]**
- **Rules cover `Bash`, `Read`, `Edit`, `Grep`, `MCPTool`, `WebFetch`, `WebSearch`**, and
  grok-build reads Claude Code's `.claude/settings.json` directly. **[src]**
- **Commands are parsed and split on `&&`, `||`, `;`, `|` and newlines**, with `deny` / `ask`
  checked per segment; a command that cannot be split into simple segments (subshells, `$(…)`,
  backticks, background `&`, control flow) prompts as one unit. **[src]**
- **Segment checks strip env prefixes** (`RUST_LOG=debug …`) and peel a fixed wrapper set
  (`timeout`, `nice`, `ionice`, `chrt`, `stdbuf`, `env`); `sudo`, `xargs` and `nohup` are
  deliberately *not* peeled, and `deny` / `ask` also reach inside inline `bash -c` scripts. **[src]**
- **The read-only allowlist is word-boundary matched** (`ls` does not match `lsof`). **[src]**
- **Its exclusions are the education**: `tee` is off the list because it writes arbitrary files;
  `cargo check` because it compiles and runs `build.rs`, proc-macros and any
  `build.rustc-wrapper` from the repo; `rg --pre` because it spawns a preprocessor per file;
  `sort --compress-program=…` likewise. **[src]**
- **A git command whose local config installs an executable hook raises a prompt floor** —
  `core.fsmonitor`, a `diff.*.command` / `textconv` / `external` driver, or an
  `alias.<safe-subcommand> = !…` — because `git log` in a hostile repo is arbitrary code
  execution. **[src]**
- **A dangerous-command list** (`rm`, `chmod`, `chown`, `chgrp`, `chattr`, `pkill`, `kill`,
  `killall`, `git push`) never honours a remembered *prefix*, only an exact grant for the whole
  command; and where no rememberable grant could stop the prompt recurring, the "always allow" row
  is not offered at all rather than saving a rule that would not work. **[src]**
- **An honest documented footgun**: `allow` rules match the whole command string only, so
  `Bash(git *)` auto-approves `git status && rm -rf /`. The docs say so in as many words. **[docs]**
- **The sandbox inverts pikuri's posture**: `xai-grok-sandbox` applies Landlock (Linux) / Seatbelt
  (macOS) *once at process startup* via the `nono` crate, covering the agent's own `tokio::fs` calls
  as well as every child. Five profiles — `off` (default), `workspace` (read everywhere, write CWD +
  temp + `~/.grok`), `devbox`, `read-only`, `strict` — with custom profiles in
  `sandbox.toml`. **[src]**
- **Network is the mirror image of pikuri's `FullFsNoNet`**: open at the process level (the agent
  needs the LLM API) and blocked per-subprocess via seccomp, Linux only, explicitly a no-op on
  macOS. **[src]**
- **A custom profile's `deny` list is kernel-enforced for read *and* write/rename**, specifically to
  close the `mv secret x && cat x` bypass. On Linux that requires bubblewrap, and if bubblewrap is
  missing or any single deny path cannot be bound, grok-build refuses to start rather than run with
  denied paths exposed. **[src]**
- **Nested user namespaces are disabled inside the bwrap layer** so mount binds cannot be rearranged
  from within, and the seccomp filter rejects `clone` / `clone3` carrying namespace bits —
  grok-build blocks from inside its own sandbox the very primitive pikuri's sandbox is built
  on. **[src]**
- **Folder trust closes a gap pikuri has open.** A cloned repository can ship `.mcp.json`, a project
  `.grok/config.toml` carrying `[permission]` auto-approve rules and `[mcp_servers]` commands, or
  `.grok/lsp.json` — all of which the CLI would otherwise honour on `cd`-and-launch. grok-build's
  own module comment calls this **"a 1-click RCE / policy bypass"**, and it resolves a VS-Code-style
  trust decision once per workspace, before any repo-local server is spawned, with every loader
  consulting a cheap `project_scope_allowed` check. **[src]**
- **Two grants are deliberately provisional and never cached**: the "there were no repo configs"
  allow (so a config appearing after a `git pull`, or written by the agent itself, is re-checked)
  and the unrecordable-key case (cwd is `$HOME` or the filesystem root). **[src]**
- **No prompt-injection defense** — same as PI and opencode. Every hit for "prompt injection" in the
  tree is the benign sense, injecting text *into* the prompt. **[src]**
- **It does have a mechanical Unicode confusable pre-pass**, aimed at edit-matching failures rather
  than hidden instructions. **[src]**

**Takeaway.** The load-bearing tag in pikuri's `SECURITY.md` stands: three of the largest coding
agents in the world, including a shipped commercial one, all decline to claim an injection defense.
The six-mode permission system, the persisted grant store and the managed
`/etc/grok/requirements.toml` admin layer are enterprise-shaped and out of scope. Three things are
not:

- **The read-only shell-command list, with its exclusions** — the `git -c` / `textconv` / `!alias`
  finding in particular. If pikuri ever auto-approves a bash command, this list is the starting
  point, and re-deriving it independently would be negligent.
- **Folder trust.** `Skill::Catalog::Bundled` scans `.pikuri/skills`, `.claude/skills` and
  `.agents/skills` under whatever bases the host passes — typically the project root — so a cloned
  repository's skill names and descriptions land in the system prompt with no trust decision at all.
  The `skill` tool already tags a skill body `untrusted: :hard`, which is the right classification
  of the *content*; what is missing is a gate on the *source*. `Mcp::Registry` is host-supplied
  today, so skills are the live exposure.
- **Per-segment analysis before any policy decision.** `Confirmer` shows the human one command
  string; splitting on the shell operators and showing the segments — the way grok-build does
  before any rule matches — is a presentation change that costs nothing and directly serves the
  confirmer-fatigue argument in `book/security.md`.

## R_skills — How each harness discovers, advertises and gates Agent Skills

- **pikuri**: the `pikuri-skills` gem — `Skill::Catalog` (abstract base) + `Catalog::Bundled`
  (on-disk scanner) + `Skill::Renderer` (the XML) + `Skill::Extension` (the wiring) — implements the
  [Agent Skills standard](https://agentskills.io/specification). Discovery is **host-supplied, not
  walked**: `Catalog::Bundled.new(search_bases: […])` scans `.pikuri/skills`, `.claude/skills`,
  `.agents/skills` under each base it is given. Precedence is bases left-to-right then subdirs in
  that order, first name seen winning, so "project beats global" is the *typical wiring* rather than
  a rule the catalog enforces. One directory level only, each entry needing a `SKILL.md`;
  frontmatter validation is lenient — a missing `description` is the sole hard failure. Wiring is
  opt-in via `c.add_extension(Skill::Extension.new(catalog:, root:))`, which on a non-empty catalog
  contributes the `<available_skills>` block as a system-prompt snippet and registers the `skill`
  tool. `Catalog#roots` is exposed so the host can fold the skill dirs into the workspace's readable
  set, which is what makes a skill's sidecar files reachable through `read`. Flat `*.md` slash
  commands are a *separate* registry over the same search bases (`R_slash_commands`).
- **pi implements the same Agent Skills standard**; pikuri's implementation reuses pi's XML block
  shape so a skill folder authored against any compliant harness renders consistently. **[src]**
- **opencode ships its own skill mechanism** (related but pre-standard), and **v2 moved the
  inventory into the prompt** — `<available_skills>` renders into a system-context block
  (`core/src/skill/guidance.ts`, `SystemContext.Key "core/skill-guidance"`); only its docs page
  still claims the tool description carries it. **[src]**
- **opencode's block is *live* where pikuri's is assembled once.** It declares `baseline` / `update`
  / `removed` renders, so a mid-session change to the skill set arrives as a delta (*"The available
  skills have changed. This list supersedes the previous available skills list."*), and the whole
  block vanishes when the `skill` tool is denied. **[src]**
- **grok-build has the widest discovery net of anyone** — `.grok/skills`, `.agents/skills`,
  `.claude/skills` *and* `.cursor/skills`, at local / repo / user tiers, walking every directory
  between CWD and the repo root, deduplicated by name with higher tiers winning. **[src]**
- **Vendor compatibility is a config cell you can switch off per vendor** (`[compat.claude] skills =
  false`), and known vendor-shipped defaults (Cursor's `shell`, `canvas`, `statusline`) are always
  filtered out. **[src]**
- **grok-build's discovery deliberately ignores `.gitignore`** — teams gitignore `.claude/**` as
  local config yet still expect project commands to work. **[src]**
- **A `[skills] disabled` list keeps a skill listed but inert**, distinct from `ignore`, which hides
  it; and flat `*.md` under a `commands/` directory become user-invocable slash commands. **[src]**
- **grok-build also ships plugins** — a marketplace-installable bundle of skills + commands + agents
  + hooks + MCP servers, gated by the same folder-trust decision. **[src]**
- **grok-build's catalog is not a system-prompt block at all**: baseline and updates alike arrive as
  `<system-reminder>` injections, and a `paths:` frontmatter key holds a skill out of the listing
  until a tool reads or edits a matching file. **[src]**
- **ruby_llm and langchainrb have no concept of skills.** **[src]**

**Takeaway.** With opencode v2's move, pikuri, pi, Claude Code and opencode all render the listing
into the prompt and grok-build is the sole holdout. opencode's live block is the mechanism a
hot-reload would need and the one that costs a prompt-cache invalidation to run; pikuri scans at
boot and does not watch the filesystem, so it buys the cache instead.

### Nobody batches the load call

| harness | load tool input |
|---|---|
| pikuri | `name` |
| opencode | `name` (`core/src/tool/skill.ts`) — v1 and v2 both |
| grok-build | `skill` + optional `args` (`implementations/skills/skill.rs`), where `args` is the slash-command argument, not a batch |

- **Three independent implementations, none of which grew a `names: []`.** **[src]** Weak evidence,
  but it is the only evidence available.

**Takeaway.** pikuri needs no such parameter anyway: ruby_llm executes *every* tool call in an
assistant message (`chat.rb:346`, `tool_calls.each_value`), so `skill("cop")` + `skill("tuile")` +
a `read` in one message is already one round trip. An array would be a second way to do the same
thing, and would make the pathological case — four bodies in one shot — the easier one to type.

### The *human* path is zero-round-trip everywhere — by three routes

- **Neither surveyed harness optimizes the model's load path; both optimize the human's,
  identically** — by expanding the body at prompt-assembly time rather than routing it through a
  tool. **[src]**
- **opencode auto-registers every skill as a slash command whose `template` *is* the skill body**
  (`opencode/src/command/index.ts:142`). The `/skills` picker
  (`tui/component/dialog-skill.tsx`) injects nothing — it types `/<skill> ` into the prompt input,
  and the body lands as the user message. **[src]**
- **grok-build expands `/commit fix the build` into a `<skill_information>` envelope** appended
  after `<user_query>`, with a `<skills_referenced>` index of name + path. Its source calls this, in
  so many words, "the new zero-round-trip path". **[src]**

**Takeaway.** pikuri ships the same human path by a different route.
`Skill::Extension#schedule_load_skill` is the seam, and since `pikuri:D_reference_text_as_user_turn` it
lands the body as a `<system-reminder>`-wrapped `:user` turn, so the `:system`-vs-`:user`
divergence that used to be the interesting difference here has closed on its own. `bin/pikuri-code`
wires it as the third leg of the typed-`/name` chain (host built-in > command > skill). Two real
differences remain: pikuri's `/name` skill leg is deliberately argument-less (a command is a
template with `$ARGUMENTS`; a skill body is fixed text, so there is nothing for an argument to do,
where grok-build routes both kinds through one mechanism), and pikuri declines the
auto-registration — the two-registry split (`D_slash_commands`) keeps a model-invoked, advertised
skill apart from a human-invoked, never-advertised command, because collapsing them would put a body
pikuri charges per *use* onto a surface charged per *install*. Both of pikuri's doors render through
the same `Renderer.format_skill`.

### Frontmatter: the six standard fields, and the nine invented ones

Verified 2026-08-16 against the spec and the same grok-build `SOURCE_REV` as the rest of this file.

- **The [Agent Skills spec](https://agentskills.io/specification) defines exactly six frontmatter
  fields.** **[docs]**

| field | purpose | pikuri reads |
| --- | --- | --- |
| `name` | skill identifier | yes — falls back to the parent directory name |
| `description` | what it does / when to use it | yes — the only hard requirement |
| `license` | license identifier | no |
| `compatibility` | free text, ≤500 chars, for a human | no |
| `metadata` | arbitrary client key-value map | no |
| `allowed-tools` | tools the skill may use | no |

- **None of the six expresses *when* a skill applies** — precisely the field every harness wanting
  conditional activation has had to invent. **[docs]**
- **grok-build invents nine, all at top level** (`discovery.rs:300–318`): `short_description`,
  `author`, `argument_hint`, `model`, `effort`, `user_invocable`, `disable_model_invocation`,
  `when_to_use`, `paths`. **[src]**

Four findings worth carrying:

1. **grok-build uses the sanctioned extension point *and* top-level keys.** `metadata` is *"an
   arbitrary key-value mapping … clients can use this to store additional properties not defined by
   the Agent Skills spec"*, with a recommendation to pick "reasonably unique" key names **[docs]**;
   grok-build parses it (`discovery.rs` `parse_metadata`), promoting `metadata.author` and
   `metadata.short-description` to typed fields and keeping the rest in a generic string map, and
   documents that in its user guide **[src]**. The nine extension keys sit at top level *alongside*
   that, which is off-spec for those nine — any could collide with a future official field — but the
   extension point is not declined. A harness adding a key therefore has a real fork with proven
   precedent on both sides: the top-level spelling buys two-harness agreement and inherits the
   collision risk, while `metadata: {<vendor>-<key>: …}` is spec-clean, agrees with nobody, and is
   nonetheless the shape grok-build itself reads. For a *newly invented* predicate there is no
   agreement to buy, so `metadata:` wins by default.
2. **An empty `paths:` marks a skill *unconditional*, not "never".**
   `…/skill_discovery_tracker/conditional.rs:38` gates on
   `s.paths.as_ref().is_some_and(|p| !p.is_empty()) && …`, so `paths: []` means always-listed — the
   opposite of what an author writing "this skill matches no paths" would intend. `paths: ["**"]`
   lands the same way: `normalize_skill_paths` (`discovery.rs:243`) drops empties, strips a trailing
   `/**` (`src/**` → `src`), and returns `None` when the result is empty *or* every pattern is `**`
   — and `None` is exactly how "unconditional" is spelled internally. **[src]**
3. **Unknown keys fail open, everywhere.** pikuri's `Catalog::Bundled#parse_skill` reads `name`,
   `description`, `paths` and `when-to-use` and drops the rest; Claude Code listed a skill carrying
   `argument-hint:` — a slash-command key, not a skill one — normally for months. A skill tagged
   with a key the host does not implement is simply advertised unconditionally, costing nothing and
   buying nothing until someone implements it. **[verified 2026-08-16, Claude Code 2.1.233]**
4. **`paths:` is not a grok-build invention — Claude Code implements it too.** Observed directly on
   2026-08-16 on **Claude Code 2.1.233**; the behaviour is undocumented, so it carries no
   compatibility promise and a later build may move it. Five skills under `~/.claude/skills` were
   annotated with `paths:`, and the four whose globs matched nothing read that session vanished from
   the session's skill listing, while `ideas-folder` (`design/ideas/**`) stayed — `design/ideas/*.md`
   had been read. Reading a single `.rb` file then caused exactly the two `**/*.rb`-gated skills
   (`writing-rdoc`, `tuile`) to be announced mid-session **with their full descriptions**, while the
   `**/*.java`- and `src/test`-gated ones stayed hidden. That is grok-build's shape precisely:
   withheld until a touched file matches, then promoted description-and-all.
   **[verified 2026-08-16, Claude Code 2.1.233]**

**The pattern dialect is gitignore's, on both harnesses — measured 2026-08-17.** grok-build's
`skill_matches_any` (`skill_discovery_tracker/conditional.rs:96–121`, `main`) hands every pattern to
an unmodified `ignore::gitignore::GitignoreBuilder` rooted at cwd and matches with
`matched_path_or_any_parents`; `coerce_path_list`'s own doc comment says a `{a,b}` group is left
intact *"for the gitignore matcher to expand"*. **[src]** Claude Code 2.1.233 was then probed
black-box — throwaway gated skills in a scratch project, each body revealing a magic word, the model
told to *invoke* the skill and report the verbatim result. That invoke-or-error signal is the sound
one: asking the model whether a skill was "available" contradicted itself across identical runs.
**[verified 2026-08-17, Claude Code 2.1.233]**

| `paths:` | file read | Claude Code | rule |
| --- | --- | --- | --- |
| `probeleaf` | `unrelated/file.txt` | `Unknown skill` | the gate holds |
| `probeleaf` | `probeleaf/file.txt` | activated | a direct hit fires |
| `probeleaf` | `nested/probeleaf/file.txt` | activated | **a slash-less pattern floats to any depth** |
| `/probeleaf` | `nested/probeleaf/file.txt` | `Unknown skill` | a leading slash roots it |
| `nested/probeleaf` | `deep/nested/probeleaf/x.txt` | `Unknown skill` | a slash *anywhere* roots it |
| `{alpha,beta}/**` | `beta/x.txt` | activated | a brace group expands |

**[verified 2026-08-17, Claude Code 2.1.233]**

- **That dialect is not minimatch**, which is what Cursor's `globs:` and GitHub Copilot's
  `applyTo:` — the same idea under two other names — take: there `*` never crosses a `/`, so `foo`
  covers neither `nested/foo/` nor anything beneath the directory, and a pattern copied in from
  either under-matches here. **[docs]**
- **Nor is it git's own gitignore**: git treats `{a,b}` literally (a `.gitignore` of `{a,b}/**`
  hides nothing under `git check-ignore`, while `rg` hides both directories), so the brace row is
  specifically ripgrep's flavour. **[verified 2026-08-17]**
- **"Hidden" means unreachable, not merely unlisted.** `skill(name: "writing-javadoc")` — on disk,
  valid frontmatter, `**/*.java` never touched — returned `Unknown skill: writing-javadoc`,
  *byte-identical* to the reply for a name that exists nowhere. A gated skill is indistinguishable
  from a nonexistent one, and the listing withholds the whole entry, name included: Claude Code
  ships grok-build's capability gate, not a visibility
  filter. **[verified 2026-08-17, Claude Code 2.1.233]**
- **That refusal came back as a *tool-execution* error, not a schema rejection**, so Claude Code's
  skill tool takes a free-form `name` rather than an enum of the active set. The two choices are a
  package — an enum of only-active names would have to be rebuilt on every promotion, churning the
  tool schema mid-session. **[verified 2026-08-17, Claude Code 2.1.233]**
- **The gate binds the human operator too, in both harnesses.** In a fresh Claude Code session,
  `/writing-rdoc` — a skill the operator wrote, whose name they typed from memory — returned
  `Unknown command: writing-rdoc`. **[verified 2026-08-17, Claude Code 2.1.233]**
- **grok-build does the same by construction**: `slash_skills()`
  (`skill_discovery_tracker/mod.rs:475`) combines `discovered_skills` with `startup_skills`, and
  `startup_skills` is what `take_unconditional` left behind after partitioning the gated ones into
  `ConditionalSkills::held` (`mod.rs:334-336`). `bridge.rs:411-415` calls that projection *"the
  authoritative source for slash command advertisement"*, and
  `SlashCommandSet::skill_resolvable` (`slash_commands.rs:659-665`) searches only it — so a gated
  name does not resolve when typed, not merely fail to autocomplete. **[src]**
- **The one accessor that reaches held skills has a single model-facing consumer.**
  `ConditionalSkills::held` — commented *"so registry-wide lookups can see skills the listing
  withholds"* — is consumed only by `suggest_skill_path`, a did-you-mean for a failed `SKILL.md`
  read. There is no operator escape hatch in either implementation. **[src]**
- **`paths:` is absent from grok-build's own user guide**, whose optional-frontmatter table
  documents ten other fields — so this is convergence on undocumented behaviour. **[docs]**
- **That guide documents `user-invocable: false` and `disable-model-invocation: true` as
  deliberately orthogonal axes for the two audiences** — which `paths:`, undocumented,
  collapses. **[docs]**
- **Bash does not count as a touch**: repeated `grep` / `sed` over `.rb` files through the shell
  promoted nothing across four separate turns, and a single `Read` of one `.rb` file promoted both
  `**/*.rb` skills at once. **[verified 2026-08-17, Claude Code 2.1.233]**
- **Promotion is once per conversation**: `ideas-folder` fired on the first `design/ideas/` read and
  never re-fired across a later read, a write and an edit in the same
  folder. **[verified 2026-08-17, Claude Code 2.1.233]**
- **The announcement carries the description only, never the
  body.** **[verified 2026-08-17, Claude Code 2.1.233]**
- **Claude Code did not render `when-to-use:` in those announcements**, so it implements at least one
  of grok-build's nine extensions and not another — "non-standard" is not one
  bucket. **[verified 2026-08-17, Claude Code 2.1.233]**
- **`compatibility` is the nearest existing field in spirit** — its own examples are *"Requires git,
  docker, jq"* and *"Designed for Claude Code"* — but it is free text aimed at a human judging "will
  this work in my environment". Nothing parses it, and it cannot carry a machine
  predicate. **[docs]**

**Takeaway.** The practical consequence for a shared skill folder is that annotating it is *not*
inert: `~/.claude/skills` is where most pikuri-visible skills actually live, so a `paths:` added for
pikuri's benefit changes Claude Code sessions today. And the load-bearing part is convergence: two
independent harnesses ship this predicate, which makes it an emerging extension rather than one
vendor's idea — and the strongest available argument that pikuri is *behind* on this axis rather
than declining to follow a fad.

### How grok-build's conditional activation actually works

Read 2026-08-16 against `main` at `5163763` — a newer monorepo sync than the `84ae1223` the rest of
this file cites, so treat this subsection as the later reading where the two disagree. grok-build is
the only harness whose *implementation* can be read, but per finding 4 above it is not the only one
shipping the feature, so read it as the documented reference implementation of a predicate two
harnesses honour.

1. **The trigger is a file the model *touched*, not a project shape.** `SkillDiscoveryReminder` runs
   after every tool call, but `extract_activation_paths` (`reminders/skill_discovery.rs:68`) yields
   paths from only four output variants — `ReadFile`, `ListDir`, `SearchReplace` and `ApplyPatch`
   (every file of a multi-file patch, rename targets included). Its comment is explicit that
   *"Bash/grep paths are excluded (unparseable / incidental)"*. So `paths: [build.gradle]` fires only
   when the model reads or edits that file; a `grep` hit, a `bash` invocation, or the file merely
   existing all fail to activate it. `paths:` cannot express "this is a Gradle project". **[src]**
2. **Matching is gitignore syntax; activation is sticky and session-scoped.** `skill_matches_any`
   (`conditional.rs:96`) builds an `ignore::GitignoreBuilder` matcher from the patterns relative to
   cwd and uses `matched_path_or_any_parents`, so a bare directory pattern matches files beneath it.
   Activated skills stay in `held`, gated by an `activated` set, so a re-seed can re-promote them;
   `/clear` calls `rehide()` (`conditional.rs:86`), which clears activations and re-partitions so a
   promoted skill drops back to held. **[src]**
3. **There is no resident skill catalog in the system prompt at all — the startup baseline is an
   injection too.** `<available_skills>` occurs in exactly one file repo-wide (the tracker's listing
   renderer); no prompt template renders it. `seed()` marks `pending = BaselineChange` and the first
   `take_pending()` emits the whole listing as a `<system-reminder>`, the same channel a later
   activation uses. A test is named for the property:
   `seed_produces_system_reminder_not_prompt_mutation` (`skill_discovery_tracker/mod.rs:1047`). **[src]**
4. **`when-to-use:` is a rendering split, and the renderer retro-fits it when the field is absent.**
   Parsed as either `when-to-use` or `when_to_use`, capped at 1024 chars like `description`.
   Rendered as `description — Use when: <trigger>` (XML) or a separate `Use when:` line. When the
   field is missing, `build_skill_entry` (`listing.rs:525`) derives one by splitting the
   *description* at the first of ten recognized connectives (`use this skill when`, `use when`,
   `triggers on`, `invoke when`, …, case-insensitive) and treating the tail as the trigger; the
   leading connective is stripped so the renderer's own label is not doubled, with a word-boundary
   guard so `Use whenever` does not match. A description that *opens* with a connective is left
   unsplit. The split takes everything after the first match, so trailing non-trigger prose lands in
   the trigger half. **[src]**
5. **Names-only listing exists, but only as budget overflow.** Per entry, `description` +
   `when_to_use` share a 400-byte cap, split proportionally to their lengths with a 20-byte floor
   each; the listing as a whole gets 50 % of the context window, and `name_only()` renders when that
   budget runs out. A comment at `mod.rs:446` records that a names-only footer for disabled skills
   was considered and rejected because it *"wastes tokens and looks like skills with no
   description"*. **[src]**
- **The spec's own client guide is behind its ecosystem on this point.**
  `agentskills.io/client-implementation/adding-skills-support` states that *"most implementations
  rely on the model's own judgment as the activation mechanism, rather than implementing harness-side
  trigger matching or keyword detection"* — and `paths:` glob matching is harness-side trigger
  matching, shipped by two of the four surveyed harnesses. **[docs]**

**Takeaway.** Two consequences of finding 3 are worth borrowing independently of `paths:`.
Promotion mutates no prefix, so it costs no prompt-cache invalidation — the cost that would
otherwise price conditional activation out on a provider that hoists system content. And skill
descriptions, which are attacker-influenceable text in a bundle that travels between harnesses, sit
in *conversation* position rather than the most-trusted slot in the request — which is where
untrusted text belongs, and which pikuri's own `<available_skills>` system-prompt snippet does not
do.

The pattern across all four harnesses is worth naming: **every one leaves the decision to model
judgment, and then bolts a nudge mechanism on beside it.** Claude Code and grok-build ship `paths:`;
grok-build adds `when-to-use` and a retro-fitting extractor for descriptions that lack it; opencode
v2 moved its inventory into the prompt to make the listing louder. Nobody trusts the description
alone, and nobody replaces it either. The reason is the capability/correction asymmetry
`book/skills.md` teaches: a tool description advertises a capability the model can feel the lack of,
so it only has to name what fills the gap — while a skill mostly advertises a *correction*, which
the model cannot miss the absence of, because nothing in the task tells it a relevance check is due.
No amount of description tuning closes that, which is why four independent harnesses converged on
adding a trigger. pikuri's `paths:` gate therefore follows the *implementations* rather than the
spec's guide, which is worth knowing before anyone cites that sentence as a reason not to gate. The
guide's two other recommendations pikuri does not follow are both decided on the record: an enum
`name` on the load tool is rejected in `D_skill_path_activation`, and exempting skill content from
context compaction is moot until something compacts.

## R_slash_commands — The human-invoked half, and what Claude Code's expansion actually does

- **Claude Code** reads `~/.claude/commands/*.md` (user) and `.claude/commands/*.md` (project),
  with subdirectories namespacing as `/frontend:foo`. Frontmatter: `description`, `argument-hint`,
  `allowed-tools`, `model`, `disable-model-invocation`. **[docs]**
- **Its body interpolates `$ARGUMENTS` and `$1`…`$9`, inlines a file with `@path`, and runs a shell
  command with `` !`cmd` `` *before the prompt is sent*** — gated only by that same file's
  `allowed-tools:`, i.e. by the untrusted file itself. **[docs]**
- **grok-build** takes flat `*.md` under a `commands/` directory. **[src]**
- **No harness in this survey defines an `.agents/commands` convention**, which is why pikuri scans
  two subdirs and not three. **[src]**
- **pikuri**: `Command::Registry` + `Command::Renderer` in `pikuri-skills`, over the same
  `Bundle::Base` search bases as the skill catalog. Names come from the path (a frontmatter `name:`
  is ignored — for a command the name is the *address the human types*), frontmatter is entirely
  optional, neither inlining leg ships (`` !`cmd` `` is refused outright and `@path` is left as
  literal text — `D_command_inlining_legs`), `allowed-tools:` is refused rather than silently
  widening a toolset its author asked to narrow, and `disable-model-invocation` is the default and
  only behaviour.

Measured against **Claude Code 2.1.233** (headless, throwaway project, each result reproduced on two
models), because three of its behaviours are documented nowhere:

- **The expansion is wrapped** in `<command-message>` / `<command-name>` / `<command-args>`, the
  last omitted when no arguments were typed. The wrapper carries no *location*, so it does not solve
  sidecar-path resolution. **[verified 2026-08, Claude Code 2.1.233]**
- **Arguments a body never references are appended** after two blank lines as
  `ARGUMENTS: <raw>`. **[verified 2026-08, Claude Code 2.1.233]**
- **`$n` is 0-based** — `/probed AAA BBB CCC` against `one=[$1] two=[$2] three=[$3]` yields
  `one=[BBB] two=[CCC] three=[$3]` — while being documented as 1-based and written as 1-based by
  every author, including in Claude Code's own shipped command
  files. **[verified 2026-08, Claude Code 2.1.233]**
- **An out-of-range `$n` stays literal.** **[verified 2026-08, Claude Code 2.1.233]**

**Takeaway.** pikuri ships a `(this command lives in …)` footer where the wrapper carries no
location, copies the `ARGUMENTS:` spelling verbatim so a body authored there reads identically here,
and implements `$n` as 1-based (`D_command_substitution`) while keeping the stays-literal half.

## R_mcp — Who supports the Model Context Protocol, and how they keep its surface cheap

- **pikuri**: `Mcp::Registry` (pure config) + `Mcp::Servers` (runtime — spawns servers, holds
  clients, registers `at_exit`) + per-client `Mcp::ClientWrapper` (restart-on-stdio-death retry) +
  `Mcp::Synthesizer` (LLM-driven summarization of MCP tool surfaces whose `instructions` /
  `serverInfo.title` are unhelpful) + `Mcp::Verifier` (pre-flight injection check: mechanical
  Unicode pre-pass plus LLM inspection for instruction-override, exfiltration, tool-chain hijacking,
  authority-impersonation) + `Mcp::Cache` (on-disk, keyed on the full server surface so any upstream
  change invalidates). Two transports — stdio (the carve-out from the `Subprocess.spawn` chokepoint)
  and HTTP. MCP tools bypass `Pikuri::Tool` and are synthesized as raw `RubyLLM::Tool` subclasses
  with a provenance prefix; the LLM connects on demand via the auto-registered `mcp_connect` tool.
- **opencode ships MCP support**; pikuri's `Mcp::Servers` is informed by its shape but uses the
  `mcp` Ruby gem for the transport layer. **[src]**
- **grok-build loads MCP servers from config, gated by folder trust**, plus the `search_tool` /
  `use_tool` deferred-loading pair (`pikuri:R_available_tools`) — a BM25 index over the tool catalog
  instead of every schema in the window. **[src]**
- **grok-build truncates descriptions to 2 KB and fingerprints a server's surface** as
  `(tool_count, description_hash, names_hash)` to detect when it changed. **[src]**
- **grok-build has no pre-flight injection scan**; the trust gate is the analogous control, firing
  earlier (before the server is spawned) but coarser (whole workspace, not per-server). **[src]**
- **ruby_llm, langchainrb and pi core have no MCP.** **[src]**

**Takeaway.** Skills and MCP are extension surfaces pikuri added deliberately — Skills for "give the
agent static text knowledge that loads on demand", MCP for "expose third-party tool servers the user
already runs". Both auto-wire when their registry or catalog is non-empty, and `EMPTY` singletons
keep the no-feature path zero-config. `Mcp::Verifier` is the novel-to-pikuri piece: pre-flight
injection scanning of a server's surface before any tool is exposed, with `InjectionDetected`
aborting startup for that server.

## R_memory — The two cross-conversation memory implementations, and their opposite substrates

- **Only two projects in the field ship cross-conversation memory**, and they picked opposite
  substrates. **[src]**
- **pikuri** (`pikuri-memory`): durable memory backed by mem0, run as a self-managed sidecar, with a
  `recall` tool plus per-turn prefetch and capture.
- **grok-build uses Markdown files plus a local SQLite index** — `~/.grok/memory/MEMORY.md` global,
  `<project-slug>-<hash8>/MEMORY.md` per workspace (keyed on the `origin` remote in `org/repo` form
  when there is one, so clones and worktrees of a repo share memory), plus per-session logs. **[src]**
- **Search is FTS5 keyword by default, with `vec0` vector search layered on when an embedding model
  is configured**, behind two tools, `memory_search` and `memory_get`. Experimental, off by
  default. **[src]**
- **Automatic per-session saves are metadata only and use no LLM call** — message counts, up to five
  substantive prompt topics, a timestamp. **[src]**
- **Richer capture is an explicit `/flush`, and a `/remember` write shows the user a review panel**,
  with an optional rewritten version, before anything is written. **[src]**
- **grok-build searches memory once, on the first turn**, and upserts the block into the leading
  system prompt, never re-scoring it because that would bust the KV-cache prefix
  (`pikuri:R_synthetic_user_turns`). **[src]**

**Takeaway.** The substrate difference matters more than the feature difference: grok-build's memory
is greppable Markdown a human can edit and own; pikuri's is a service. Given pikuri's privacy-first
positioning and its read-it-in-an-evening ceiling, Markdown-plus-SQLite is arguably the more
pikuri-shaped answer than the one pikuri shipped — and the fallback ladder (FTS5 always, vectors
only if an embedder is configured) is exactly the degradation story `pikuri-vectordb` has to tell
anyway. Worth revisiting; not worth churning a shipped gem over. `pikuri-rag` shipped the FTS5 half
for the *corpus* side, though as a peer rather than a ladder — both legs always run and are fused by
reciprocal rank, because it was built for retrieval quality rather than for degrading gracefully
without an embedder. The ladder shape is still unbuilt here and would be cheap: the decorator
already holds a working keyword index that answers with no model at all.

Two mechanisms are cheap and orthogonal to the substrate: the **no-LLM-call automatic save**
(metadata summaries cost nothing and still make a session findable later) and the
**confirm-before-write review panel**, which is the `Confirmer` seam applied to memory writes — a
place pikuri's memory capture currently writes unattended.

A third difference is in *when* recall is delivered, and it is not cosmetic. Pikuri prefetches per
turn, which is the better product — recall tracks what the conversation is currently about — but it
forecloses the system-prompt home: a re-scored block written into the prefix every turn would
invalidate the cache every turn. Per-turn recall and prefix-resident recall are mutually exclusive,
and pikuri chose the one that has to ride an injected message.
