# Book 2: loose ends after the rewrite

Status: **open checklist**, left when `book2-shape.md` graduated with the climax. Each item is a
run nobody has done yet or a fix that lives in pikuri; strike it when done, delete the file when
empty.

## Runs still owed

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

Memories, end to end, ran 2026-11-17 (rootless docker, router on another host with an API key,
Ornith-1.5 as chat *and* extractor, nomic embedder): three facts stored, recalled by a fresh
process, the stack torn down clean both times. It surfaced:

- **`embed_model` doesn't set the vector size.** `bin/pikuri-memory` never passes
  `embedding_dims:`, so any embedder but a 768-dim one (e.g. `bge-m3`, 1024) breaks Qdrant
  upserts.
- **The router's API key never reaches mem0.** The compose file defaults `OPENAI_API_KEY` to a
  dummy and neither the bin nor `Mem0Server` passes `llm_api_key`; a keyed router 401s every
  extraction. The run worked only because `OPENAI_API_KEY` was exported by hand.
- **`Mem0Server` calls `docker` only**, against the podman-first convention.
- **The exit flush loses the last turn.** `Recorder`'s 10 s flush timed out while the extractor
  shared the router with chat; `compose down` then cut the in-flight `POST /memories`. A fact
  told in the last turn before quitting is dropped.
- **The model doesn't know capture is automatic.** Told "remember this", Ornith-1.5 reasoned at
  length about having no save tool; the prompt could say capture happens on its own.
