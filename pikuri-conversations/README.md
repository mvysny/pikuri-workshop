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

Coming: a request throttle for a small server shared by many conversations, and a titler.

## Install

```ruby
# Gemfile
gem 'pikuri-conversations'
```
