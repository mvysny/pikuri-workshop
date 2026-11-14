# Agent per conversation — the workshop side

pikuri decided `pikuri:D_agent_is_one_conversation`: one `Agent` is one conversation.
`clear_conversation`, `load_history!`, `Extension#on_conversation_reset` and `Event::Reset` are
gone; a host closes the old agent and builds a new one, resuming via `Agent.new(history:)`. An
extension that needs the restored conversation reads it in `configure` (`c.history`).
This file is what the workshop (and the downstream hosts) must do about it.

## Why, in one paragraph

MCP tools registered by `mcp_connect` outlived a clear and leaked across a load. Worse, an MCP
server's *state* did: Playwright logged into a bank in conversation A is still logged in for
conversation B. pikuri can't know what a foreign server holds, so it assumes every one is
stateful — an MCP connection never crosses a conversation boundary
(`D_mcp_catalog_and_connections`).

## Mechanical migration

**Done in the workshop** (with `pikuri-conversations`): `pikuri-tasks` and `pikuri-skills`
lost `on_conversation_reset` (and `List#clear`, `Activation#reset`, `Activation::Open`, the
"needs an interloper" raise, the `arm_gate` warning); the `pikuri-memory` / `pikuri-os` yardoc
says "taken when the agent is built"; `bin/pikuri-code` drops `interloper:` and its `/clear`
closes the agent and calls a `build_conversation` lambda, the skill extension built inside it.
`pikuri-mcp` `Connect` needed nothing.

**Found on the way**: a host object that outlives the agent and offers only a subscribe —
`Workspace::ReadOnly#on_change` — kept the closed agent's `Code::Extension` reporting plan-mode
flips after a `/clear` (printed twice). Fixed by going quiet on `c.on_close`; an unsubscribe on
`ReadOnly` would be the cleaner pikuri-side fix. Any other shared host object with a
subscribe-only API has the same shape.

**Still to do, in the hosts**:

- `pikuri-tui` `AgentSession#clear_conversation` → build a new agent, close the old; the
  `Event::Reset` handling (e.g. `skill_activation_listener.rb`) goes; drop `interloper:` in the
  three apps. `deliver_pending_injections` moving leftovers to a rebuilt agent reads both
  agents' queues.
- `pikuri-webui` `Runner#restore!` → pass `history:` to the factory's `Agent.new`;
  `HistoryLoaded` now fires during construction, so the listener stack must be wired before (it
  already is). `pikuri-webui-chat`'s factory reads `agent.interloper` instead of handing one to
  `Agents::Runner`. Its store moves to `Pikuri::Conversations::Store` (`conversations.md`).

## MCP: catalog + lazy connections — done

Built: `Mcp::Catalog` once per process, `Mcp::Connections` per agent and lazy, the rug-pull
check, restore from the history's `mcp_connect` calls; why is `D_mcp_catalog_and_connections`.
**Breaking for the hosts**: `Mcp::Extension.new(registry:, synthesize_descriptions:,
verify_mcp_servers:)` is now `Mcp::Extension.new(catalog:)`, one per agent, the catalog built
once with `Mcp::Catalog.build(registry, transport:, cancellable:, around_request:)`. Only
pikuri-tui wires MCP (`Code::App#default_build_agent` builds the registry and the old-shape
extension per agent); it still takes `pikuri-mcp` from pikuri at 9b982d6, so the change lands
when it moves to the workshop's gems. pikuri-webui parses `[[code.mcp]]` but wires nothing.
