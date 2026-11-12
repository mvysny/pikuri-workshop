# pikuri-tasks

In-memory task list + four LLM-facing tools for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

Provides:
- `Pikuri::Tasks::List` — per-Agent in-memory list of
  `(id, content, status)` items. Status is one of `pending`,
  `in_progress`, `completed`. Nothing is written to disk.
- Four tool classes, all sharing one `List` instance:
  - `Pikuri::Tasks::Create` (`task_create`) — mass-create pending
    items from a JSON array of strings. Atomic: if any element is
    blank or a duplicate (within the batch or already on the
    list), nothing is added.
  - `Pikuri::Tasks::InProgress` (`task_in_progress`) — mark an item
    as `in_progress` by numeric id.
  - `Pikuri::Tasks::Completed` (`task_completed`) — mark an item as
    `completed` by numeric id.
  - `Pikuri::Tasks::Delete` (`task_delete`) — remove an item by
    numeric id.
- `Pikuri::Tasks::Extension` — wires the four tools + a brief
  `<tasks_usage>` workflow snippet into a `Pikuri::Agent` via the
  `c.add_extension(...)` block API.

Two shape choices worth flagging:
- **Status is baked into the tool name** (no `status:` parameter
  with an enum). Removes the `"in-progress"` vs `"in_progress"`
  vs `"inprogress"` typo failure mode.
- **Items are addressed by numeric id** — assigned on create,
  shown in every rendered list, never reused after a delete. A
  near-miss when re-typing the task's content cannot lock the
  model out of its own list; duplicates are still rejected on
  `task_create` because they are almost always a mistake.

## Install

```ruby
# Gemfile
gem 'pikuri-tasks'
```

## Usage

```ruby
require 'pikuri-core'
require 'pikuri-tasks'

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension(Pikuri::Tasks::Extension.new)
end
```

The extension's `configure` constructs a fresh `Tasks::List`,
registers all four task tools against it (so they mutate the same
instance), and appends a short `<tasks_usage>` snippet to the system
prompt explaining the workflow (create at the start, exactly one
`in_progress` at a time, `completed` only after verification).

Every mutation returns the full rendered list as its observation,
so the LLM always sees fresh state without a separate read tool:

```
<tasks>
- #1 [pending] Add dark mode toggle
- #2 [in_progress] Write unit tests
- #3 [completed] Update README
</tasks>
```

Empty renders as `<tasks>(empty)</tasks>` so the LLM gets an
unambiguous "the call worked and the list is now empty" signal.

Sub-agents do **not** inherit extensions — a sub-agent spawned by
the `agent` tool gets a fresh persona and no task list. The
parent's plan stays private to the parent.

## Further reading

- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-tasks> (once published), or
  run `bundle exec yard` in this directory for a local copy.
