# pikuri-mcp — AGENTS.md

Model Context Protocol support: a config registry, a catalog verified once per process, per-agent
connections that spawn servers over stdio and HTTP on first use, a pre-flight injection verifier,
an on-disk surface cache, and `bin/pikuri-openlibrary` as the one-MCP demo. Owns everything
MCP-shaped, including the choice to synthesize its tools as raw ruby_llm tools rather than
`Pikuri::Tool`s.

## Invariants

- **MCP-tool bypass.** MCP tools synthesize as raw `RubyLLM::Tool` subclasses, not `Pikuri::Tool`s; the root's Display-line defaults are mechanical so they still render. See {Pikuri::Mcp::Connections}.
- **No MCP process crosses agents.** Only the immutable {Pikuri::Mcp::Catalog} is shared; each agent's {Pikuri::Mcp::Connections} spawns its own, and every spawn must list the catalog's tools. See `D_mcp_catalog_and_connections`.
- **Subprocess-seam exception.** The stdio child is spawned *inside the third-party `mcp` gem*, one of the two sanctioned bypasses of `Pikuri::Subprocess.spawn` (root Subprocess seam); pikuri owns the teardown via `#close`. The `rake tripwires` check for that seam cannot see this one. See {Pikuri::Mcp::ClientWrapper}.
- **`StdioEntry#env` is the per-child credential channel**, merged over the de-bundlerized `Pikuri::BundlerEnv` base (root **Environment is not a secret store** seam). See {Pikuri::Mcp::Registry::StdioEntry}.

Maintenance: the root `AGENTS.md`'s rules.
