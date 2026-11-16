# The coding agent, completed

[The shell chapter](shell.md) started `pikuri-code` bare: the file tools, `bash`, the
Bubblewrap cage, the human gate. Every chapter since bolted one piece onto it: MCP servers,
skills and slash commands, language intelligence, a task list. This one puts it back together
and then does the accounting.

The accounting is the point. pikuri ends on
[a secretary](https://codeberg.org/mvysny/pikuri/src/branch/master/bin/pikuri-secretary) that
reaches for all three trifecta legs and weakens each by construction: search hands back
snippets, mail leaves only through a Thunderbird draft you send yourself, notes go to one folder
with a diff you approve. A coding agent can't weaken its legs that way. It reads files somebody
else wrote (untrusted), in a project you may mind leaking (private), with a shell that reaches
the internet (egress), and a weaker version of any of the three is a worse coding agent. So it
holds all three, at full strength, by design.
What's left is to say, for each defense the book built, what it buys and where it stops, and
to be honest about the one wall that closes what the others can't.

## The whole wiring

The `Agent.new` block in `bin/pikuri-code`, stripped of comments:

```ruby
agent = Pikuri::Agent.new(transport: ..., system_prompt: ..., cancellable: ...) do |c|
  c.add_listener Pikuri::Agent::Listener::Terminal.new
  c.add_listener Pikuri::Agent::Listener::TokenLog.new

  c.add_extension Pikuri::Workspace::Extension.new(filesystem: plan_mode.guard(filesystem), confirmer:,
                                                   confirm_all_writes: false)
  c.add_tool Pikuri::Tool::CALCULATOR
  c.add_sub_agent_tool Pikuri::Web::Search.from_h(examples_config['search'])
  c.add_sub_agent_tool Pikuri::Web::SCRAPE
  c.add_sub_agent_tool Pikuri::Web::FETCH
  c.add_extension Pikuri::Code::Extension.new(filesystem:, confirmer:, passive_detector:,
                                              sandbox:, plan_mode:)
  c.add_extension skill_extension
  c.add_extension Pikuri::Command::Extension.new(registry: command_registry)
  c.add_extension Pikuri::Tasks::Extension.new
  c.add_extension Pikuri::Mcp::Extension.new(registry: mcp_registry,
                                             synthesize_descriptions: true,
                                             verify_mcp_servers: true)
  c.add_extension Pikuri::Lsp::Extension.new(registry: lsp_registry, filesystem:)
  c.add_extension Pikuri::SubAgent::Extension.new(
    personas: [Pikuri::SubAgent::FILE_MINER, Pikuri::SubAgent::RESEARCHER]
  )
  c.add_extension Pikuri::Code::GitRepoResearcher.new
end
```

Nearly every line is an extension, and each came from a chapter:

| Extension | Adds | Met in |
|---|---|---|
| `Workspace::Extension` | `read` `grep` `glob` `file_list` `edit` `write`, and the read-before-edit record they share | [the shell chapter](shell.md) |
| `Code::Extension` | `bash` in its cage, and plan mode | [the shell chapter](shell.md); plan mode below |
| `skill_extension` | the `skill` tool and its catalog | [Agent Skills](skills.md) |
| `Command::Extension` | nothing the model sees: slash commands are yours to type, so this only declares their untrusted bytes to the trifecta report | [Agent Skills](skills.md) |
| `Tasks::Extension` | the four `task_*` tools | [Task tracking](tasks.md) |
| `Mcp::Extension` | `mcp_connect` and whatever the servers bring | [Your first MCP server](mcp.md), [MCPs revisited](mcp-revisited.md) |
| `Lsp::Extension` | `lsp`, when the config names a server | [Language intelligence](lsp.md) |
| `SubAgent::Extension` | the `agent` tool and its two personas | pikuri's [sub-agents chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/subagents.md); below |
| `Code::GitRepoResearcher` | `git_repo_research`, a child agent that clones a repo and reads it | below |

Three things hold it together.

**A few shared objects, threaded by hand.** `filesystem` is the one answer to "what may this
agent touch": the file tools wrap it with their read record, `bash`'s cage binds exactly its
roots, `lsp` reads through it. `confirmer` is the one human gate, asked by `write`, `bash` and
plan mode. `plan_mode` is one flag that `edit` and `write` obey, through the filesystem it
guards, flipped by the model's plan tools and by your `/plan`. Build each once, hand the same
instance to everyone who needs it, and the pieces agree without knowing about each other.

**Two tool pools.** `add_tool` puts a tool in front of the model; `add_sub_agent_tool` puts it
only where a persona that names it can reach it. The web tools sit in the second pool, so a
scraped page can only land in a child with no `bash` to hijack. `git_clone` sits in neither: only
`git_repo_research`'s child ever holds one.

**Order, in one place.** `SubAgent::Extension#configure` checks every persona's tool names
against what's registered so far, and `GitRepoResearcher` checks for the web tools the same way,
so both come after them. Move one up and boot fails with an `ArgumentError` naming the missing
tool, which is the point: a wiring bug found at boot, not on the first delegation.

The block isn't all of the wiring, though. Before it, the bin asks up to three questions and
checks one thing, each feeding a grade rather than a gate: does this project hold anything you'd
mind leaking (the private leg, in pikuri's
[trifecta chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/trifecta-detector.md));
do its skill and command files match a commit, and did you write them (the
[skills chapter](skills.md)); do you control its git config (the
[shell chapter](shell.md#even-git-status-runs-code)).

## Sub-agents: untrusted bytes away from the shell

`FILE_MINER` is pikuri's read-only recon persona: `file_list`, `read`, `grep`, `glob`, nothing
else, and a contract to answer in one paragraph with `path:line` citations. A coding parent hands
it a lookup ("find every spec that mentions `Cancellable` and say what they cover") so that the
twenty files it reads along the way land in the child's context, not the parent's. And a file
that tells it to `curl` something finds no shell to do it with.

Whether the parent delegates is the model's call, though, the same as whether it plans with the
task list. Asked exactly that question in this repository, Ornith-1.5 didn't delegate: it ran
`grep` twice, then `read` ten spec files itself, and its context grew from 15.7k tokens to 24.2k
before it answered. A correct answer, paid for out of the parent's window. The persona is in the
prompt, described; nothing makes the model reach for it.

`git_repo_research` is the same move for a question a web page answers badly: "how does
library X actually do Y?". Its child's tools are `git_clone`, the four read tools and the web
tools, all over a throwaway folder of its own: a fresh temporary directory, a `git clone --depth 1
--no-recurse-submodules` over HTTP(S) into it, run inside the same Bubblewrap cage as `bash`, and
the directory deleted when the child finishes. A README in that clone saying "read
`~/.ssh/id_rsa`" reaches a child whose `read` can't resolve anything outside the temp directory
and which has no `bash`, `write` or `edit` to act with. What comes back to the parent is a
paragraph with citations.

It is a tool of its own rather than a third persona because a persona's tools are the parent's
own instances: a persona naming `read` would get the `read` that sees your project, and the
separation would be gone. So `Code::GitRepoResearcher` builds its child itself, with file tools
bound to the throwaway folder, the way `SubAgent::Extension` builds a persona's.

That's privilege separation, and it is real: the children hold the untrusted bytes without the
tools that would make them dangerous. It doesn't move the parent, though. The parent still reads
your project's files (somebody else's bytes, if it's a dependency, a vendored library or a
fetched branch) and still has `bash` with the internet. Sub-agents keep the *web* away from the
shell, not the trifecta.

## Plan mode, and what approving a plan buys

`/plan`, or the model's own `enter_plan_mode`, flips the shared `plan_mode` flag: `edit` and
`write` refuse until it's off, because the filesystem they write through, `plan_mode.guard`,
refuses every write path while it's on. The model researches, then calls `exit_plan_mode` with a plan,
and you're asked "Approve this plan? (approving exits plan mode and lets the agent edit
files)". Yes, and it implements.

It's tempting to read that as a security feature: approve one plan instead of forty commands.
It isn't one, for two reasons in the code. The flag gates `edit` and `write` only, never
`bash` (`Pikuri::Code::PlanMode` says so in as many words): in plan mode a shell command
still runs, behind its own prompt. And the plan is prose. Nothing binds what the agent does next
to what it wrote; approving the plan approves an *intent*, the same way approving `curl`
approved one in [the shell chapter](shell.md#the-human-gate). After a yes, every `write`
overwrite and every non-passive command still asks, because nothing else could hold the agent to
its plan. Plan mode is for alignment, which is worth a lot. It isn't a gate.

## What it doesn't have: memory

[The memories chapter](memories.md) gave an agent automatic memory and spent a whole argument on
*which* agents can afford it: one that stores what it reads lets an injection survive the
session, so the store belongs on an agent that can't send anything out. Run the argument
backwards and it lands here. The coding agent reads untrusted bytes every turn and has egress,
so a memory it fills by itself would let one poisoned README come back next week, already
trusted, in a session that never saw the README. `pikuri-code` doesn't wire `pikuri-memory`. A
project's `AGENTS.md`, which you write and review and commit, is its memory instead.

## The accounting

Answer "yes" to the first boot question and the banner says what this chapter is about:

```
[TRIFECTA: HARD] pikuri-code — private(read, grep, glob, file_list, bash, lsp)
  + untrusted(read, grep, glob, file_list, bash, lsp) + egress(bash).
  An injection in what this agent reads can drive an exfiltration. …
```

Every defense in the book, against that verdict:

| Defense | What it buys | Where it stops |
|---|---|---|
| **The workspace** ([shell](shell.md)) | The file tools reach the project, your toolchains and caches, the skill folders; not `~/.ssh`, not your other projects. | The project itself, `.env` included. And `read` reaches `~/.m2`, `~/.cargo`, other people's bytes, so its untrusted leg is real. |
| **The cage** ([shell](shell.md#the-cage-what-bash-sees)) | `bash` sees the same roots, with toolchain writes in throwaway overlays; inherited secrets withheld from its environment; with `pasta`, a loopback of its own, so the host's local services don't answer. | The internet and the LAN are open. The kernel is shared. It cages `bash` and `git_clone`, nothing else. |
| **The human gate** ([shell](shell.md#the-human-gate)) | `write` asks before overwriting a file that differs; `bash` asks before every command it can't prove passive; plan approval. | `edit`, and `write` to a new file, never ask: in-project edits are the job, and git is the undo. The gate is attention, and it approves intents. |
| **The passive-command detector** ([shell](shell.md#confirmation-fatigue-the-passive-command-detector)) | `ls`, `grep`, `ps` and (after you vouch for the git config) read-only `git` stop prompting. | It can never approve a command that runs project code, which is the next section. |
| **Sub-agents** (above) | Scraped pages and cloned repos land in children with no shell. | The parent keeps all three legs anyway. |
| **The skills check** ([skills](skills.md#what-a-skill-can-reach-and-where-it-stops)) | A bundle no commit vouches for is graded untrusted, unasked. | A grade, not a gate; a skill's scripts run through `bash`, in the cage, no further. |
| **MCP in a box** ([MCPs revisited](mcp-revisited.md)) | A stranger's server in a container with no capabilities, its token from the config file, narrowed to one host behind a proxy. | A container shares your kernel; a token does everything it's scoped for. |
| **Language servers** ([language intelligence](lsp.md#the-server-itself-is-in-no-cage)) | Nothing spawns until a call needs it, and only servers your config names. | The server itself is in no cage, and ruby-lsp evaluates your `Gemfile` as you. |
| **The trifecta banner** (pikuri's [trifecta chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/trifecta-detector.md)) | Says, at boot, which legs are present and where from. | Blocks nothing, by design. |

And what none of them touch:

- **The project is inside the radius.** `edit` reaches `.git/hooks`, which run the next time
  *you* commit, outside any cage; and the build files, which run the next time anyone builds.
- **The injection chain itself.** A file the agent reads can carry instructions it follows.
  Every row above shrinks what following them can do; none stops the following.
- **No audit log.** What ran is in your scrollback and nowhere else.

## The gate runs out on `bundle exec rspec`

The coding agent's daily loop is: edit, run the tests, read the failure, edit again. "Run the
tests" is `bundle exec rspec`, `mvn test`, `npm test`: a command that runs the project's code,
which the agent just changed. The passive-command detector can never approve one of those,
because nothing about `bundle exec rspec` is observe-only: it runs whatever is in `spec/`, and the
agent wrote some of `spec/` two turns ago. So every test run asks.

You can read every one of those prompts, and you should. But be honest about what reading it
checks: the command is the same every time, and what changed is the code under it, which the
prompt doesn't show. After the twentieth identical `bundle exec rspec`, a yes is a reflex. That's
the moment people reach for `--no-confirm`, and it's the right instinct in the wrong place.
Attended work on your host is Bubblewrap plus the gate, with the gate understood as what it is.
Not asking at all is fine too, in the one place where it's safe:

## Lifting the cage: the outer VM

`--yolo` (no cage, no gate, file tools open to the whole disk bar a short credential list),
unattended runs, and a repository you don't trust all belong inside a virtual machine wrapped
around the whole process. The workshop doesn't ship one: you bring it, because it has to hold
your toolchain. The banner checks for one (`systemd-detect-virt --vm`) when a cage comes off,
and says in red when it isn't there.

**What the VM adds.** Every wall so far ran on your kernel and covered one child: the cage
covers `bash`, a container covers one MCP server, and pikuri's own process, its file tools and
its language servers ran as you on your host. A VM covers all of it at once, with a kernel of
its own:

- **A bug is bounded.** A path escape in the workspace, a hostile `build.gradle` evaluated by a
  language server, a kernel exploit from inside the cage: each lands in the VM.
- **Your other files aren't there.** Only the project you copied or mounted in, and whatever
  else you put in the VM on purpose.
- **Egress becomes shapeable a layer down.** The hypervisor's network is yours to cut to "the
  registries, the git remote and the LLM", which no in-process allowlist does yet.
- **Recovery is a snapshot.** Something went wrong; revert the VM.

**Inside the VM, containers are fine again.** On your host,
[MCPs revisited](mcp-revisited.md) put each server in a box and warned about the docker socket,
which is root on whatever runs the daemon. Inside a VM, that's the VM's root. An escape from a
container, or a sibling started through the socket, lands in the VM, which is the wall you
already accepted. So the container recipes from the MCP chapters work unchanged inside it, and
the Docker-in-Docker warnings that apply to an outer *container* don't apply here.

**What still bites inside.**

- **The project is mounted in.** An injection can still leak *this* project's `.env` through
  whatever egress the VM has. The VM bounds your machine's exposure, not the project's.
- **Tokens keep their blast radius.** A GitHub token works from inside any wall. And under
  `--yolo` the file tools can read the config file that holds it (the credential denylist
  covers `~/.ssh` and friends, not `~/.pikuri-examples-config.yaml`), so put in the VM only the
  tokens you'd hand the agent.
- **The LAN is the VM's network too.** On the box this book was written on, the LLM server sat
  on the hypervisor's bridge, reachable from inside. Cut what the agent doesn't need.
- **Keep the cage on when you're watching.** Inside a VM, Bubblewrap and the gate still keep
  the agent off the VM's own secrets and in front of your eyes. The VM is what makes switching
  them *off* safe, not a reason to.

**An outer container is the weaker version.** Wrapping the process in Docker instead gets you
the filesystem half (your other files aren't there) and none of the kernel half: an escape lands
on your host. And the tempting ways to run MCP containers inside it, the host's docker socket
bind-mounted in or a `--privileged` daemon, each hand the agent root-equivalent access to your
machine. If a container is what you have, run the MCP servers as plain processes inside it,
pinned in its image, and treat it as a better cage, not a wall.

**What it costs.** The VM needs your whole toolchain: the language runtimes, the build tools,
the language servers you use, the caches (or the patience to refill them), and file ownership
that matches between the VM and a mounted project. It's a second development machine to keep
current, which is why the attended default stays on your host. If you already develop inside a
VM, the cost is zero and `--yolo` there is a reasonable way to work.

## What the book built

Ten chapters, one agent. pikuri's secretary is safe by construction: read its wiring and you
can see each leg weakened before an injection gets to use it. This one can't be, and every
chapter here said so in its last section. What it has instead is a stack of walls you can name,
each with a measured edge: the workspace, the cage with its environment and its loopback, the
gate and what it can't see, the boxes around MCP servers, the one around the web. And outside
them all, the one that closes what they can't, a VM, which you bring.

From here, the sources read directly. [`SECURITY.md`](../SECURITY.md) is the workshop's threat
model in one place, with every spot where the promise and the code disagree;
`design/decisions.md` is why each wall is shaped the way it is; and each gem's
`design/architecture.md` is the measurements its code rests on. Start with `pikuri-code`'s.
