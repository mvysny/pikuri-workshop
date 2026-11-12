# pikuri-mcp

[Model Context Protocol](https://modelcontextprotocol.io) support
for the [pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant
toolkit.

Adds:
- `Pikuri::Mcp::Registry` — declarative config layer for stdio +
  HTTP MCP servers.
- `Pikuri::Mcp::Servers` — runtime that spawns the configured
  servers via the [`mcp`](https://rubygems.org/gems/mcp) gem.
- `Pikuri::Mcp::Synthesizer` — LLM-driven description summarizer
  for MCP servers whose handshake omits useful instructions.
- `Pikuri::Mcp::Verifier` — pre-flight prompt-injection scan of
  every MCP server's tool surface before tools are advertised to
  the LLM.
- `Pikuri::Mcp::Cache` — on-disk cache of synthesized descriptions
  and verifier results, keyed on the full server surface.
- `Pikuri::Mcp::Extension` — wires everything into a
  `Pikuri::Agent` via the `c.add_extension(...)` block API.
- `bin/pikuri-openlibrary` — dev/demo entry point (source checkout
  only, not a gem executable): a minimal agent hardcoded to one MCP
  server, the community [Open Library
  catalogue reader](https://github.com/8enSmith/mcp-open-library)
  running in a locally-built Docker container, plus `calculator`.
  The worked example of the guide's MCP chapter.

## Install

```ruby
# Gemfile
gem 'pikuri-mcp'
```

Adds the `mcp` gem as a runtime dep on top of `pikuri-core`.

## Usage

```ruby
require 'pikuri-core'
require 'pikuri-mcp'

registry = Pikuri::Mcp::Registry.new(entries: [
  Pikuri::Mcp::Registry::StdioEntry.new(id: 'gmail', command: %w[npx @gongrzhe/server-gmail-autoauth-mcp]),
  Pikuri::Mcp::Registry::HttpEntry.new(id: 'hubspot', url: 'https://mcp.example.com/v1',
                                       headers: { 'Authorization' => "Bearer #{ENV.fetch('HUBSPOT_TOKEN')}" })
])

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension(Pikuri::Mcp::Extension.new(registry: registry))
end
```

The extension's `configure` builds the shared `Mcp::Servers` (which
eager-starts every configured server), appends `<available_mcps>` to
the system prompt, and registers a close handler so the agent's
`#close` tears down the MCP subprocesses. Its `bind(agent)` adds a
per-agent `mcp_connect` tool — sub-agents share the live MCP clients
via the same extension instance but each has its own connect tool +
activation set.

## Further reading

- **Narrative walkthrough:** [the MCP chapter of the guide](../book/mcp.md) is the gentle MCP intro — one
  low-stakes server in a locally-built container (run via
  `bin/pikuri-openlibrary`), rootless Docker as the boundary, the
  verifier and synthesizer in depth.
  [The MCP-revisited chapter](../book/mcp-revisited.md) picks
  the thread back up at the harder end: the official GitHub MCP
  in Docker, npx- and pip-based community servers, Playwright,
  and the full threat model.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-mcp> (once published), or run
  `bundle exec yard` in this directory for a local copy.
