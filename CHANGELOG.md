# Changelog

All notable changes to the workshop gems. pikuri's own changes are in
[its changelog](https://codeberg.org/mvysny/pikuri/src/branch/master/CHANGELOG.md).

## [Unreleased]

- `pikuri-code`, `pikuri-os`, `pikuri-lsp`, `pikuri-mcp`, `pikuri-skills`, `pikuri-tasks`, `pikuri-memory` and `pikuri-extractors` moved here from pikuri; a host that wires one now takes it from this repo, beside pikuri's own gems (`D_separate_repo`).
- The workshop gems carry their own version (`Pikuri::Workshop::VERSION`) and pin pikuri's gems with `~>` instead of pikuri-core's exact version.
- `pikuri-extractors` tags its converter image with a digest of its build context instead of pikuri-core's version, so an unchanged image is never rebuilt.
- `bin/pikuri-code` asks "did you write the files under this directory?" only when the project ships a skill or a slash command, and its `--yolo` help and reduced-safety banner now point at a VM rather than a container.
- `bin/pikuri-os` and `bin/pikuri-computer` keep `--no-sandbox` and `--yolo`, but their help and reduced-safety banner now say to use them only inside a VM.
