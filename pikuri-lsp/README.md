# pikuri-lsp

Language intelligence for a [pikuri](https://codeberg.org/mvysny/pikuri)
agent: the questions grep cannot answer — *where is this defined*, *who
calls it*, *what does it inherit from* — asked of a real language server
and relayed back verbatim.

**Read-only by construction.** No formatting, no code actions, no
diagnostics push, no rename, no workspace edits. The gem is named after
what it refuses to become: the moment it applies an edit it needs the
`Confirmer` seam and stops being a closeable, auditable piece.

> **Status: young.** Everything below is in and wired — `bin/pikuri-code`
> builds its registry from the `lsp_servers:` key of
> `~/.pikuri-examples-config.yaml`, and one `c.add_extension` does the same
> for any other host. [`design/architecture.md`](design/architecture.md) carries the threat model and
> the measurements every call here rests on, `../design/decisions.md` its five
> LSP forks, and [the language-intelligence chapter](../book/lsp.md) the
> teaching walk-through.

## What is here

| class | what it does |
| --- | --- |
| `Pikuri::Lsp::Connection` | JSON-RPC over one pair of IOs: framing, id demux on a reader thread, `null` replies to server-initiated requests, no timeout |
| `Pikuri::Lsp::Position` / `Range` | pikuri's 1-based line/character coordinates, converted to and from the wire's 0-based encoded offsets in exactly one place |
| `Pikuri::Lsp::PositionEncoding` | the `utf-8` / `utf-16` / `utf-32` offset arithmetic — mandatory, because jdtls ignores the `utf-8` offer |
| `Pikuri::Lsp::Location` | both wire shapes (`Location` and `LocationLink`) behind one value type |
| `Pikuri::Lsp::Uris` | `file:` URI ↔ path, and the scheme sniff that says "this result is not a file at all" |
| `Pikuri::Lsp::ServerProgress` | the domain event a host draws a progress bar from while a cold index runs |
| `Pikuri::Lsp::ClientWrapper` | one server's lifecycle: spawn, handshake, what it advertises, restart after a death, teardown |
| `Pikuri::Lsp::Registry` | which servers exist, which files each claims, and `.from_h` to build that from a host's own config file |
| `Pikuri::Lsp::Readiness` | the indexing gate: no progress token open and nothing said for a moment, blocking with no timeout so a mid-index query cannot be answered wrongly |
| `Pikuri::Lsp::Mailbox` | the thread boundary the gate needs — newest value per key, so a three-minute wait reports current state instead of replaying a backlog |
| `Pikuri::Lsp::Servers` | one client per registry entry, started on first use, plus the routing that picks the server a file belongs to |
| `Pikuri::Lsp::LspTool` | the `lsp` tool: ten operations, `symbol` + optional `file`/`line`, and never a column — see below |
| `Pikuri::Lsp::Extension` | wires the tool onto an agent, arms the teardown, and points the progress events at the agent's event stream |
| `Pikuri::Lsp::Testing` | a scripted fake server and a hand-framed wire, so a host can test its integration with no language server installed (`require 'pikuri/lsp/testing'`) |

`bin/pikuri-lsp-check` is a dev diagnostic, not part of the gem: it runs
the measurements this design rests on against the language server you
actually have installed, and reports *ok* / *DRIFT* / *could not ask* per
probe. Run it after a server upgrade — the specs cannot catch a server
that changed its mind.

It probes two layers, because a fault in one is invisible from the other.
By default it drives the protocol client. `--drive` drives the `lsp` tool
instead: it prints the observation the model would read for every
operation, then checks what a rendered answer owes — no repeated rows,
every printed path openable. That is the layer where `Navigator`, `Anchor`,
`Sources` and `Renderer` live, and a duplicate-row bug that every protocol
probe passed through is what put it there.


## The tool, in one paragraph

One tool with an `operation` enum of ten values —
`goToDefinition`, `findReferences`, `hover`, `documentSymbol`,
`workspaceSymbol`, `goToImplementation`, `goToTypeDefinition`,
`incomingCalls`, `outgoingCalls`, `supertypes`. The model passes a
`symbol` and, ideally, the `file` and `line` it read it on; **the column
is derived from that line's text and never asked for**, because nothing
the model has seen contains one and a column off by seven turned one
measured `findReferences` into 80,609 results. A bare `symbol` is looked
up in every server's index instead — best effort, honestly reported when
it resolves nothing. Multi-hop operations (the call pair, the ancestor
chain) run their `prepare` and their per-level walk inside the tool, so
the model never holds an opaque protocol item. Results are capped and
grouped, a result inside a dependency archive is fetched and shown as its
type name, and a remote URI is printed but never fetched.

## Three rules it is built to

1. **Relay, don't work around.** Every language server is broken in its
   own way and the ways do not generalize, so the tool reports what the
   server said and the model decides what to do about it.
2. **Never collapse three answers into one.** *The server does not
   support this*, *the server answered nothing*, and *the server is not
   ready yet* stay three distinct strings. Merging them is how a shipped
   client teaches a model that a symbol has no definition when in fact
   the index was still building.
3. **No fallback steering.** An error says what failed. It never
   suggests grep.

## License

MIT, as the rest of pikuri.
