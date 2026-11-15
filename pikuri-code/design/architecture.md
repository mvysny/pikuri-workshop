# pikuri-code — design & threat model

Audience: someone extending pikuri-code or auditing its sandbox
posture. The per-class contracts — the exact bind set, the `@raise`
conditions, the wrapped-argv shape — live in the YARD headers
({Pikuri::Code::Bash::Sandbox}, {Pikuri::Code::Bash::Sandbox::Bubblewrap},
{Pikuri::Code::Bash::Sandbox::FullFsNoNet}). This file carries the
cross-cutting *why* those headers otherwise swell with: the two-sandbox
design, each one's threat model, and the invariants that span
{Pikuri::Code::Bash} + {Pikuri::Workspace::Filesystem} +
{Pikuri::Code::ToolchainPaths} at once. In-flight notes and still-open
questions live in [`../design/ideas/coding-agent.md`](../../design/ideas/coding-agent.md).

The must-not-break half is already in this gem's [`AGENTS.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/AGENTS.md)
(**Sandbox seam**) and [`../pikuri-workspace/AGENTS.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/pikuri-workspace/AGENTS.md)
(**Workspace seam**); this file is the reasoning *behind* those
one-liners, not a second copy of them.

## Two sandboxes, opposite postures

{Pikuri::Code::Bash} runs every command through a `Sandbox#wrap(argv)`.
Three implementations, but only two real postures — `NONE` is the
identity passthrough (the `Bash.new` default and the `--no-sandbox`
opt-out); the other two are deliberate inverses:

| | {Bubblewrap} | {FullFsNoNet} |
|---|---|---|
| Filesystem | curated subset (project + toolchain + `/etc` baseline) | the whole real root, read-write |
| Network | **kept**, but its own loopback behind `pasta` (`D_sandbox_own_loopback`) | **severed** (`--unshare-net`) |
| PID / IPC / UTS | unshared (`--unshare-all`) | kept shared |
| Written for | the in-repo coding agent (`bin/pikuri-code`) | the offline OS helper (`bin/pikuri-os`) |
| On probe failure | degrades (overlay → `--ro-bind`) | **raises** — the severed net *is* the property |

Bubblewrap contains the filesystem and trusts the network; FullFsNoNet
trusts the filesystem and severs the network. Which is right follows
from what the agent's job must touch: a coding agent must
`git pull` / `mvn` / `curl` (network essential, containment cheap); an
OS helper must inspect the real host (filesystem essential, egress is
the whole risk). The class lives in pikuri-code because it's a `Bash`
sandbox; its *user* is pikuri-os (see that gem's DESIGN and the book's OS-assistant chapter).

### Sandbox is not Workspace

Two overlapping-but-distinct objects govern what bash can touch, and
keeping them separate is deliberate:

- **{Pikuri::Workspace::Workspace}** is *what the LLM observes* through
  the `Read` / `Write` / `Edit` / `Grep` / `Glob` tools, which run
  in-process as the real user.
- **Sandbox** is *what the executed bash subprocess sees*.

They overlap on project + toolchain dirs but diverge on the OS-runtime
baseline ({Bubblewrap}'s `ETC_BASELINE` — TLS certs, DNS, tz, hosts):
the LLM has no business `Read`-ing `/etc/resolv.conf`, but the `curl`
subprocess needs it. Separate objects keep each allowlist with its
rightful owner rather than fusing two different questions into one list.

## Bubblewrap: blast-radius containment, not a malware boundary

Bubblewrap composes a `bwrap` argv from the {Pikuri::Workspace::Filesystem}
plus a curated OS-runtime baseline, so the bash subprocess sees only
project + toolchain + ephemeral temp + the handful of `/etc` files
needed for a TLS/DNS/tz/hostname handshake. The exact bind list is in
the class YARD; the *design points* worth stating once:

### The toolchain overlay

`workspace.readable` dirs (the toolchain caches from
{Pikuri::Code::ToolchainPaths}) are mounted as **read-write ephemeral
overlays**: the host dir is the read-through lower, a per-session upper
under `<state dir>/overlay-<slug>/` absorbs writes. So
`gem install` / `bundle` / `mvn` / `gradle` / `cargo` / `pip` succeed
against `/usr`, `~/.rbenv`, `~/.gradle/caches`, … while the host's real
toolchain stays untouched. Writes survive across bash calls within one
session (a warm cache — the upper is a persistent dir re-mounted each
call, not a tmpfs that dies with the `bwrap` process) but never across
sessions, so a poisoned session can't propagate into the host's normal
`gradle` or a future run.

Why the mounts are *narrow* subdirs (`~/.gradle/caches`, not
`~/.gradle`) — so `gradle.properties` / `init.d` / `.credentials` never
reach the sandbox — is owned by {Pikuri::Code::ToolchainPaths}: because
the lower is the host's real file, it's the narrow *mount*, not the
write's ephemerality, that keeps secrets out of the sandbox's view.

### The environment wall

The same rule, one namespace over: {Pikuri::Code::Bash::Sandbox::EnvWall}
lets through the shell's baseline, build-tool options, the user's
`sandbox_env:` names and any path-valued variable, and the sandbox unsets
the rest in the environment `bwrap` itself starts with. `ToolchainPaths`
decides which *files* a build sees and `EnvWall` which *variables*; both
deny by default. Why only this sandbox filters, and why `--clearenv`
isn't enough: `design/decisions.md` `D_sandbox_env_wall`.

### What the overlay does NOT defend

Blast-radius containment for the subprocess, **not** a malware boundary.
Prompt injection reaching the LLM can still:

- modify project source under `project_root` (the LLM legitimately needs
  `Write` there);
- inject a malicious dependency the next build executes;
- exfiltrate over the network — the internet stays reachable so
  `git pull` / `mvn` / `curl` work;
- reach anything on the LAN, the LLM server included. Only the host's own
  `127.0.0.1` is cut, and only with `pasta` installed.

The overlay specifically prevents *cross-project* contamination via
shared `$HOME` caches — nothing more. Users needing adversarial
isolation run pikuri-code inside a VM: the VM is the outer
boundary, `bwrap` the inner (a container would share the kernel). ({Pikuri::Workspace::Filesystem::AllowAll}
is the file-tool-side counterpart.)

### Concurrency: one umbrella, serialized bwrap

Each `Bubblewrap` instance must own its overlay upper/workdir
exclusively — overlayfs returns `EBUSY` on a shared upper. The bundled
wiring guarantees it: each `Bubblewrap` mints its own state dir
({Pikuri::Paths.new_temp}) for its uppers, and `Bash` runs `bash -c` synchronously
({Pikuri::Subprocess}`#wait`) while sub-agents block their parent's
loop — so two `bwrap` invocations from one pikuri process never overlap
in time. Two pikuri-code *processes* are independent (each its own
umbrella; the shared read-only lower may be shared across mounts per
kernel docs). A downstream host that reused one `Bubblewrap` across
parallel bash tasks would collide on its own `EBUSY`; pikuri's own
wiring never does.

## FullFsNoNet: sever the egress, not the filesystem

The inverse of Bubblewrap: `--dev-bind / /` binds the entire real root
read-write, and *only* the network is unshared (`--unshare-net`). This
is the sandbox for the offline OS helper (`bin/pikuri-os`). That agent's
job is to operate the real host, so filesystem *containment* is the
wrong tool — there is deliberately no fs sandbox. The one isolation that
matters is egress: with the network namespace unshared *and the live
session's IPC sockets masked*, an injection in a file the agent reads has
nowhere to exfiltrate to. **The trifecta's egress leg is cut by the
kernel, not by a prompt** — the load-bearing invariant of the OS-helper
design. Both halves are required, and the second is the non-obvious one:
see §"The session-IPC mask" below.

Running unprivileged, `bwrap`'s user namespace maps the caller's uid to
itself, so root-owned files (`/etc/*`, another user's `$HOME`) appear
owned by an unmapped id and are *not* writable (and `/etc/shadow` stays
unreadable) — matching the OS helper's "advise, don't execute anything
privileged" rule: privileged edits need `sudo`, unavailable in the
namespace, so they route to the human.

### Why the real /dev, not bwrap's synthetic --dev

FullFsNoNet binds `--dev-bind /dev /dev` (the real device tree) where
Bubblewrap uses a synthetic `--dev` (null/zero/random/tty only). It's
redundant with `--dev-bind / /` but stated explicitly so it survives
someone narrowing the root bind — and the reason is an **error-signal**
argument, not access:

A synthetic `/dev` omits the block-device nodes (`/dev/nvme0n1`,
`/dev/sda`). With them missing, `smartctl -a /dev/nvme0n1` fails
`ENOENT` ("No such device") while `lsblk` / `/sys` still show a healthy
disk — an incoherent machine the model can't reason about, so it
retry-loops instead of escalating. With the real node present the
unprivileged open fails `EACCES` ("Permission denied"), the honest error
that says "escalate" — and here escalation *is* the answer: `sudo` is
unavailable in the namespace, so a privileged read becomes advice to the
human, matching the "advise, don't execute privileged" rule.

This is not a security regression: the root is already bound read-write,
so the synthetic `/dev` was hiding nothing an attacker couldn't
otherwise reach — it only mangled the error. (Regression-guarded by the
`refute_includes argv, '--dev'` assertion in the sandbox spec.)

**`--dev-bind`, never plain `--bind` (fixed 2026-08-06).** Both binds
above shipped as `--bind` for months, and `--bind` applies `MS_NODEV`.
The nodes stayed *visible* — `ls -l /dev/null` printed `crw-rw-rw-` —
but every `open()` failed `EACCES`, so `echo x > /dev/null` was refused
on a world-writable file. That is this section's own error-signal bug in
its worst form: not a *missing* environment but a **lying** one, where
the permission bits and the kernel's answer disagree. It surfaced on a
live "install openjdk-21" run, where the model emitted the reflexive
`2>/dev/null`, got "Permission denied", and reasoned "that's odd" —
exactly the incoherent-machine confusion the real `/dev` was chosen to
avoid. `2>/dev/null` is among the most common idioms an LLM emits, so
this was a constant tax.

`--dev-bind` grants no authority the user lacks outside the sandbox:
node permissions and the uid map still apply, so `/dev/loop0`
(`brw-rw---- root disk`) fails `EACCES` under `--dev-bind`, under
`--bind`, and in an unsandboxed shell alike — byte-identical messages.
The block-device escalation path this section rests on was therefore
*accidentally* intact before the fix (`nodev` produced the same
`EACCES` the file mode does); afterwards it holds for the stated
reason. What was actually broken was the world-accessible pseudo-device
set — `/dev/null`, `/dev/zero`, `/dev/random`, `/dev/urandom`,
`/dev/tty` — all of which an ordinary user is *supposed* to open.
Bubblewrap is unaffected: its synthetic `--dev` mounts each node with
device access.

Note the PID namespace is *not* unshared, unlike Bubblewrap's
`--unshare-all`: an OS helper must see and reason about host processes
and services, so `--proc /proc` over the bound root still shows them —
essential for `ps` / `top` / `systemctl status`. Unsharing PID would
blind them.

### The session-IPC mask

`--unshare-net` alone is **not** an egress cut on a desktop. A network
namespace binds this process tree; it says nothing about what the tree can
*ask someone else* to do — and one unix socket in `$XDG_RUNTIME_DIR` is a
general-purpose "run this outside my namespace" service. Unix sockets don't
care about network namespaces, so `--dev-bind / /` handed it over intact.
Measured on GNOME/Wayland, all three from inside the sandbox:

| Attempt | Result |
|---|---|
| `curl https://…` | `000` — severed, loopback-only netns |
| the same `curl` via `systemd-run --user` | **HTTP 200** — spawned by `systemd --user` in the host netns |
| `xdg-open x.png` (`DBusActivatable` handler) | app runs in the **host netns**, cgroup `dbus.service`, outliving `--die-with-parent` (it was never a child) |

A plain `Exec=` handler forks *inside* the sandbox instead, and is
contained — **until the app is already running**, when the
remote-instance handoff passes the URL out (cold browser: "Unable to
connect"; warm browser: the GET arrived). Containment conditional on
whether the user has their browser open is not a property to rely on.

So `SESSION_IPC_MASKS` subtracts the surface: a tmpfs over
`$XDG_RUNTIME_DIR` and `/tmp/.X11-unix`, plus a `/dev/null` mask over a
`DBUS_SESSION_BUS_ADDRESS` pointing outside both. Three notes on why it's
shaped this way:

- **Structural, not a denylist.** Blocking `xdg-open` by name would be the
  losing side of the enumeration game (`gio`, `gdbus`, `systemd-run`, five
  lines of Python on the socket are one channel) and would manufacture
  false comfort. Removing the *authority* needs no list. See
  `design/decisions.md` `D_headless_os_agent`, which also records what this costs
  (`systemctl --user`, rootless `docker`) and what survives (the system
  bus, `journalctl`, `gsettings get`).
- **Abstract sockets need no mask.** `@/tmp/.X11-unix/X0` and friends are
  scoped *by the network namespace*, already unshared — measured
  reachable from the host and `ECONNREFUSED` inside. That's what makes
  masking the filesystem paths sufficient rather than a patch.
- **Order matters.** The masks must follow `--dev-bind / /`; placed before
  it, the root bind covers them and the bus comes back. Invisible in
  review, silent under every other test, so the spec asserts the order.

The mask rides the boot probe too, so a host that refuses it (`bwrap`
cannot `mkdir` a missing runtime dir under root-owned `/run/user`) fails
at construction rather than on the first command.

### No fallback if the network can't be severed

If `bwrap` is missing, or the kernel forbids unprivileged user / network
namespaces, the constructor **raises** — it does NOT degrade to a
networked sandbox (the opposite of Bubblewrap's overlay probe, which
logs and falls back). Here the severed network *is* the security
property, so a silent networked run would void the no-egress invariant.
A host that can't unshare the network must fix the kernel setting (e.g.
`kernel.unprivileged_userns_clone`) or not run this agent there.

### What FullFsNoNet does NOT defend

`--dev-bind / /` exposes everything, including container/VM control sockets.
Unsharing the *bash process's own* network namespace does not constrain
a container the agent asks the *host daemon* to spawn — a confirmed
`docker run --network=host` would have full connectivity. The session-IPC
mask closes the *rootless* variants (their sockets live in
`$XDG_RUNTIME_DIR`) as a side effect of being structural, but the rootful
sockets under `/run` stay reachable — and stay *visible* on purpose. A user
outside the `docker` group gets an honest `EACCES` from the untouched
socket; masking it would trade that for a confusing `ENOENT` and leave the
model retry-looping over a daemon that appears to have vanished, exactly
the error-signal argument of §"Why the real /dev, not bwrap's synthetic
--dev". So this is not a malware boundary; it
severs the agent's own egress, and the guard against socket abuse is the
confirmer (`docker` / `nc` / `curl` are mutating and non-allowlisted, so
they reach the human). A hard boundary means running the whole agent
inside a container / VM.

Two further residuals, both human-gated and neither silent:

- **The system bus stays bound** — `systemctl status` needs it. A transient
  unit there is polkit-gated, and polkit raises an *authentication dialog
  on the user's desktop* (observed while testing this). That's the
  `D_no_agent_sudo` hand-off working, not a bypass: loud, and it needs the
  user's password.
- **Deferred execution via a confirmed write** — `~/.bashrc`,
  `~/.config/autostart/*.desktop`, `crontab` — runs later, outside the
  sandbox. The write confirmer shows it as a diff, which is the guard.

## Construction-time probing (loud, not on first tool call)

Both sandboxes probe `bwrap` in their constructor, so a misconfigured
host fails at boot rather than mid-conversation. The two probes differ
in exactly the way the postures differ, and that difference is
load-bearing:

- **Bubblewrap** probes with `--share-net` (its runtime posture), then —
  only when a `readable` dir would actually be overlaid — runs a *second*
  overlay probe that **degrades** to `--ro-bind` on a warning if
  overlayfs-in-userns is unavailable (Linux < 5.11).
- **FullFsNoNet** probes with `--unshare-net`, because a kernel that
  forbids unprivileged net namespaces must fail *here*, loudly. Probing
  with `--share-net` would let a host pass the check and then be unable
  to sever the network at runtime — silently voiding the whole point.

So the probes are not interchangeable: the flag under test is precisely
the property each sandbox promises. A shared probe helper would have to
be parameterized by that flag (and by raise-vs-degrade) rather than
unified away.

## Passive-command auto-approval (`PassiveCommandDetector`)

`bin/pikuri-os` runs bash confirmed-by-default: every command reaches the
human {Pikuri::Workspace::Confirmer} unless
{Pikuri::Code::Bash::PassiveCommandDetector} proves it *passive* — provably
only *observing* state (no change that persists to disk/device/remote,
nothing sent off the machine). Two clauses, both required: **non-mutating**
and **confined**. A passive verdict skips the prompt; everything else falls
through to the human. The detector is a *classifier*, not a decider — `false`
means "not provably passive, ask the human," never "reject." The per-method
contracts and the exact constant sets live in the class YARD; this section
carries the cross-cutting *why*.

**Why this is a security feature, not a convenience.** A user who has clicked
"yes" forty times has stopped reading; the injected forty-first gets
rubber-stamped. Cutting the pointless prompts (`ls`, `cat`, `grep`, `df` …) is
what keeps attention on the ones that matter — so passive auto-approval is the
conservative complement to blanket `--yolo` ({Confirmer::AutoApprove}), and the
two stay independent, composable axes rather than one tangled decorator.
Keeping content classification *out* of the confirmer is deliberate: a
confirmer's one job is to resolve a request, never to parse a command.

### Two reasons a command isn't passive — and they differ

- **Mutation and egress fail by definition.** `rm`, `git push`, a `curl` GET,
  `smartctl -t` — each fails one of the two clauses.
- **Process execution and privilege escalation are *abstained*, not failed.**
  An `exec` (a spawned `$BROWSER`, `rg --pre`) makes the child's effects
  *undecidable*; `sudo` changes the process's *authority*, not the world. So
  `sudo dmesg` is genuinely passive — it only reads — and pikuri-os still routes
  it to the human, but via a *separate* sudo policy, not because this classifier
  calls it active. A future vetted sudo-read path would reuse the verdict
  unchanged.

### Four recovery strategies, and the residual each accepts

The classifier starts from a short **allowlist of binaries passive in *every*
argument form** (`PASSIVE_BINARIES`: `ls` `cat` `grep` `df` …). Metacharacter-free
is necessary but not sufficient — `find . -delete`, `sort -o f`, `dd`, `tee`,
`shred`, `date -s` are all single, clean, *destructive* invocations — so the list
holds only binaries with no mutating or escaping form in any argument,
independent of privilege (the guarantee mustn't rely on running non-root). That
excludes `find` (`-delete`/`-exec`), `env`/`command` (run other programs),
`date`/`hostname` (set-forms), and `xxd` (`xxd in out` writes `out` — a write
with no flag to deny, so unrecoverable; `od`/`hexdump` cover read-only hex).
Mixed-mode binaries whose *read* forms are passive are recovered separately, four
ways:

| Strategy | Families | Residual accepted |
|---|---|---|
| **Subcommand gate** — a known query verb must appear *immediately* after the binary (refuses a leading `--admindir` / `-o Foo=bar` / `--root` global option or config injection) | `dpkg` `apt` `apt-cache` `systemctl` `nvme`, and git under `allow_git:` | none — an unknown verb abstains |
| **Flag denylist** — passive iff no argument names an enumerated mutating/exec flag | `dmesg` `journalctl` `man` `rg` `file` | a *future* mutating/exec flag this set doesn't yet name |
| **Flag allowlist** — passive iff *every* `-`-flag is a known read flag | `smartctl` | none — an unknown flag abstains |
| **Glob fast path** — a command the strict parse rejects *solely* for an unquoted glob passes iff every segment is a bare `PASSIVE_BINARIES` invocation | pure allowlist only | none |

The flag-denylist row is **the one deviation from "never call an active command
passive"**: its residual is a mutating/exec flag not yet enumerated. Accepted
because the surfaces are small and stable (util-linux / systemd / man-db /
ripgrep); an allowlist would close it at the cost of rejecting every *new read*
flag — the inferior trade, same residual shape as git's `--output` check. The
allowlist families (`PASSIVE_BINARIES`, the subcommand-gated set, `smartctl`)
have no such residual: an unrecognized token always abstains toward the human.
The glob fast path admits *only* the pure allowlist because those binaries have
no mutating/exec/output-file form in *any* argument — so a glob expanding into a
`-flag`-looking filename can't grow teeth; the flag-classified families are
ineligible, since a post-expansion glob would defeat spelling-based
classification (a planted `-C`/`--pre` file smuggled past the denylist).

The per-family nuggets behind those rows (why each is unconditional, what each
excludes) live on the constants and predicates in the class YARD — e.g. `apt`'s
pre/post-invoke hooks fire only on mutating verbs and `systemctl`'s pager spawns
only on a tty (which Bash's piped stdout is not), so both query subsets are
*unconditional*; `man -H` launches `$BROWSER` (exec *and* egress); `smartctl -l`
is value-sensitive (`-l selective,S-E` *sets* a span) so it's lumped out
wholesale; `nvme`'s read-verb set started deliberately minimal.

### The soundness hinge: true de-quoted words

{Pikuri::Code::Bash::Tokenizer} hands the classifiers the *true* de-quoted word
(`--clear`, not a `--_clear` placeholder), which is what makes the denylist /
prefix checks sound. The lexer does genuine shell quote-removal — the marks are
dropped and the interior kept verbatim — rather than the cheap shortcut of
`gsub`-blanking `'...'` to a placeholder (`--''clear` → `--_clear`). That
shortcut diverges from real quote-removal and smuggles an analyzer-only byte
into a flag, so a `dmesg` denylist or a git `--output` check would miss the
mutating flag the shell still runs. Real quote-removal collapses `--''clear` to
`--clear`, so the spelling the classifier sees is the spelling bash runs.

Why the two classifier shapes need this to *different* degrees:

- An **exact-match allowlist** (a binary name, a subcommand verb) fails *safe*
  under quote injection even with a naive placeholder — the smuggled byte just
  breaks the match, so the command abstains toward the human.
- A **denylist / prefix** check fails *open* unless it sees the de-quoted word —
  the smuggled byte makes a mutating flag *not* match the denylist, and the
  command is wrongly called passive.

Real quote-removal makes both kinds sound. The failure mode is always "asks the
human too often," never "called something active passive." The lexer's own
mechanics — which double-quote interiors it will decode vs. abstain on
({Tokenizer::DQUOTE_LIVE}), why the escape-blind segment splitter can't
mis-approve, why `!` isn't gated inside `bash -c` — live in the
{Pikuri::Code::Bash::Tokenizer} YARD.

### Residuals the allowlist does NOT close

- **PATH hijacking.** A bare `ls` resolves via `$PATH`, so a planted `~/bin/ls`
  earlier in `PATH` runs instead. Planting requires a prior *confirmed* write,
  and altering `PATH` in the same command needs `export`/`;` (metacharacters →
  not passive), so this is not a one-command bypass. Documented, accepted for v1.
  (`rg`'s `$RIPGREP_CONFIG_PATH` `--pre` and any env-var vector are the same
  class — they already presuppose control of the agent's environment.)

### Passive git needs Bash's hardening (`allow_git:`, opt-in, default off)

Everything above is unconditional. `allow_git: true` additionally treats the
passive git verbs (`status`/`diff`/`log`/`show` …, with `--cached` and friends
free) as passive. But even a bare `git diff` executes whatever the repo config
directs (`core.fsmonitor`, `diff.*.textconv`) — an *active* vector — so calling
it passive is sound only because containment lives one layer up, in
{Pikuri::Code::Bash}: `Bash::GIT_HARDENING` forces `core.fsmonitor=false` (and
`core.pager=cat`) via the `GIT_CONFIG_*` environment, overriding a hostile
repo-local `.git/config` and closing the headline vector (`core.fsmonitor =
rm -rf ~`, which fires on a plain `git status`).

The residual the caller accepts is narrow: diff-driver execution
(`diff.external`, a `.gitattributes`-selected `diff.<driver>.command` /
`.textconv`), which the environment can't disable cleanly. A plain `git clone`
never copies the remote's config, so that residual is confined to a repo whose
`.git/config` an attacker wrote. `bin/pikuri-code` gates `allow_git:` behind a
startup "trust this repo?" prompt; `pikuri-os` enables it unconditionally (its
agent roams the whole disk — no single repo to vouch for). Hardening does NOT
license *destructive* git, so the verb set excludes every mutating form and
{PassiveCommandDetector#passive_git?} additionally refuses inline config /
repo-redirection / `--output`.
