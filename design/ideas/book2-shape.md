# Book 2's shape: ending on a simple coding agent

Status: **running order agreed; chapter-by-chapter rewrite at eight of ten chapters (shell,
OS assistant, memories, first MCP server, MCPs revisited, skills, wire, language
intelligence). Next: task tracking** (see "Carried forward" below). Carried over from pikuri's
`pikuri-workshop.md` idea, which deferred it until this repo existed. `book/README.md` now
lists the chapters in the order below; the ones not yet revisited moved here as they were, so
their "What's next" links still follow pikuri's old order.

`Q_book2_shape`: book 2 ends on **a simple coding agent** (`pikuri-code`), the way pikuri's
book ends on a plain CLI personal assistant (`bin/pikuri-secretary`). The two climaxes pair
up: pikuri's is broken by construction; the workshop's is the agent people actually run, which
can't be, because it holds all three legs at full strength. So its chapter is about what each
defense (the sandbox, the confirmer, the passive-command detector) buys and where it stops,
which absorbs most of `security-revisited.md`.

## Bare first, completed last

`pikuri-code` can't *first appear* in the climax: `skills.md`, `mcp-revisited.md`, `lsp.md`
and `tasks.md` all wire into it or assume it exists. So the shell chapter starts a **bare**
`pikuri-code` (a shell, its cage, the file tools), each middle chapter bolts one piece onto it,
and the climax is the **completed** agent: assembled, then accounted for. That keeps the pairing
with the secretary and needs no per-chapter demo agent. `memories.md` and `wire.md` don't lean
on `pikuri-code` and need no change for this.

## The VM is the outer wall, not a second sandbox

One bash sandbox, Bubblewrap, stated honestly with its limits; lifting them (`--yolo`,
unattended runs, a repo you don't trust) means running the whole process inside a VM. No VM
implementation of the `Sandbox` seam. The promise in `AGENTS.md` says so.

What that does to the book:

- The shell chapter opens on Bubblewrap; book 2 asks for no VM before the climax.
- Every middle chapter's "where it stops" ends the same way. Skills' scripts, MCP servers
  in Docker on a shared kernel, and language servers evaluating a hostile `build.gradle` on
  your host are each closed by one wall: the VM.
- The climax's confirmer story runs out on `bundle exec rspec`. The passive-command
  detector can never approve a command that runs project code, which is the coding agent's
  daily loop (`bash-confirmer.md`). The VM is what makes not asking safe: attended means
  Bubblewrap plus the confirmer; `--yolo` or unattended means the VM.
- `security-revisited.md`'s outer-Docker section becomes an outer-VM section. Docker inside
  the VM is fine, since an escape lands in the VM, so the Docker-in-Docker warnings mostly
  go; outer Docker stays as the weaker option, on a shared kernel.
- A boot check that refuses or loudly warns on `--yolo` / `--no-sandbox` outside a VM would
  back the promise in code; it is already an entry in `security-open-questions.md`.

## Running order

1. **The shell and its cage**: bare `pikuri-code`, Bubblewrap, the sandbox seam. Harvests
   `code.md`'s sandbox half and `os-assistant.md` Part 1's seam introduction.
2. **The OS assistant**: the same seams, the opposite cut (`FullFsNoNet`). Its point is your
   host, so on the host its cage stays on; `--yolo` is for a VM, to compare how it feels.
3. **Memories**: mem0, automatic capture on a no-egress agent.
4. **Your first MCP server.**
5. **MCPs revisited.**
6. **Skills**: after MCP, since "why a skill needs a trigger and an MCP server doesn't"
   needs MCP already met.
7. **The wire chapter**: a debugging interlude, right after skills because its motivating bug
   is the withheld-skills injection. The one chapter not about power and its cage.
8. **Language intelligence.**
9. **Task tracking**: a short chapter, not folded into the climax. The climax is already
   `code.md`'s other half plus `security-revisited.md`, and tasks carries its own lesson
   ("the training prior always wins").
10. **The coding agent, completed**: the climax.

## How each chapter is revisited

In running order, one chapter per commit:

1. **Audit**: the chapter against its bin and the code it describes; what's wrong, stale, or
   badly illustrated by the bin.
2. **Decide**: a short findings list goes to the owner, each marked text-fix or code-fix.
3. **Rewrite + code**: the chapter, the bin, specs where code changes, `rake check`.
4. **Commit**: with the chapter's "What's next", its `book/README.md` line, and inbound links.
   Grep finished chapters for anything a code change touched.

Each finished chapter strikes its part of this file; after the climax the file graduates.

Habits that paid off on the first three chapters:

- **Run, don't just read.** Boot the bin (`< /dev/null` skips the TTY prompts and prints the
  trifecta report), probe the sandbox directly (`Code::Bash.run` with `AUTO_APPROVE`), bring
  a docker stack up and test from inside it. Each chapter had at least one claim the code
  contradicted, and two had a security gap only a run showed.
