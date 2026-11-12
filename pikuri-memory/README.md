# pikuri-memory

Durable, cross-conversation memory for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit:
facts about the user and their work that persist across
conversations, backed by [mem0](https://github.com/mem0ai/mem0).

Wire it onto a `pikuri-core` agent the same way as `pikuri-tasks` /
`pikuri-vectordb` — `c.add_extension` inside the `Agent.new` block:

```ruby
require 'pikuri-memory'

client = Pikuri::Memory::Mem0Client.new(endpoint: 'http://localhost:8888')

Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension Pikuri::Memory::Extension.new(client: client, user_id: 'martin')
end
```

## What you get

Three retrieval tiers, the same layered shape `pikuri-vectordb`
uses (`vectordb_search` + `vectordb_read`):

1. **Resident persona** — a small always-in-prompt summary of what
   the agent already knows about the user, appended once at
   construction.
2. **Automatic prefetch** — every user turn is embedded and
   searched; a small, high-precision slice is injected as a
   `<memory-context>` block right after the turn.
3. **`recall` tool** — explicit, topic-driven deepening when the
   agent wants more than the automatic slice surfaced.

Recall is automatic and **synchronous** (a vector search is
milliseconds). Capture is automatic and **asynchronous** — a
background worker drains user turns into mem0's extraction call
(~seconds), so a turn never blocks on "what should I remember?".

## Safety

Automatic capture and recall are safe only on an agent with **no
untrusted ingest and no egress** (pikuri's `@private` member): a
poisoned memory plus an outbound leg is the lethal trifecta. Two
structural defenses keep the capture pipeline honest:

- **Only the user's own words** are fed to extraction — assistant
  turns, tool results, and recalled context are never captured.
- **Capture reads what you typed, never the conversation.** That is
  what stops a recalled memory being re-extracted and re-stored, over
  and over, until one hallucinated fact exists 800 times.

Do not port memory onto an egress-capable agent without re-deriving
the recall-poisoning mitigations.

## Storage: mem0 + Qdrant

Memory is stored in [mem0](https://github.com/mem0ai/mem0) with
**Qdrant** as the vector backend (mem0's pgvector path has a top-k
inversion bug — it returns the *farthest* matches), a local
OpenAI-compatible LLM + embedder (llama.cpp via `OPENAI_BASE_URL`),
and a **non-reasoning** extraction model (e.g. `Qwen2.5-7B-Instruct` —
a thinking model burns its token budget on chain-of-thought and
returns empty JSON).

Two ways to get a server:

- **Let pikuri manage it.** `Pikuri::Memory::Mem0Server` is a
  self-managed sidecar supervisor (the same pattern — and the same
  Qdrant engine — as `pikuri-vectordb`'s `Server::Qdrant`): it
  clones mem0 at a pinned
  commit, patches `DEFAULT_CONFIG` to use Qdrant, and brings a
  `docker compose` stack (mem0 + Qdrant + a ~5 MB socat relay,
  **no Postgres**) up through `Pikuri::Subprocess.spawn`. `#client`
  returns a `Mem0Client` pointed at it. A `localhost` router works
  as-is: the relay carries the container's LLM/embedder calls to
  the host's loopback over a unix socket, so no
  rootless-vs-rootful daemon configuration is needed (see
  `Mem0Server`'s "router relay" yardoc section).

  ```ruby
  server = Pikuri::Memory::Mem0Server.ensure_running(
    router_url:     'http://localhost:8080/v1',
    llm_model:      'bartowski/Qwen2.5-7B-Instruct-GGUF:Q5_K_M',
    embedder_model: 'nomic-ai/nomic-embed-text-v1.5-GGUF:Q8_0'
  )
  Pikuri::Memory::Extension.new(client: server.client, user_id: 'martin')
  ```

  Needs `docker` (with the compose plugin), `git`, and `socat`. The
  first run builds the mem0 image (a few minutes); the clone lives under
  `~/.cache/pikuri/mem0/temp/git` and the Qdrant corpus + memory
  history under `~/.cache/pikuri/mem0/data/` (bind-mounted into the
  containers), so subsequent runs are fast and the data persists
  across restarts.

- **Bring your own.** Point `Mem0Client.new(endpoint:)` at a mem0
  server you already run (configured as above). Skips the supervisor
  entirely.

## Install

```ruby
# Gemfile
gem 'pikuri-memory'
```

Depends only on `pikuri-core`.
