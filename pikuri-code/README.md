# pikuri-code

In-repo coding-agent gem for the
[pikuri](https://github.com/mvysny/pikuri) AI-assistant toolkit,
in the spirit of Claude Code, opencode, or pi-code — but kept
deliberately small so you can read the sources in an evening.

Adds the shell-and-dev-loop layer on top of
[`pikuri-workspace`](https://github.com/mvysny/pikuri/blob/master/pikuri-workspace/README.md)'s filesystem
tools:
- `Pikuri::Code::Bash` — runs commands via the
  `Pikuri::Subprocess.spawn` chokepoint with `Confirmer` gating,
  optionally wrapped in a `Pikuri::Code::Bash::Sandbox::Bubblewrap`
  filesystem sandbox.
- `bin/pikuri-code` — the interactive coding-agent binary that
  wires file + shell + web tools into an agent rooted at the
  current working directory.

Wire-by-wire it's the same `Pikuri::Agent` as `pikuri-chat`
(from [`pikuri-core`](https://github.com/mvysny/pikuri/blob/master/pikuri-core/README.md)), with a different
system prompt and a different toolset: `read`, `write`, `edit`,
`grep`, `glob`, `bash`, plus the web tools and the calculator.
Sub-agents are enabled, and any
[Agent Skills](https://agentskills.io/specification) discovered
under `.pikuri/skills`, `.claude/skills`, or `.agents/skills`
(project or home) get exposed to the model on demand. An
in-memory task list (`task_create` / `task_in_progress` /
`task_completed` / `task_delete`) is also wired in — see
[`pikuri-tasks`](../pikuri-tasks/README.md) for the rationale.

## Install

```ruby
# Gemfile
gem 'pikuri-code'
```

Pulls in `pikuri-core` + `pikuri-workspace` + `pikuri-subagents` transitively.

## Usage

Run from the root of the repo you want it to work in:

```sh
cd ~/code/your-project
/path/to/pikuri/pikuri-code/bin/pikuri-code
```

You'll land in a REPL — type a request at the `>` prompt, hit
enter, and the agent will start reading files, running commands,
and editing code to satisfy it. Ctrl+D (or Ctrl+C) exits. You
can also pass an initial message on the command line:

```sh
/path/to/pikuri/pikuri-code/bin/pikuri-code "find the failing spec and fix it"
```

The first time the agent wants to write a file or run a shell
command, it prompts you on the terminal
(`[y] approve  [n] reject  [r] redirect`). Read what
it's about to do before you say yes. Two instruction files are
prepended to the system prompt as context when present: your
user-wide `~/.claude/AGENTS.md` first, then a project `AGENTS.md`
or `AGENTS.md` at the workspace root (`AGENTS.md` wins when both
exist) — so a project's rules refine your user-wide ones.

## Security: this is a tech demo, treat it accordingly

**Do not run `pikuri-code` against a sensitive checkout on a
machine that holds secrets you care about.** It is a working demo
of the coding-agent shape, *not* a hardened tool. The threat
model has glaring holes:

- **The sandbox walls off your home, not this project or the
  network.** `bash` runs inside Bubblewrap by default: it sees the
  workspace, the folders you add with `--readable` / `--writable`
  (readable ones, your toolchain caches among them, as throwaway
  overlays) and a small OS baseline, so `~/.ssh`, `~/.aws` and your
  other projects don't exist in there. It gets only the environment
  variables a build needs; the banner lists what it withholds. The
  network stays open, though: an LLM that's been prompt-injected
  (by a malicious README it scraped, a poisoned dependency, a
  crafted file in the repo) can still ask to `curl` this project's
  `.env` to a stranger, and *you* reading the confirmation prompt
  is what stands in the way. pikuri's own file tools are held to
  the same workspace. `--no-sandbox` drops the wall, and `bash`
  then reaches everything your user can.
- **`--yolo` turns every wall off.** No sandbox, no prompts, and
  the file tools open to the whole disk. That flag exists for use
  *inside* a disposable container or VM; on your laptop it hands
  the model your user account. Don't.
- **Network tools fetch arbitrary URLs.** `web_search`,
  `web_scrape`, and `fetch` are happy to pull whatever the
  model asks for, and the content of those pages then becomes
  part of the conversation — classic indirect prompt-injection
  surface.
- **No audit log of approved actions.** Once you approve a
  `bash` command it runs; there's no separate record beyond
  your scrollback.

In short: the sandbox keeps `bash` out of the rest of your home,
not out of this project or off the network. Run it attended, on a
repo you trust, and read each prompt. For `--yolo`, unattended
runs or a repo you don't trust, run the whole of `pikuri-code`
inside a VM — anywhere you'd be fine with a stranger having a
shell ([`SECURITY.md`](../SECURITY.md)).

## Further reading

- **Narrative walkthrough:** [the shell chapter](../book/shell.md) starts the agent bare (the
  workspace, the cage, the human gate);
  [the coding agent, completed](../book/code.md) shows the full wiring block and accounts for
  what each defense buys and where it stops.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-code> (once published), or run
  `bundle exec yard` in this directory for a local copy.
