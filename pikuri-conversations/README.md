# pikuri-conversations

Store, list and resume conversations of the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit. pikuri hands a
conversation out as an in-memory `Pikuri::Agent::History` and never writes one to disk; a
chat app that resumes across a restart needs this.

- `Pikuri::Conversations::HistoryFile` — the stored format of a `History`: a folder
  (`history.json` plus content-addressed `attachments/`) or one self-contained JSON string.
  Stored bytes are validated on the way back in, and an attachment loads only from inside
  its conversation's folder, its bytes matching the digest in its name.
- `Pikuri::Conversations::Store` — one folder per conversation under a root, with a
  `meta.json` envelope: title, timestamps, the model and server it ran on, and any keys of
  your own. Lists newest first, finds by id through the listing, retitles, deletes.

```ruby
store = Pikuri::Conversations::Store.new(root: File.expand_path('~/.local/state/my-chat/conversations'),
                                        shell: 'my-chat')
entry = store.create
agent.run_loop(user_message: 'how do I keep an avocado?')
store.save(entry, agent.export_history, model: agent.transport.model, server: agent.transport.api_base)

# later, in another process
entry = store.list.first
agent = Pikuri::Agent.new(transport:, system_prompt:, history: store.history(entry))
```

- `Pikuri::Conversations` — the live ones: one agent per conversation, built and run on
  threads of its own. A message sent while a turn runs is injected into it; cancel, model
  switches, clear and close are safe from any thread and never block it.

```ruby
convs = Pikuri::Conversations.new(
  system_prompt: 'You are a helpful assistant.',
  on_turn_end: ->(conv, history) { store.save(store.find(conv.id), history, model:, server:) }
)
conv = convs.open(id: entry.id, transport:, listener:, history: store.history(entry))
conv.submit('how do I keep an avocado?')   # => :started — events reach your listener
conv.submit('also, ripe?')                  # => :injected — the running turn reads it
conv.cancel
convs.shutdown(timeout: 5)
```

- `Pikuri::Conversations::Throttle` — how many requests may fly against one server at a
  time, process-wide. A llama.cpp sizes itself from its `/props` slot count on a
  conversation's first turn; size any other server yourself, and pass the throttle to the
  agents you build outside a list, and to a RAG embedder and reranker, so they queue with the rest:

```ruby
Pikuri::Conversations::Throttle.limit('http://localhost:8080', 1)   # llama-server --parallel 1
titler = Pikuri::Agent.new(transport:, system_prompt:, around_request: Pikuri::Conversations::Throttle)
embedder = Pikuri::VectorDb::Embedder.new(server:, model:, around_request: Pikuri::Conversations::Throttle)
reranker = Pikuri::VectorDb::Reranker::LlamaServer.new(server:, model:, around_request: Pikuri::Conversations::Throttle)
```

- `Pikuri::Conversations::Titler` — names a conversation from its opening message. Give the
  list one and open a conversation `untitled: true`; once its first turn has ended, the
  conversation reports `Event::Titled` and you store it:

```ruby
titler = Pikuri::Conversations::Titler.new(transport: thinking_off_transport, params_declared: true)
convs  = Pikuri::Conversations.new(system_prompt:, titler:)
conv   = convs.open(id: entry.id, transport:, listener:, untitled: store.stamp_titled?(entry))
# in the listener:
#   in Pikuri::Conversations::Event::Titled(title:) then entry = store.retitle(entry, title)
```

- `Pikuri::Conversations::RateLimitedListener` — streamed deltas at most 15 times a second,
  for a renderer that re-renders Markdown on each. Wrap the listener you open with; the
  conversation's own events pass straight through, from whatever thread sends them:

```ruby
listener = Pikuri::Conversations::RateLimitedListener.new(renderer, fps: 15)
conv     = convs.open(id: entry.id, transport:, listener:)
```

## Install

```ruby
# Gemfile
gem 'pikuri-conversations'
```
