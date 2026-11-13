# Changelog

All notable changes to the workshop gems. pikuri's own changes are in
[its changelog](https://codeberg.org/mvysny/pikuri/src/branch/master/CHANGELOG.md).

## [Unreleased]

- `pikuri-code`, `pikuri-os`, `pikuri-lsp`, `pikuri-mcp`, `pikuri-skills`, `pikuri-tasks`, `pikuri-memory` and `pikuri-extractors` moved here from pikuri; a host that wires one now takes it from this repo, beside pikuri's own gems (`D_separate_repo`).
- The workshop gems carry their own version (`Pikuri::Workshop::VERSION`) and pin pikuri's gems with `~>` instead of pikuri-core's exact version.
- `pikuri-extractors` tags its converter image with a digest of its build context instead of pikuri-core's version, so an unchanged image is never rebuilt.
- `bin/pikuri-code` asks "did you write the files under this directory?" only when the project ships a skill or a slash command, and its `--yolo` help and reduced-safety banner now point at a VM rather than a container.
- `bin/pikuri-os` and `bin/pikuri-computer` keep `--no-sandbox` and `--yolo`, but their help and reduced-safety banner now say to use them only inside a VM.
- `pikuri-memory`'s mem0 stack has no route out: mem0, Qdrant and the router relay sit on an internal Docker network, a socat `front-door` publishes the API, and `MEM0_TELEMETRY=false` turns off mem0's PostHog telemetry.
- `bin/pikuri-openlibrary` runs `mcp-open-library:1.2.6` with podman when installed (docker otherwise) and with `--cap-drop=all --security-opt=no-new-privileges --read-only`; rebuild the image from a v1.2.6 checkout with the new `pikuri-mcp/containers/mcp-open-library.Containerfile`.
- `bin/pikuri-openlibrary` prints what the prompt-injection verifier flagged and exits, instead of crashing with a backtrace.
- `Mem0Server` drops `container_router_url:` and `qdrant_port:` (and `bin/pikuri-memory` its `--mem0-router-url`): an internal network can route nowhere but the relay, and Qdrant is no longer published on the host.
