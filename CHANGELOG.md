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
- `pikuri-code`'s Bubblewrap sandbox withholds inherited environment variables except the shell's baseline, build-tool options and path-valued ones, a second wall behind keeping secrets out of your environment at all, so a token you missed no longer reaches `bash` or a cloned repo's filters; list extras under `sandbox_env:` in the config file, and add `#env(delta)` and `#withheld_env_names` to any sandbox of your own (`D_sandbox_env_wall`).
- `bin/pikuri-openlibrary` runs `mcp-open-library:1.2.6` with podman when installed (docker otherwise) and with `--cap-drop=all --security-opt=no-new-privileges --read-only`; rebuild the image from a v1.2.6 checkout with the new `pikuri-mcp/containers/mcp-open-library.Containerfile`.
- New `pikuri-mcp/containers/mcp-egress-proxy.Containerfile`, a tinyproxy image that lets an MCP server on an internal network reach only the hosts baked in at build time; `bin/pikuri-code`'s commented MCP examples now run every server in a container (GitHub behind that proxy, a baked npm image, Playwright with Chromium's sandbox on) instead of bare `npx`.
- `bin/pikuri-code` counts a project's skills and commands as untrusted, without asking, when a bundle file matches no commit (untracked, ignored or changed since `HEAD`) or the project is not a git repository, via the new `Pikuri::Bundle::Unreviewed`; commit the bundles you reviewed to be asked again.
- `bin/pikuri-code` gains a `/clear` built-in that empties the conversation and resets the task list, the read-before-edit marks and every fired `paths:` skill, keeping the wiring.
- `Pikuri::Tasks::ListChanged#to_s` renders one line (`tasks: 1/3 done, now: …`), so a terminal no longer prints the raw event.
- `bin/pikuri-openlibrary` prints what the prompt-injection verifier flagged and exits, instead of crashing with a backtrace.
- `Mem0Server` drops `container_router_url:` and `qdrant_port:` (and `bin/pikuri-memory` its `--mem0-router-url`): an internal network can route nowhere but the relay, and Qdrant is no longer published on the host.
