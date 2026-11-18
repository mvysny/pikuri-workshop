# Hosting many conversations

Every binary in both books has run one agent at a time. You type, it thinks, it prints, you
type again. Even sub-agents only *look* like the exception: a boss that asks for three runs them
one after another, inline, on its own thread.

A chat app inverts that. Put pikuri behind a web page, a GTK window or a full-screen terminal UI
and the user stops waiting: they type a correction while the agent is mid-answer, press stop a
second after pressing send, open a second conversation while the first one is still thinking,
and expect both to be there tomorrow. Meanwhile small jobs nobody asked for run on their own
schedule: a title for the sidebar, a description check for an MCP server.

pikuri's `Agent` doesn't do any of that, on purpose. It is one conversation, synchronous and
thread-unsafe, with a short list of rules for whoever drives it from more than one thread. This
chapter is about those rules, about what broke when three apps each obeyed them in their own
way, and about `pikuri-conversations`, the gem that now obeys them once for all three.

There is no cage in this chapter. Nothing here runs code you didn't write; this gem is in the
workshop because a scheduler is a *feature*, and pikuri grows by explaining better, not by
gaining features.

There is no demo either. The interesting behaviour lives in races a few milliseconds wide, which
nobody can hit on purpose from a keyboard, so a demo would mostly show the happy path. Claims
below were measured in the gem's specs, in a scratch script, or in the apps themselves, and each
says which. The worked examples are the apps:
[pikuri-webui](https://github.com/mvysny/pikuri-webui) and
[pikuri-tui](https://github.com/mvysny/pikuri-tui) are both thin layers over this gem now, and
read well after this chapter.

## Two shapes of agent

A chat app holds two quite different kinds of agent.

**Session agents** live long: one per conversation, built when someone opens it and kept until
they close it. Tools wired, extensions bound, a listener streaming events out to a browser tab
or a pane, a history that grows for as long as the conversation does. This is the agent every
earlier chapter built, just several of them.

**One-off agents** are the opposite: built for one question, handed one turn, read once, thrown
away. No tools, no listener, no history worth keeping. Here is one whole, the `Thinker` that
[MCPs revisited](mcp-revisited.md)'s description verifier runs its passes through:

```ruby
def call(prompt)
  @cancellable&.check!
  agent = Pikuri::Agent.new(transport: @transport, system_prompt: SYSTEM_PROMPT,
                            around_request: @around_request)
  begin
    agent.run_loop(user_message: prompt)
    agent.last_assistant_content.to_s
  ensure
    agent.close
  end
end
```

Fresh agent, one turn, `close` in an `ensure`. The gem's `Titler` is the same thing with a
different prompt. Keep that `around_request:` in mind; it comes back below.

The realistic load is the mix: twenty session agents mostly idle (people read slowly) while
one-off jobs fire in bursts.

## `Agent` is thread-unsafe, on purpose

Everything below follows from one blunt fact. An `Agent`'s chat, its message map and its
`on_close` list are plain unguarded state, and `run_loop` is not re-entrant. A second thread
calling into a mid-turn agent corrupts the conversation rather than raising something you could
catch.

So the contract is *one call at a time*, and two details matter:

- **Nothing is confined to a thread.** Turn 4 may run on one thread and turn 5 on another; a web
  server's pool hands you whichever worker is free. Only *overlap* is forbidden, so never key
  anything about an agent off `Thread.current`.
- **Exactly two doors open from another thread**, the two objects that carry their own locks.
  `Control::Cancellable` stops the turn: flip it from anywhere, and the agent notices at its next
  checkpoint and unwinds. `Control::Interloper` hands a running agent a message: every agent owns
  one, and it delivers at the end of a tool batch, the one point where the conversation is
  consistent.

Every other method needs your own serialization. And one rule rides on the first door: **the
host resets the `Cancellable`, where it decides a turn starts** — not `run_loop`, which can't
tell a cancel left over from the last turn from one meant for this turn
(`pikuri:D_host_resets_cancel`). The next section is what that rule costs when it sits one line
too late.

## The cancel that arrives too early

Press Return, then Escape at once. The host's natural shape is this:

```ruby
Thread.new do
  agent.cancellable.reset!           # don't let the last turn's cancel stop this one
  agent.run_loop(user_message: text)
end
# ...and the user's Escape, on the UI thread:
agent.cancellable.cancel!
```

It reads fine, and it never works. `Thread.new` returns before the new thread runs a line, so the
Escape lands first, and the worker's reset wipes it. Measured with a scratch script on pikuri's
scripted fake transport (Ruby 3.3.8), cancelling right after starting the turn, 500 times: **500
turns ran to the end.** Against a real model that means a cold prefill and a full answer you
asked not to get.

The gem moves the reset to where the turn starts: under the conversation's lock, in the same
critical section that flips its state to `:running`, on the thread that called `submit`. A
cancel that lands after `submit` returns is for this turn; one that landed before was for the
previous. The same script, through `conversation.submit(text)` then `conversation.cancel`, 500
times: **500 cancelled.**

pikuri-webui, pikuri-tui and Puri each had the early version of this, and when pikuri moved the
reset out of `run_loop`, a pin bump alone broke cancel in all three at once. That is most of the
reason the gem exists (`D_conversations_gem`).

## Typing while it works

The user types again while the agent is mid-turn. Queueing the message as a new turn is the
obvious answer, and the wrong one: a correction ("not that file, the other one") reaches the
model only after the turn it was meant to correct has finished.

So `submit` on a running conversation answers `:injected` and hands the message to the agent's
`Interloper`; the running turn reads it after its current tool batch. Two edges need handling,
and both are tested in the gem's specs rather than by hand:

- **The message that arrives too late.** If the turn's last request was already in flight, no
  later batch boundary will deliver it. The gem notices at turn end, still under the lock, and
  starts a *bare* turn — no new user text — whose `run_loop` delivers what's pending. Only after
  a turn that *completed*: after a cancel, a restart would make the stop button look broken, and
  after a failure, an unreachable server would spin.
- **The cancel with a message pending.** Dropping it would silently discard text the user typed
  and never saw rendered; handing it back as text fails because no UI can put text back into its
  input box. So it stays pending, counted in `status.pending`, and the app decides: pikuri-webui
  and pikuri-tui deliver it with the next message you send (a blank `submit` would send it
  alone), Puri takes it with `discard_pending` and shows what it took (`D_submit_injects`).

The `Interloper` delivers at batch boundaries, not mid-response, so a message typed while the
model streams a long answer waits for it. That's why an app shows the pending count: it makes the
wait legible rather than hiding it.

## Many conversations, one llama.cpp

Three conversations, one local server started with `--parallel 1`. llama.cpp doesn't refuse the
second and third request; it queues them, which is the problem. ruby_llm's timeout ticks while a
request waits in the server's queue, its retry on timeout re-enqueues work behind an original
that may still be generating, and a request parked inside the server can't be cancelled from the
client. Parked in *our* queue it can.

So the gem's `Throttle` bounds the requests in flight per server, and the unit is **one HTTP
request, never a turn**. A turn spends seconds in tools while the server idles, and a turn-long
permit deadlocks outright: a parent holding the only permit runs a tool that spawns a sub-agent,
and the child waits for the permit its parent holds. pikuri measured the request-sized version
against a live llama.cpp router (`pikuri:D_llm_request_throttle`): three agents, one permit,
answers landing at 7.1, 14.2 and 21.3 s; four permits, all three together at 9.1 s. The gem's
spec holds three conversations against a server sized to one and checks that no second request
ever gets past.

Three details make it work without configuration:

- **It is process-wide**, keyed by server URL, not owned by a list of conversations: what a
  permit protects is the server, and two lists against one llama.cpp would each hand out its
  slots (`pikuri:D_rate_limiter_scope`).
- **It sizes itself.** At a conversation's first turn the gem asks llama.cpp's `/props` for its
  `total_slots`, once per server and model, and seeds the throttle with it. At the turn, not at
  boot: on a router, asking loads the model, and the user may switch away before sending
  anything (`pikuri:D_deferred_cap_probe`). `Throttle.limit` from the app wins over the probe,
  and a server that isn't llama.cpp stays unlimited unless you size it.
- **It is the `around_request:` hook.** Every agent the gem builds carries it. An agent you build
  yourself — the `Thinker` above, a titler — must be handed it, or it skips the queue. So must
  a RAG `Embedder`, which takes the same hook: a reindex is a burst of embed requests, and
  unthrottled it crowds the chat off a one-slot server. Three embeds against a stub server
  sized to one permit ran one at a time, 1.5 s in all against 0.7 s unsized; a live llama.cpp
  was not tried. A `Reranker::LlamaServer` takes the hook the same way; its reranks were not
  timed. An embedding server of its own is never probed, since only a turn probes, so
  it stays unlimited until you `limit` it.

Turns themselves are *not* bounded. Each runs on a plain thread of its own: a bounded pool would
let three conversations parked on three confirmation prompts hold every worker while the server
idles, and a sub-agent submitted to the pool and awaited deadlocks it
(`D_conversation_turn_state`).

## Never call out under your own lock

pikuri-webui guards its whole state with one lock, held by every task, listeners included
(`pikuri-webui:D_global_monitor`). A listener for a conversation's events takes that lock to
update the sidebar. Now suppose the gem fired that listener while holding *its* lock, and a
request thread holding webui's lock asked the conversation for its status: each thread holds one
lock and waits for the other. Nothing crashes; the app just stops.

The gem's answer is one rule: **nothing outside the gem is called under its lock.** No listener,
no saver, no `Agent#close`. A critical section changes state and *queues* the events and
threads it wants; they go out after the lock drops. So the lock order is fixed — the app's lock,
then the conversation's, then the agent's `Interloper` — and an app may call `status` from inside
its own listener, under its own lock, safely. The rule reaches into odd corners: a mid-turn
`submit` injects into the `Interloper` under the conversation's lock, and the `Interloper` reports
its new count on the injecting thread, so the gem owns that callback and queues the event like
any other.

## A connection rides the agent

ruby_llm's obvious configuration door is process-global:

```ruby
RubyLLM.configure { |c| c.openai_api_base = '...' }   # never, in pikuri
```

In one agent you'd never notice. In an app it's two conversations stomping each other: one on a
30B, one on a 4B, a title job on whatever is cheapest, and one global `openai_api_base` — the last
to configure wins, and the others silently talk to the wrong server with the wrong key.

So a connection rides the agent. A `ChatTransport` bundles what must travel together for a chat
to resolve to the same model on the same server every time — model id, provider, base URL, key —
and the agent maps it onto a `RubyLLM::Context` of its own. The bundle matters most on a model
switch: ruby_llm's `with_model` swaps only the model against the chat's *existing* connection, so
switching to a model on another server without the connection travelling along sends the new
model's id to the old server's URL with the old key.

A switch in the gem is `conversation.switch_model(transport)`. A running turn finishes on its own
model; the last pick before the next turn wins, picking the current model undoes a pick, and the
switch happens at the next turn's start — after the gem has checked the next model can take the
turn's attachments, so a refused image never strands a half-applied switch.

## The parameter your model needs and pikuri doesn't name

The bundle carries one more thing, for the same reason it carries the URL: a request key that is
a property of *this model on this server* and of nothing else.

The canonical one is thinking. A local Qwen 3.6 reasons before every answer, which is what you
want for a hard question and ruinous for a short one. Asked for a few-word conversation title, it
spent 31 seconds and 625 completion tokens, and in one of eight tries put four thousand characters
of chain-of-thought where the title went. With reasoning off, the same eight titles took 1.2
seconds and 8 tokens. (Measured when pikuri-webui's titler was built; not re-run for this
chapter.) No prompt turns it off. A request parameter does:

```ruby
Pikuri::Agent::ChatTransport.from_openai_server(
  server: 'http://localhost:8080',
  model:  'unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M',
  params: { 'chat_template_kwargs' => { 'enable_thinking' => false } }
)
```

`params` lands in the request body as written, and pikuri doesn't know what it means. There is no
`thinking: false` flag, because "off" has no single spelling: llama.cpp reads that kwarg, OpenAI
reads `reasoning_effort`, Anthropic a `thinking` object. A flag would have to guess, and a wrong
guess doesn't raise: `reasoning_effort` on llama.cpp is accepted and ignored, and you get the
four-thousand-character essay while your code says thinking is off. That's also why the `Titler`
keeps its character cap and logs the first title that cost reasoning tokens: a thinking-off
parameter fails silently, and the cap is what catches it.

So the titler is the conversation's own model over a second transport that differs only in
`params`: one loaded model, both behaviours, no second copy of the weights
(`pikuri-webui:D_titler_connection`).

**And it asks after the first turn, not beside it.** Both apps used to ask for the title while the
answer streamed, so the title showed sooner. On a server with one slot, the title's request won
the permit and the answer waited for it, about 2 s, measured in pikuri-webui. Asked once the first
turn has ended, the turn's requests are done before the title asks, and the race is gone rather
than rarer. The cost is a date stamp in the sidebar until the first answer is in
(`D_title_after_turn`).

## A tool two agents can reach

You build your tools once at boot — one `web_search`, one `fetch`, one calculator — and hand the
same instances to every conversation's agent. Sensible, until two agents are inside one tool at
the same moment. That's why every pikuri tool's yardoc carries a `Sharing:` line naming one of
four postures:

- **`P_stateless`** — no mutable state; share freely. The calculator.
- **`P_shared_locked`** — process-wide state under a lock, shared on purpose. A search rate
  limiter *must* be shared: one per agent lets twenty agents fire twenty requests from one IP and
  earn the ban it exists to avoid.
- **`P_shared_benign`** — unguarded process-wide state whose race is harmless, with the race
  named: two callers miss the same cold URL-cache key and write identical bytes.
- **`P_one_agent`** — one conversation's state, so one agent. The task list: agent A's todos are
  not agent B's, and wiring one list into two agents is a correctness bug before it's a race.

So tool construction splits in two, and the second half goes in your `AgentInitializer`. The
gem asks it for each agent it builds: `system_prompt` for the prompt, and `configure` — the
`Agent.new` block, called after the gem has wired what it owns — for the tools:

```ruby
class Chat
  include Pikuri::Conversations::AgentInitializer

  SHARED_TOOLS = [Pikuri::Tool::CALCULATOR, Pikuri::Web::FETCH]   # built once, at boot

  def system_prompt(_conversation) = 'You are a helpful assistant.'

  def configure(c, _conversation)
    SHARED_TOOLS.each { |t| c.add_tool(t) }
    c.add_extension(Pikuri::Tasks::Extension.new)                  # P_one_agent: per conversation
  end
end
```

An interface rather than a pair of lambdas: the arguments each method gets have names and
types you can look up, and one object can hold what both need. It comes with each conversation,
to `open`, beside its `Saver`: an app with one object per conversation passes that object as
its listener, initializer and saver alike, and one with a single `Chat` passes it every time.

Nothing enforces the split; the `Sharing:` line is the contract. Thread-safe is no licence to
share, either: a per-conversation thing that happens to hold a lock is still per-conversation.

The same reasoning is why the gem never closes an idle conversation's agent to free memory and
rebuilds it later. The rebuild would keep the messages and lose everything else: the task list,
activated skills, and what each MCP server held — its tools come back, the browser it had logged
in does not (`D_no_idle_eviction`).

## A conversation is a thing you store and switch

Someone closes the tab and comes back tomorrow, or switches between two conversations in a
sidebar. So a conversation has to leave its agent and come back.

It leaves as a `Pikuri::Agent::History`, a plain value: `agent.export_history` hands it out and
`Agent.new(history:)` takes it back. pikuri has no file format, since a deployment that never
resumes shouldn't carry one; the gem does. `HistoryFile` writes a history as a folder — the
messages as one JSON file, attachments beside them named by their digest — and reads it back
through validators only (`D_history_file`). `Store` keeps one such folder per conversation under
a root, with a `meta.json` for the title, timestamps and the model it ran on.

The gem never saves on its own. It calls your `Saver`'s `save(conversation, history)` after every turn — completed,
cancelled, failed, or cut short by a quit — on the turn's thread, *before* the conversation goes
idle. So "idle" means "saved", and a cancelled turn keeps what was said.

What the history doesn't hold is the transcript. Your UI renders the *event stream* —
`ToolCall`, `ToolResult` and friends — and that rendering is lossy on purpose: results truncated,
injected blocks collapsed to one line. So the transcript can't be rebuilt from the history, nor
the history from the transcript; they are two artifacts, and the transcript is the app's.
Redrawing a stored conversation is still each app's own code today: pikuri-webui replays the
history as the events a live turn would have sent, through the same renderer; Puri builds its
blocks from the messages directly.

## Wiring it

All of it together, as a sketch; `# ...` marks what is the app's business:

```ruby
require 'pikuri-conversations'

Pikuri::Conversations::Throttle.limit('http://localhost:8080', 1)   # or let /props size it

store  = Pikuri::Conversations::Store.new(root: File.expand_path('~/.local/state/my-chat'),
                                         shell: 'my-chat')
titler = Pikuri::Conversations::Titler.new(transport: thinking_off, params_declared: true)
entries = {}   # id => Store::Entry

class Saving
  include Pikuri::Conversations::Saver

  def initialize(store, entries) = (@store, @entries = store, entries)

  def save(conv, history)
    model = conv.status.model                   # the model the turn ran on
    @store.save(@entries[conv.id], history, model: model.model, server: model.api_base)
  end
end

convs  = Pikuri::Conversations.new(titler:)
chat   = Chat.new                                        # the tool split above
saving = Saving.new(store, entries)

entry = store.find(id) || store.create
entries[entry.id] = entry
conv = convs.open(id: entry.id, transport:, listener:, initializer: chat, saver: saving,
                  history: store.history(entry), untitled: store.stamp_titled?(entry))

conv.submit('how do I keep an avocado?')   # => :started
conv.submit('also, ripe?')                 # => :injected
conv.cancel                                # the turn ends TurnEnded(:cancelled), saved
convs.shutdown(timeout: 5)                 # on quit: cancel, save, close every agent
```

The `listener` hears the agent's events and the conversation's own: `Ready`, `TurnStarted`,
`TurnEnded`, `PendingChanged`, `Titled` — on which the app calls `store.retitle` — and `Closed`,
the last. It's called from the gem's threads, so a GUI marshals onto its UI thread; pikuri-tui
does it with Tuile's `event_queue.submit`. If the listener re-renders Markdown on every streamed
delta, wrap it in `RateLimitedListener` to cap that at 15 frames a second.

## The takeaway

If you're building a chat app on pikuri:

1. **One call into an agent at a time**, from any thread; never key anything off
   `Thread.current`. Cancel and inject are the only doors in from elsewhere.
2. **Reset the cancel where the turn starts**, under the lock that says it started — or let the
   gem do it. One line late, and 500 of 500 early cancels were lost.
3. **A message typed mid-turn joins the turn**, and a cancel keeps what it hadn't delivered.
4. **Throttle per request, per server, process-wide** — never per turn, never with a bounded pool.
5. **Never call out under your own lock.**
6. **A connection rides the transport**, `params` included; never `RubyLLM.configure`.
7. **Split tool construction** by the `Sharing:` line.
8. **The history is pikuri's, the transcript is yours**, and saving happens before idle.

## What's next

The book ends here. From here, the apps read directly:
[pikuri-webui](https://github.com/mvysny/pikuri-webui) is the reference host, and
[pikuri-tui](https://github.com/mvysny/pikuri-tui) the smallest, one conversation in a
terminal. The gem's own [architecture](../pikuri-conversations/design/architecture.md) has the
state machine, the threads and a turn's steps, and `design/decisions.md` has why each is shaped
the way it is.