- **Check pikuri's book before renaming or cutting.** pikuri's chapters link into this repo
  (`~/work/my/pikuri/book`, `grep pikuri-workshop/blob`); they link files, plus one anchor.
- **Prefer the book's own question over the old text.** "What can this cage reach, and
  where does it stop?" found the mem0 store's open network, which the chapter never asked.
- **The dev box has no `socat`** and the llama.cpp router isn't always up: say what went
  untested rather than skip the run. The LLM URL is in `~/.pikuri-examples-config.yaml`, not
  always `localhost:8080`.
- **Podman over docker when installed**, in commands, chapters and bins (the owner's call);
  docker stays the fallback.
- **Read an upstream Dockerfile before building it.** Open Library's re-cloned `main` inside
  the build, so "read the source, then build" was false; the workshop now ships its own
  Containerfile.

## Progress

| # | Chapter | Source files | State |
|---|---|---|---|
| 1 | The shell and its cage | `shell.md` (from `code.md`'s first half, `os-assistant.md` Part 1 seams) | done, `828ad36` |
| 2 | The OS assistant | `os-assistant.md` | done, `d660655` |
| 3 | Memories | `memories.md` | done, `7932dc7`; end-to-end recall untested |
| 4 | Your first MCP server | `mcp.md` | done; verifier rejection path untested |
| 5 | MCPs revisited | `mcp-revisited.md` | done; headed Playwright vs. a desktop, dummy iface, docker untested |
| 6 | Skills | `skills.md` | done; the TTY trust prompt after a clean git check untested |
| 7 | The wire | `wire.md` | done, text only; canary re-run on Qwen3.6 and Ornith-1.5 |
| 8 | Language intelligence | `lsp.md` | done; ruby-lsp only (jdtls installed, not run) |
| 9 | Task tracking | `tasks.md` | — |
| 10 | The coding agent, completed | `code.md` (rest), `security-revisited.md` | — |

What the done chapters changed beyond their text:

- **Shell:** new `book/shell.md`; `code.md` lost its first half; `bin/pikuri-code` asks the
  skills trust question only when the project ships bundles, and points `--yolo` at a VM.
- **OS assistant:** Part 1 cut to what differs from `shell.md`, plus "Lifting the cage, and
  where" (`--yolo` is for trying it in a VM). The flags stay, by the owner's call; both OS
  bins point them at a VM. The promise now says the OS assistant keeps its cage on the host.
- **Memories:** the mem0 stack has no route out (`internal: true` network, a socat
  `front-door`, `MEM0_TELEMETRY=false`), verified from inside the container; `Mem0Server`
  lost `container_router_url:` and `qdrant_port:`. New section "…and neither can the store".
- **First MCP server:** new `pikuri-mcp/containers/mcp-open-library.Containerfile` (builds the
  pinned v1.2.6 checkout; upstream's re-cloned `main`). `bin/pikuri-openlibrary` picks podman
  over docker, adds `--cap-drop=all --security-opt=no-new-privileges --read-only`, and catches
  `InjectionDetected`. New section "What the box can reach": the whole internet, the host's
  non-loopback services, the LAN (llama-server included); the VM is the wall.
- **Shell, again (found auditing MCPs revisited):** sandboxed `bash` inherited every exported
  variable, so a token in your shell was one `env | curl` away. `D_sandbox_env_wall`:
  `Sandbox::EnvWall` withholds all but the baseline, build-tool options, path-valued variables
  and `sandbox_env:` names; `git_clone` too; the tool description and the banner name what is
  withheld. `shell.md` gained "The environment, walled too".
- **MCPs revisited:** tokens from the config file (`c78a538`). New
  `pikuri-mcp/containers/mcp-egress-proxy.Containerfile` (tinyproxy, allowlist baked via
  `--build-arg ALLOW`) and a section "Narrowing the box to one host": `--internal` network +
  proxy on a DNS-enabled `mcp-egress` network, verified end to end through `bin/pikuri-code`.
  GitHub pinned `v2.1.0` with its own `stdio --read-only` (46 → 27 tools); Playwright via the
  vendor image with Chromium's sandbox back on (`--cap-add=SYS_CHROOT` + `--sandbox`, checked
  at `chrome://sandbox`). The bin's MCP examples and `pikuri-mcp/README.md` lost bare `npx`.

- **Skills:** de-stubbed around the owner's real `cop` skill. Measured: a model-invoked `lol`
  never fires (three runs), typed `/lol` does. `bin/pikuri-code` gained `/clear` (MCP
  connections and plan mode survive it), and a git check before the trust question: project
  bundle files not matching `HEAD` (or no git) grade the project untrusted unasked, via new
  `Pikuri::Bundle::Unreviewed` (hash-object `--no-filters`; `git status` ran a repo's clean
  filter in the run). `Tasks::ListChanged#to_s` stops the raw-event print. New section "What a
  skill can reach, and where it stops".

- **Language intelligence:** a readiness race found by re-running `bin/pikuri-lsp-check`
  cold (2 in 9 runs: "index ready", then nothing): the quiet clock started at spawn, so
  ruby-lsp's ~6s handshake counted as silence. `Readiness#restart_quiet_clock!` at
  `initialized` (`W_quiet_from_initialized`); the check now says *no answer* when it
  measured nothing. New section "The server itself is in no cage" (ruby-lsp `eval_gemfile`s
  your Gemfile as you; VM is the wall); architecture's "unsandboxed child" premise
  (`bash` netless) corrected. Walked-path rule now stated in place, citing the tripwire.

Habits added by the MCPs revisited chapter: a host's AppArmor profile attaches by path inside a rootless
container (Ubuntu's tinyproxy profile blocked the config and every signal, so `podman rm -f`
hung; `journalctl -k | grep apparmor` found it). Under pasta the host's LAN IP is the
container's own; reach the host as `host.containers.internal`. Podman's `--read-only` already
mounts tmpfs on `/tmp`; `--tmpfs /tmp` stays for docker.

### Carried forward

- **Memories, end to end.** Store-and-recall through the new network cut is untested: it needs
  `socat` on the host and the llama.cpp router up. Run `pikuri-memory/bin/pikuri-memory`, tell
  it a fact, quit, rerun, ask.
- **First MCP server, the rejection path.** `bin/pikuri-openlibrary`'s new
  `InjectionDetected` rescue never fired in a run (the real server passes). A spec-support
  server with a poisoned description would exercise it.
- **MCPs revisited, the untested corners.** Headed Playwright against a real desktop's X
  socket (the run used an in-container Xvfb; `$XAUTHORITY` may be needed); the dummy-interface
  dev-server recipe (needs sudo); every recipe under docker (run on podman 5.7 only). The
  chapter says so in place. Its "Wrapping pikuri in Docker" link keeps the anchor pikuri holds
  (see the climax note).
- **pikuri's `pikuri-wire-check`, two pikuri-side nits.** From the workshop it runs only as
  `BUNDLE_GEMFILE=$PWD/Gemfile ruby "$(bundle show pikuri-core)/bin/pikuri-wire-check"` (it
  pins pikuri's own Gemfile, uninstalled in a bundler checkout); and phase 1 logs a spurious
  `ContextWindowDetector` WARN probing its fake `wire-check.invalid` server.
- **`/clear` and MCP.** `Mcp::Extension` has no `on_conversation_reset`, so servers the model
  `mcp_connect`ed stay active after a `/clear` while the conversation forgot connecting. Harmless
  so far; decide when the climax accounts for `pikuri-code`'s wiring.
- **pikuri's "Environment is not a secret store"** still holds (pikuri filters nothing), but
  its one line could point at `pikuri-workshop:D_sandbox_env_wall` for where clearing does
  happen. A pikuri-side edit.
- **pikuri's `security.md:167`** says "the Verifier you already met in the MCP chapter", but
  pikuri's readers reach `mcp.md` after it. A pikuri-side fix.
- **The coding agent, completed.** `code.md`'s wiring block is stale: it shows `add_tool` per
  file tool and `Bash`, where the bin now uses `Workspace::Extension` + `Code::Extension`
  (which also adds `git_clone` and plan mode) plus `Command` and `Lsp`; "four extensions" and
  "six tools take `workspace`" are wrong. The private-repo boot question and the trifecta
  banner get one line in `shell.md`; their full story is pikuri's trifecta chapter. pikuri's
  `book/security.md` links `security-revisited.md#wrapping-pikuri-in-docker`, the one anchor pikuri
  holds into this repo: renaming that section to the outer VM means fixing pikuri too. The
  accounting should also count the mem0 API: unauthenticated on `127.0.0.1:8888`, so the
  coding agent's sandboxed `bash` (shared network) can read every memory. The fix, a
  unix-socket front door, is in `pikuri-memory/design/architecture.md`.

## Open for the climax

"Simple" means checking whether each candidate earns a place:

- **No automatic memory, and saying why.** The coding agent holds all three legs, so
  auto-capture would make one injection come back every session; the memories chapter's own
  argument, run backwards. A strong lesson for "simple".
- **`GIT_REPO_RESEARCHER` / `git_clone`**: its lesson (cloned bytes land in a workspace the
  parent never reads) is real but secondary, since pikuri's book already teaches the
  trifecta-break via a sub-agent. Leaning sidebar.
- **Plan mode**: earns a place only as a security lesson, approving one plan instead of forty
  commands, and then the paragraph on why an approved plan doesn't constrain execution.
