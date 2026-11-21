# Coding-agent deferrals

Status: **deferred, considered-then-punted.** Carried over from the v1
plan once `bin/pikuri-code` shipped. Each was in scope of the design
exercise, considered, and left out on purpose — recorded so a future
contributor doesn't read the absence as oversight. Promote into a real
plan when the friction shows up.

Related:

- [`bash-confirmer.md`](bash-confirmer.md) — the permission-system
  deferral below is the coarse-modes-today half; that note is the
  session-grant / fatigue half of the same permission story, and the
  risk-tier / dry-run / time-bound wishlist it would grow into.

## The deferrals

- **Permission system.** opencode's three-action `allow` / `deny` /
  `ask` glob rules. v1 ships with two coarse modes (interactive
  `Workspace::Confirmer::Terminal` on `Write` / `Bash`; `--yolo` swaps in
  `AUTO_APPROVE`). Revisit once `bin/pikuri-code` has lived a while
  and we know where the friction is. Where things are headed:
  yolo-in-docker, or ClaudeCode's agentic review of the command + automatic approval/denial.
- **Image auto-resize in `Workspace::Read`.** Day-one image support
  refuses anything over 5 MB outright (see
  `lib/pikuri/workspace/read.rb`'s `MAX_IMAGE_BYTES`). PI auto-resizes
  to 2000×2000 with an image-processing dep; we punted on that
  trade-off — adds mini_magick / ruby-vips for one tool's
  ergonomics. Revisit if "Read screenshot.png" being denied on size
  becomes a common annoyance.
- **Streaming output from bash.** `Code::Bash` returns a single
  observation `String`. Live process output is meant to stay on the
  listener stream once we add a TUI; meanwhile callers bound wall time
  with coreutils' `timeout`.
- **Session persistence / resumable sub-agents.** opencode's `task`
  tool persists sub-sessions; pikuri's `agent` tool
  (`SubAgent::SubAgentTool`) doesn't. Worth doing the day we have
  any other reason to introduce a session store.
