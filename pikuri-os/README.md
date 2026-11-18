# pikuri-os

Offline Linux/OS helper agent + OS-integration tools for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

`pikuri-os` is the home of `bin/pikuri-os`: a single, local,
**network-severed** agent that understands and operates the host OS —
answer questions about the machine, find and open files, read logs and
explain errors, advise on configuration. It is the federation's
privacy-first `@os` member shipped as a standalone single agent (walked
through in [the guide's OS-assistant chapter](../book/os-assistant.md); the
cross-class rationale is [`design/architecture.md`](design/architecture.md)).

Posture (the load-bearing parts):

- **Egress severed at the kernel.** Bash runs in a full-filesystem,
  net-isolated sandbox (the inverse of the coding agent's networked
  one), so the trifecta's exfiltration leg is gone by construction —
  not by a prompt.
- **Every mutation confirmed.** `Bash`/`Write`/`Edit` route through the
  confirmer; a conservative deterministic auto-confirmer waves through
  only provably-read-only commands.
- **Advise, don't execute, anything privileged or networked.** Anything
  needing `sudo` or the network is handed to the user to run.
- **Memory is a single `MACHINE.md`**, not mem0 — an `AGENTS.md` for this
  host, appended to the system prompt at boot and editable through the
  confirmed write path.

**Opt-in web research.** `--with-internet` enables web access, but
quarantined: `web_search` / `web_scrape` / `fetch` live inside an isolated
`RESEARCHER` sub-agent that has the web tools but **no filesystem** —
reached via the `agent` tool. The main agent holds **no direct web
tool**, so it has zero unconfirmed egress; you approve each research task
before it runs (the human, not the model, authors what leaves the
machine), and the researcher — having no private data — can at worst leak
that approved task plus the public pages it read. This is a *separate*
network boundary from the bash sandbox, which **stays kernel-severed
regardless**. Off by default; the agent stays networkless until you pass
the flag. See [`design/ideas/more-confirmers.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/design/ideas/more-confirmers.md)
for the harder pieces still deferred.

**Target platform:** Ubuntu 26.04 LTS or newer, GNOME desktop.

Depends on `pikuri-core` (Agent + Tool framework), `pikuri-workspace`
(file tools + confirmer), `pikuri-code` (Bash + sandbox), and
`pikuri-fileindex` (search over the desktop's file index).
Deliberately **not** `pikuri-mcp` / `pikuri-memory` / `pikuri-vectordb`
— severing those keeps the no-egress, audit-first posture honest.
