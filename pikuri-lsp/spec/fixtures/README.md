# Recorded language-server payloads

What real servers answered, as bytes, so the parse layer is tested against
reality rather than against pikuri's own serializer. Every file is one
JSON-RPC member: a `result`, or a complete notification frame.

**Provenance, exactly.** Field names, value shapes, counts and every string
a run recorded verbatim (the `jdt:` URI, the error codes and messages, the
progress token titles, the 14 `Pikuri::Tool` rows and the file that
declares it last) come from the live runs written up in
`pikuri-lsp/design/architecture.md` §Measurements, cited per file below by finding id. What is *ours*
is whitespace, key order, paths the write-up elided, and ranges past the one
line a finding recorded.
These are faithful reconstructions of recorded payloads, not raw captures — the
runs were throwaway clients whose transcripts were never kept, and the
findings are what survived.

Each file therefore pins a behaviour, and the finding id is where the
behaviour was observed:

| file | server | finding | what it pins |
| --- | --- | --- | --- |
| `ruby_lsp_initialize_result.json` | ruby-lsp 0.26.10 | `F_capabilities_per_workspace`, `F_unadvertised_providers`, `H_subtypes_stub` | `positionEncoding: "utf-8"` accepted, `typeHierarchyProvider: {}` present, `typeDefinitionProvider` / `implementationProvider` / `callHierarchyProvider` / `declarationProvider` absent |
| `jdtls_initialize_result.json` | jdtls 1.58 | `J_progress_opt_in`, `J_type_definition_recovers_var`, `F_position_encoding` | no `positionEncoding` at all (utf-16 by default), `definitionProvider: true` as a bare boolean |
| `ruby_lsp_definition_location_link.json` | ruby-lsp | `F_definition_candidates`, `F_two_location_shapes` | the `LocationLink` shape, and a definition answering *candidates* — two overrides, not one answer |
| `jdtls_definition_jdt_uri.json` | jdtls | `J_library_is_not_a_file`, `J_type_definition_recovers_var` | a plain `Location` whose URI is a ~300-character `jdt:` URI carrying a classpath entry in its query string |
| `jdtls_class_file_contents.json` | jdtls | `J_class_file_contents` | `java/classFileContents` answers a **bare String**, where a spec-shaped request would answer an object |
| `ruby_lsp_supertypes.json` | ruby-lsp | `H_namespace_reopenings` | 14 results, every one named `Pikuri::Tool`, the real declaration ordered last. The file:line pairs are this repo's actual `class Tool` reopenings, so `grep -rn '^  class Tool$' pikuri-core/lib` still reproduces the list |
| `ruby_lsp_subtypes_null.json` | ruby-lsp | `H_subtypes_stub` | an advertised provider wired to a `# TODO`, answering `null` rather than `[]` |
| `ruby_lsp_invalid_location_error.json` | ruby-lsp | `S_rangeless_didchange_crash` | `-32602` with a raw Ruby backtrace as the message |
| `ruby_lsp_log_message_didchange.json` | ruby-lsp | `S_rangeless_didchange_crash` | the only report a crashed notification gets: a `window/logMessage` the client is free to ignore |
| `jdtls_progress_begin.json`, `_report.json`, `_end.json` | jdtls | `J_progress_opt_in`, `J_readiness_edge` | the `$/progress` lifecycle of the long-lived `Initialize Workspace` token — and that `percentage` is absent from `begin` |
| `jdtls_language_status.json` | jdtls | `J_progress_opt_in`, `J_readiness_edge` | `language/status`, a readiness signal outside the LSP spec |
