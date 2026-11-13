# Agent per conversation — the workshop side

pikuri decided `pikuri:D_agent_is_one_conversation`: one `Agent` is one conversation.
`clear_conversation`, `load_history!`, `Extension#on_conversation_reset` and `Event::Reset` are
gone; a host closes the old agent and builds a new one, resuming via `Agent.new(history:)`. An
extension that needs the restored conversation reads it in `bind` (`ctx.agent.export_history`).
This file is what the workshop (and the downstream hosts) must do about it.

## Why, in one paragraph

MCP tools registered by `mcp_connect` outlived a clear and leaked across a load. Worse, an MCP
server's *state* did: Playwright logged into a bank in conversation A is still logged in for
conversation B. pikuri can't know what a foreign server holds, so it assumes every one is
stateful — an MCP connection never crosses a conversation boundary. Re-creating the agent gives
that for free, because `Mcp::Extension#configure` already starts the servers and `on_close`
kills them.

## Mechanical migration

- `pikuri-tasks`, `pikuri-skills`: delete `on_conversation_reset`; the state is fresh because the
  extension instance is (one instance per agent — a host must not reuse one).
- `pikuri-memory`, `pikuri-os` (`MachineMemory`, `SystemInfo`): yardoc says "refreshed on
  clear_conversation" — now "taken when the agent is built", which a /clear still triggers.
- `pikuri-mcp` `Connect`: the activated set is already per instance; fine.
- Hosts: `pikuri-tui` `AgentSession#clear_conversation` → build a new agent, close the old; the
  `Event::Reset` handling (e.g. `skill_activation_listener.rb`) goes. `pikuri-webui`
  `Runner#restore!` → pass `history:` to the factory's `Agent.new`; `HistoryLoaded` now fires
  during construction, so the listener stack must be wired before (it already is).

## MCP: catalog + lazy connections

Re-creating the agent re-runs MCP startup per conversation: spawn + handshake per server, the
verifier's LLM call (not cached), the synthesizer's (cached by `Mcp::Cache`). Split it:

- **Catalog, once per process** — spawn each server, verify, describe, record its tool schemas,
  close. `<available_mcps>` renders from it.
- **Connections, per agent, lazy** — `mcp_connect` registers tools from the catalog; the process
  starts at the first real tool call. Building an agent spawns nothing; most conversations never
  connect, so the webui's N open conversations don't mean N × M children.
- **Restore** — `Mcp::Extension#bind` scans the restored history for `mcp_connect` calls and
  re-registers those ids still in the catalog. No process, no side effect; the server starts
  when the conversation actually calls a tool (and finds a blank Playwright page —
  `pikuri:D_history_load_repairs`). Re-registering an id whose old connect failed costs only
  extra tools, so no result parsing.
- **Rug-pull check** — the lazily spawned process is a new process. Compare its handshake's tool
  list to the catalog's and refuse on a difference; re-verifying would put the LLM call back
  per conversation.
- `Servers` stays `P_one_agent` — no locking, since nothing is shared across conversations.

## Open questions

- `Q_lsp_lifetime` — LSP servers also start per agent (`Lsp::Extension#configure`), and jdtls is
  slow. An LSP server holds the project, not a secret a conversation produced, so it could be
  host-owned and passed in. Does anything a conversation does leave state in it that another
  must not see (unsaved buffers via `didOpen`/`didChange`)?
- `Q_subagent_mcp_view` — within one conversation, a sub-agent reaches the parent's servers via
  `Mcp::Servers::View`, so a persona reading untrusted pages would drive the parent's logged-in
  browser. Separate from the conversation boundary, but the same leak shape.
- `Q_extension_reuse_guard` — reusing an extension instance across two agents silently shares
  per-conversation state. Worth a loud guard (core's `Configurator#add_extension`), or is the
  protocol yardoc enough?
