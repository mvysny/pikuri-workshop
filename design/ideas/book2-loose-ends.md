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

- **Capture drops facts once a user has memories.** With a related memory stored, mem0's
  extraction reply asks for `linked_memory_ids`, and Ornith-1.5 often returns `["0"}]}`; mem0
  logs "Error parsing extraction response" and returns `[]`, so nothing is stored and pikuri
  warns of nothing. 2/2 with thinking off, 1/2 with it on. llama.cpp didn't enforce
  `response_format` on mem0's request (`json_object` 4/4 invalid, `json_schema` 1/4), though it
  did on a short one. Candidate fix: a mem0 patch falling back to `json_repair`, and a warning on
  a parse failure. The book and `architecture.md` still describe a separate extraction model.
- **`pikuri-extractors` calls `docker` only** (`Documents`), against the podman-first convention;
  `Mem0Server` had the same bug, now fixed.
- **The exit flush lost the last turn** with a thinking extractor: `Recorder`'s 10 s flush timed
  out and `compose down` cut the in-flight `POST /memories`. Fixed in practice by the no-think
  default: quitting right after a one-turn fact stored it 3/3, no warning (extraction, 2–5 s,
  starts with the turn and beats the reply). Still possible with a thinking extractor, slow
  hardware or rapid-fire turns, and then warned. The book's exit-flush paragraph describes the
  thinking run; rewrite it with the extraction-model docs.
- **The model doesn't know capture is automatic.** Told "remember this", Ornith-1.5 reasoned at
  length about having no save tool; the prompt could say capture happens on its own.
