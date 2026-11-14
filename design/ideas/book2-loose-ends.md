# Book 2: loose ends after the rewrite

Status: **open checklist**, left when `book2-shape.md` graduated with the climax. Each item is a
run nobody has done yet or a fix that lives in pikuri; strike it when done, delete the file when
empty.

## Runs still owed

- **Memories, end to end.** Store-and-recall through the mem0 stack's network cut is untested:
  it needs `socat` on the host and the llama.cpp router up. Run
  `pikuri-memory/bin/pikuri-memory`, tell it a fact, quit, rerun, ask.
- **First MCP server, the rejection path.** `bin/pikuri-openlibrary`'s `InjectionDetected`
  rescue never fired in a run (the real server passes). A spec-support server with a poisoned
  description would exercise it.
- **MCPs revisited, the untested corners.** Headed Playwright against a real desktop's X socket
  (the run used an in-container Xvfb; `$XAUTHORITY` may be needed); the dummy-interface
  dev-server recipe (needs sudo); every recipe under docker (run on podman 5.7 only). The
  chapter says so in place.
- **Other models.** Task tracking and the completed coding agent were measured on Ornith-1.5
  only: whether a model plans with `task_create` unasked, and whether it delegates recon to
  `file_miner`, are both the model's call and may differ elsewhere.
- **`sandbox_ports:` from the bin.** The forwarding is covered by
  `pikuri-code/spec/pikuri/code/bash/sandbox_spec.rb`; a run through `bin/pikuri-code` against a
  dev server on the host is not.

## pikuri-side fixes (pikuri's repo, not this one)

- **`security.md:167`** says "the Verifier you already met in the MCP chapter", but pikuri's
  readers reach the workshop's `mcp.md` after it.
- **"Environment is not a secret store"** still holds (pikuri filters nothing), but could point
  at `pikuri-workshop:D_sandbox_env_wall` for where clearing does happen.
- **The trifecta verdict's "See book/trifecta-detector.md in this repo"** is wrong when the agent
  runs from the workshop; it should name pikuri's book.
- **`pikuri-wire-check`** runs from the workshop only as
  `BUNDLE_GEMFILE=$PWD/Gemfile ruby "$(bundle show pikuri-core)/bin/pikuri-wire-check"` (it pins
  pikuri's own Gemfile).

## Seen in runs, not yet looked at

- **Every reply printed twice.** In every `bin/pikuri-code` run on Ornith-1.5, each assistant
  message showed as reasoning text and then a near-duplicate as the reply ("Now run the
  tests." / "Now run the tests:").
