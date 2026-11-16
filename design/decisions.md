# Decisions

Why the workshop is the way it is and not otherwise — FAQ-shaped: each entry is a question and
its current answer. Rewrite the answer when it changes; delete the entry when nobody asks any
more. **A reversal is a rewrite**, never a second entry and never an amendment note: the counter-
arguments become the replacement's why-not clauses, and a reversal to *nothing* is a standalone
why-not question. An entry is earned by what happened, not by having had an alternative — either
it **shaped what the workshop is**, or it **cost research the next person would otherwise redo**
(cited as its `R_`). Not an entry: windows → panels "because that's the trend", this red over
that red, `get_foo` over `is_foo?`, the testing library, the CI host, a version bump — a comment
at the site of the choice, or nothing. Nothing about `design/` itself is an entry, and nothing not
yet decided — that lives in `design/ideas/`. Cite by slug, `D_<slug>`, never by position; a
decision of pikuri's is `pikuri:D_<slug>` and lives in pikuri's `design/decisions.md`.
`grep '^## D_' design/decisions.md` is the index. The founding entry, `D_separate_repo`, comes
first. An entry is as long as its question needs: every road not taken keeps all of its losing
reasons. When you have written an entry, re-read it against the one above for consistency, and
open the doc comments it touches and delete what they already say.

---

## D_separate_repo — Why is the workshop a repo of its own, pinned to a pikuri commit, rather than more gems in pikuri?

**Context.** Until 2026-11 these eight gems lived in pikuri's monorepo. Every integration added
a gem, a release target, a book chapter and a share of a capped `AGENTS.md`, and pulled pikuri
two ways: stay simple enough to teach in an evening, and grow complete enough for bash's
tokenizer, a sandbox, MCP's container model and a language server's build evaluation.

**Decision.** pikuri keeps the gems you would run on your host with your real data, and whose
future is "explain it better". A gem that needs a cage, or whose future is more features, lives
here. The workshop is "just" an app built on pikuri: its `Gemfile` pins one pushed pikuri
commit by sha, its gemspecs pin the pikuri release they were built against, it releases on its
own cycle, and its tooling (`rake check`, `rake release`, both tripwires) is a copy that evolves
on its own. Dependencies point from here to pikuri, never back.

**Alternatives rejected.**

- **One repo, two books.** Every gem would still answer to "readable in an evening" and to the
  trifecta promise, which a coding agent holding all three legs can't keep.
- **pikuri's `master` branch, with a Bundler local override to `../pikuri`.** The pin lived only
  in `Gemfile.lock`, and the override moved it silently: on the first day it pointed the lock at
  a pikuri commit not yet pushed, which CI could never fetch. A sha in the `Gemfile` is visible,
  and moves only when someone edits it.
- **A shared version and release.** A rename in pikuri breaks the workshop until it catches up
  either way; a shared number only hides that, and spends a release on gems that didn't change.
- **Renaming the gems `pikuri-workshop-*`.** A name is tied to its namespace and entry file, so
  it churns every constant, and the placement rule can move a gem back to pikuri.

---

## D_lsp_direct_not_mcp — Why write the LSP client rather than bridge somebody else's through MCP?

**Context.** `pikuri-mcp` already exists, and maintained LSP↔MCP bridges do
too: isaacphi/mcp-language-server, Tritlo/lsp-mcp, bug-ops/mcpls,
ProfessioneIT/lsp-mcp-server. Wiring one would have been a *registry entry*
— config, not code — buying every language at once and letting someone else
absorb protocol drift. Their pitch is correct, too: a semantic answer costs
~50–200 tokens against dumping a file at the model.

**Decision.** A direct stdio JSON-RPC client, in its own gem, reusing
`Mcp::ClientWrapper`'s restart discipline rather than its transport.

**Why — four reasons, and the first is the one that generalizes.**

- **The transport is not the hard part.** Both paths terminate at the same
  `ruby-lsp` process over the same stdio JSON-RPC; the bridge adds a hop and
  a process. The actual difficulties — indexing readiness, capability
  gating, name→position, result capping, coordinate conversion — get solved
  somewhere either way, and through a bridge you inherit someone else's
  answers to all five with no way to correct them.
- **Two seams cannot be delegated at all.** `F_definition_candidates` and
  `F_reference_volume`: denylist filtering of walked paths, root
  confinement, and volume capping are post-processing pikuri must write
  regardless. At which point most of a client exists anyway, and the extra
  process is still being paid for.
- **It inverts the bounded-gem rule.** A direct client has a closeable
  threat model — read-only, no network, one long-lived child
  (`pikuri-lsp/design/architecture.md`). A third-party bridge is an opaque Go/TS/Rust
  binary with its own network posture and supply chain: widening the threat
  model to save ~200 lines of Ruby, in a project whose bar is "small enough
  to audit in an evening", and dragging a non-Ruby toolchain into a Ruby
  monorepo.
- **Teaching mandate.** A small LSP client is a good book chapter about how
  editors actually work. "Install this Go binary" teaches nothing.

**Rejected: depending on `language_server-protocol`.** The one plausible
Ruby dependency, and it is a *protocol SDK*, not a client: framing plus typed
structures, no lifecycle, no id correlation, no spawn, and an `Io::Reader`
shaped as a blocking whole-stream callback loop for a server's main loop. It
would have supplied forty lines of framing whose reader shape pikuri then
fights. Nothing else on rubygems is a client at all — `lsp-client` is a
35-byte empty placeholder, and every other promising name is a *server*,
because LSP clients live in editors and editors are not written in Ruby.

**Consequence.** Protocol drift is pikuri's problem now. That is what
`bin/pikuri-lsp-check` is for — a human-run diagnostic that re-measures the
findings in `pikuri-lsp/design/architecture.md` §Measurements against a live server and
reports *ok* / *DRIFT* / *no answer*, rather than a spec that goes green by
skipping.

---

## D_lsp_operation_surface — Why these ten LSP operations, and why relay a server glitch rather than work around it?

**Context.** Six live runs against ruby-lsp and jdtls found a real pattern,
and then the pattern turned on the method that produced it: *every server is
broken in its own way, and the ways do not generalize.* ruby-lsp advertises
a type hierarchy whose `subtypes` half is a `# TODO` (`H_subtypes_stub`);
jdtls's `workspace/symbol` cannot see a method at all
(`S_jdtls_types_only`); ruby-lsp crashes on a full-text `didChange` that
jdtls accepts (`S_rangeless_didchange_crash`); ruby-lsp's index
desynchronizes from its own document because of a typing-speed heuristic
(`S_index_desync`). There are language servers for thirty other languages,
each with its own list.

**Decision.** Two rules, and they are the same rule twice.

1. **The operation surface comes from harnesses that shipped one**, not from
   what two servers happen to implement. Claude Code and opencode ship an
   identical nine (near-identical tool text too, so they count as roughly
   one data point); grok-build ships six, a strict subset. pikuri ships that
   union plus two *measured* additions and one collapse:
   `goToTypeDefinition` (`J_type_definition_recovers_var`: with
   `var names = new ArrayList<>()` the type appears nowhere in the source,
   so nothing else recovers it), `supertypes` (`H_supertypes_no_substitute`
   — the one hierarchy operation that works on both servers, and the *chain*
   is what has no substitute), and `prepareCallHierarchy` run inside the
   tool rather than exposed.
2. **Server glitches are relayed, not worked around.** The tool reports what
   the server said and what it was asked; the model decides what to do about
   it. Three answers must stay distinct in what the model reads: *the server
   does not support this operation*, *the server answered nothing*, and *the
   server could not be asked*. Collapsing them is the most consequential
   defect in the shipped prior art — Claude Code's
   `No definition found. This may occur if…` is `F_empty_before_index`'s
   false premise verbatim.

**Rejected: an enum sized to what the two reference servers implement.**
That is a catalogue of two servers' glitches, and it says nothing about the
third. It also gets the answer wrong in both directions: `documentSymbol`
would have been cut (all three harnesses ship it, and `S_jdtls_types_only`
makes it the only route from a Java method *name* to a position), while
`subtypes` would have been kept.

**Rejected: a per-server known-stub list.** The obvious fix for
`H_subtypes_stub` — record that ruby-lsp advertises `typeHierarchyProvider`
but implements only half of it. It is unbounded work that gets one server
right, and a capability gate provably cannot catch the case anyway: one
provider key covers both directions, and ruby-lsp advertises it *truthfully*
for the half that works. With `subtypes` cut the case no longer arises, and
where it would, the answer is to relay the empty result.

**Rejected: per-server readiness predicates.** Closed by
`J_jdtls_defers_replies`: jdtls defers its replies during an import instead
of answering `[]`, so a false-early gate is harmless there and essential
against ruby-lsp. One generic quiescence-plus-debounce gate covers both, and
the feared config knob is not needed.

**Rejected: `subtypes` as an eleventh operation.** It went first to
`H_subtypes_stub`, then to the harness survey (nobody ships it), and finally
to `H_implementation_is_transitive` / `H_subtypes_direct_only`: on jdtls,
`goToImplementation` answers "list all subtypes" transitively in one call
and works on concrete classes, while `typeHierarchy/subtypes` returns the
direct children only. So there is **no server on which `subtypes` is the
best available answer**, and `findReferences` is not the substitute either
(`H_references_not_substitute`: exactly 1 of 4 hits was the `extends` site,
unlabelled).

**Rejected: exposing `prepareCallHierarchy`.** The one place pikuri narrows
a 2-of-3 majority. Exposing it hands the model an opaque
`CallHierarchyItem` to echo back; the prepare hop runs inside the tool, the
same collapse `workspace/symbol` gets.

**Also out, recorded so nobody re-proposes them:** `declaration` (marginal
against `definition` outside C-style header/impl splits), `completion` (an
agent writes whole files rather than completing at a cursor), and the whole
write half — `rename`, formatting, code actions — which needs the
`Confirmer` seam and ends the closeable threat model. Diagnostics are
deferred rather than rejected: all three harnesses surface them *without* a
diagnostics tool, as reminders appended to tool output.

---

## D_lsp_no_startup_timeout — Why is there no startup timeout anywhere in the LSP client?

**Context.** ruby-lsp indexes this repo in seconds; a cold jdtls import of a
Gradle multi-module project took 78 seconds (`J_warm_start`), during which
every request went unanswered until the backlog flushed
(`J_jdtls_defers_replies`). The obvious fifth registry field is
`startup_timeout:`.

**Decision.** No `startup_timeout:`, and no timeout at all. The first call
blocks until its server is ready, however long that takes.

**Why.** No value is defensible — 30s is wrong for Java, 300s is wrong for
Ruby — and what a timeout buys is a `"still indexing, try grep"`
observation, which is not information but a *decision point*: retry, wait,
or give up. "Wait" is the correct answer and the one thing no tool call can
express. Relaying an empty index state is the single case where waiting
beats relaying, because there is nothing in `[]` to reason about — and
`F_empty_before_index` is what an un-gated client hands the model instead: a
*successful* empty answer, from which it concludes the symbol has no
definition.

**Three things replace the clock, none of them a clock.**

- **Die on child death.** What a timeout actually guards is not a slow index
  but a server that never becomes ready: jdtls failing a dependency import,
  ruby-lsp's custom-bundle `bundle install` erroring, a second session
  finding the `-data` directory locked. Child exit is a *definite* answer
  and catches the common case earlier than any clock would.
- **`Cancellable` breaks the wait.** A blocking read never reaches a
  tool-call boundary, so a host's SIGINT trap would not fire; the wait polls
  the cancel flag. This is what makes "endless" acceptable — the human is
  the timeout, through a mechanism pikuri already has.
- **Progress is a domain event.** A silent three-minute stall is
  indistinguishable from a hang for the person watching. Not optional once
  the clock is gone.

**Rejected: a failure message that steers.** The death report says what
failed and stops: it never says "try grep". That would be the
`"still indexing, try grep"` observation arriving by a different door — a
failure message deciding the task's next step, when the model is the one
holding the task.

**Consequences.** *Spawn synchronously at boot* was the original companion
to this — cheap, and it made a missing binary raise immediately and loudly.
It was reversed on 2026-08-18 in favour of starting a server on **first
use**: a registry is machine state (which binaries you have installed), so
an unconditional boot spawn starts a JVM and a 78-second import in projects
containing no Java at all. Missing-binary loudness moves with it — first use
reports `"Error: cannot spawn ruby-lsp: …"` and the model relays it to the
human, which is one policy instead of two. What the reversal does *not*
touch is what this entry is about: indexing proceeds in the background and
the first call blocks, unbounded.

---

## D_lsp_scheme_fallback — Why one hardcoded `jdt:` row rather than a general URI-scheme fallback?

**Context.** A result is not always a file. jdtls answers a library
definition with
`jdt://contents/slf4j-api-2.0.18.jar/org.slf4j/LoggerFactory.java?=…`
(`J_library_is_not_a_file`) — a *handle, not a locator*, an index into that
server's own view of the classpath, closer to a file descriptor than a path
and meaningless to anything else. **There is no standard "read this URI"
request in the LSP that ships today, and no way to discover a server's
non-standard one**: `language_server-protocol` 3.17.0.6 does not mention
`textDocumentContent`, and jdtls, `zipfile:`, `deno:` and `sourcekit-lsp:`
each invented their own, documented in prose and announced nowhere on the
wire.

**Decision.** Every result renders as location + snippet, and the URI scheme
decides where the snippet comes from. Three tiers: `file:` is read through
the `Workspace` seam (with `Filesystem#denied?` applied, since a result is a
*walked* path — `pikuri:D_walked_path_denylist`); a custom scheme is asked of the
**server that issued it**, standard 3.18 `textDocumentContent` first and one
hardcoded row second; `http(s):` and everything else is printed as text,
never dereferenced. A scheme with no row gets an inline reason, never a bare
count.

**Why the `http(s):` refusal is load-bearing rather than decorative.**
Fetching a URI the *server* chose would hand the gem an
attacker-influenceable egress leg, with the request itself as the
exfiltration channel — the data rides in the path. A dependency that names a
URL in its source map would break the gem's entire claim. pikuri already has
`fetch` and `web_scrape` for network reads a human asked for. The table may
therefore never gain a row that reaches the network; every row is a JSON-RPC
request to a child pikuri already spawned over a pipe it already owns, which
is what `D_lsp_trifecta_legs` leans on.

**Rejected: standard-only, no fallback row.** The principled position — the
protocol layer stays server-agnostic — and it makes the Java arm untestable
in practice: without the row, `J_init_options_required` and
`J_class_file_contents` compose into "library navigation returns a polite
refusal", which is the capability the typed half of the target was for.

**Rejected: a `content_request:` config field.** The same fallback,
parameterized: two arcane coupled strings the user must get right, in a file
format pikuri exists as a counter-move to. A protocol method is code, not
config — grok-build's C#-specific `solution/open` escape hatch is the same
mistake in a different costume. The table is a different animal: the user
writes nothing, it is named after a server rather than parameterized over
all of them, and it carries a **written deletion condition — delete the
`jdt:` row the day jdtls advertises `textDocumentContent`**, at which point
the standard path above it takes over with no other edit.

**Rejected: an `lsp_read` operation or tool.** The tempting shape — hand
back a URI, let the model ask for its text — reintroduces exactly the
chaining hop collapsed everywhere else, spends a round trip on something the
tool can do exactly, and hands the model a ~300-character `jdt:` URI to hold
and reason about. The tool inlines content itself, on the same path for both
the standard request and the fallback. If explicit loading is ever wanted it
lands as another `operation` enum value, not a second tool — and the
question to answer *then* is that inlining and explicit reads are not rivals:
a bounded snippet per result keeps `definition` usable
(`J_class_file_contents`'s 22 KB × the 45 hits `F_reference_volume`
measured), while an explicit operation is how the model asks for a whole
document.

---

## D_lsp_hover_file_uris — Why rewrite the `file:` URIs inside hover prose?

**Context.** `hover` is the only one of the ten operations whose answer is
*prose* rather than rows. The other nine come back as `Location` /
`SymbolInformation` / `CallHierarchyItem` structures, and every one of them
renders through `Sources#label_for` and `Sources#denied?`. Hover's `contents`
is one opaque markdown string — the server has already flattened its own
structure into it, so there is no link list to walk. ruby-lsp fills that
string with VS Code file links:

```
**Definitions**: [version.rb](file:///home/m/proj/lib/version.rb#L9,3-9,20)
```

Three things are wrong with passing that through. It is a **walked path that
reaches no `denied?` pass** (`pikuri:D_walked_path_denylist`), so a definition
inside a credential root prints its absolute path. It is a **dead-end
citation** — the `read` tool takes neither a URI nor a `#Lline,col` fragment
— while nine other operations spent their design on printing a path the
model can act on. And it is **expensive**: hover's whole value is quoting a
class comment, `MAX_HOVER_BYTES` is 3 KB, and each link burns ~90 bytes of
absolute path ahead of the documentation.

**Decision.** Every `file:` URI in the blob is rewritten, before the
truncation so the cap is spent on prose. Denied → a bracketed refusal, the
link dropped whole. Readable → the `label_for` citation with the fragment's
line, `path:line`, keeping its markdown link. Neither → the label alone
(`outside the workspace: entry.rb`), no link. A URI that arrived bare stays
bare. The rule in both directions: **never invent a link that was not there,
never keep one whose target `read` would refuse.**

**Rejected: pass it through as it came.** The renderer's own stated posture
(`D_lsp_operation_surface`) — pikuri cannot pre-empt thirty servers' failure
modes, so it relays glitches rather than smoothing them. That rule is about
a server's *behaviour*, though, and this is pikuri's own denylist obligation
arriving through a shape the row path does not cover. The rule still holds
for every byte that is not a `file:` URI.

**Rejected: parse ruby-lsp's `**Definitions**` line.** It knows the most
about the markdown and generalizes the least: the heading is ruby-lsp's own
invention, gopls emits no links at all, rust-analyzer emits different ones.
A scan keyed on the *scheme* treats all thirty servers alike and no-ops on a
server that emits nothing.

**Rejected: a bare or backticked citation, dropping the link.** Cheaper
still, and consistent with how a row cites. The link earns its ~15 bytes by
saying *this is a file that exists* — and once the refused and denied cases
degrade to plain text, link-presence carries the same signal `label_for`
already encodes, rather than a second one to learn.

**Rejected: keeping the `#L9,3-9,20` fragment.** It is VS Code's convention
for an editor that will place a cursor, and it carries **columns** — which
the whole tool refuses (`symbol`, never a column) and which produced a real
bug: two results differing only in column rendered as one row and counted
twice (`E_same_line_references`). A model finds the symbol on the line.

**Rejected: extending the scan to `jdt:`.** `Sources` can already label one
(`java.lang.String (rt.jar)`), so the objection is not semantic — it is that
a `jdt:` URI carries an entire classpath entry in its query, runs to ~300
characters and has **no reliable end inside a sentence**, where a `file:`
URI stops at whitespace or `)`. `http(s):` stays untouched for a different
reason: a URL in a docstring is prose, not a result, and it is never
dereferenced either way (`D_lsp_scheme_fallback`).

---

## D_lsp_document_sync — Why re-open the document around every LSP call rather than send an edit stream?

**Context.** LSP's document model assumes the client is a text editor: you
`didOpen` a document, stream `didChange` edits as a human types, and the server
holds a buffer the disk may not have seen for hours. An agent inverts that at
the root — `write` and `edit` land on disk immediately, so the tool never owns
text the disk lacks. Yet the servers still presume that *a client which opened a
URI is that document's authority* (`S_watched_files_ignored`, stated outright in
ruby-lsp's source), which is exactly the assumption an agent writing straight to
disk breaks.

**Decision.** Re-send `textDocument/didOpen` with the file's current disk text
before every position-based call, and `textDocument/didClose` once that call's
last reply is in (`S_reopen_works`). No open-URI set, no version counter, no
digest. Re-opening a document already open is spec-forbidden — *a document must
not be opened twice* — and neither reference server minds; balancing the pair
per call is what keeps that the only deviation.

**Why the alternatives all lost, one measurement each.** The first is not
spec-legal and the rest are.

- **Rejected: a rangeless whole-document `didChange` — and it was never ours to
  send.** The obvious "here is the new text" move leaves jdtls correctly updated
  and *crashes* inside ruby-lsp, which reads `edit[:range][:start]`
  unconditionally (`S_rangeless_didchange_crash`). The document keeps its old
  text, a notification has no reply channel, and the only report is a
  `window/logMessage` line — what the model sees is the next query failing with
  a raw backtrace. Both visible harnesses sync this way, and grok-build's own
  `capabilities.rs` opens by describing the same failure against *Roslyn*: the
  finding independently confirmed on a third server. But the reason it loses is
  the contract, not the crash. Both servers advertise **incremental** sync, and
  `TextDocumentSyncKind` is the *server's* declaration of which arm of the union
  it accepts — a client must support both so it can comply with either, never
  pick. Shopify closed that report three times (ruby-lsp #575, #1273, #3148; in
  #1273 the reporter wrote the ycmd client and came round to it), so a server
  that started tolerating the shape would still not make it usable. That is also
  why it is the one finding `bin/pikuri-lsp-check` does **not** probe: the
  response to a message the server never agreed to accept is undefined, so no
  outcome could inform this decision.
- **Rejected: the ranged whole-document `didChange`.** Honoured by both servers
  for the document, and then it desynchronizes ruby-lsp's *index* from the
  document it just updated (`S_index_desync`): `documentSymbol` reports the
  renamed method while `definition` on it returns `[]`. `RubyDocument#should_index?`
  reindexes only when the edit's start position looks like a declaration, and a
  whole-file replace starts at 0:0 — the `frozen_string_literal` comment. The
  optimization that makes editor typing cheap makes whole-file replacement
  invisible.
- **Rejected: `didClose` and forget.** Drops ruby-lsp's store entry so the next
  request re-reads disk, and does nothing at all on jdtls, which keeps answering
  its pre-close copy (`S_didclose_ruby_only`). Not portable, which is what
  promotes re-opening from an option to the policy.
- **Rejected: `workspace/didChangeWatchedFiles`.** The spec's own out-of-band
  "the disk changed" channel changed nothing on either server while the client
  held the URI (`S_watched_files_ignored`).
- **Rejected: version or digest bookkeeping on top of the re-open.** There is
  nothing to reconcile when the text always comes from disk, and the bytes are
  already in hand: they are the text the tool read to derive the column.

**Rejected: opening without closing**, on the grounds that neither reference
server needs the close (`S_didclose_ruby_only`), so it buys nothing measurable.
Wrong shape of reasoning: the spec caps a document's open count at one and asks
for the pair, so a client that only ever opens is relying on two servers'
*tolerance*, which no amount of testing on more servers turns into a guarantee.
A pyls or gopls that trusted the count could leak a document per call, answer
from a stale buffer, or block. The close is sent because it is owed.

**Rejected: closing per request rather than per call.** `supertypes` and the
call-hierarchy operations issue a `prepare` hop and then a request per level
against one document, so a close after each request would hand the later ones a
document the server had already dropped. The pair brackets the whole
`Navigator#navigate`, in an `ensure`, so a refusal or a death still balances.

**Rejected: firing the close alongside the request.** "Immediately" has to mean
*after the reply*, not concurrently with it. ruby-lsp happens to be safe either
way — one worker thread, one incoming queue, strict order — but that is one
server's implementation detail, and a server answering requests in parallel
could process the close first and answer about a document it had just dropped.
Since `request` already blocks for its reply, waiting costs nothing.

**Rejected: restarting a dead child to deliver the close.** Every other
notification here retries through `with_restart`; this one must not. A dead
child holds no open documents and a respawned one never received the matching
`didOpen`, so a retry would deliver a close that only the new process finds
confusing. `close_document` checks liveness, swallows `Connection::Closed`, and
never raises — it runs from an `ensure`, where raising would replace a served
answer with a teardown failure.

**Consequence.** The re-open half rests on server behaviour rather than on the
specification, so it is pinned by a probe rather than by a reading:
`bin/pikuri-lsp-check`'s `S_reopen_works` row re-measures it against the
server actually installed, opening and closing as the library does. The close
half needs no probe — it is a contract, not a measurement, and the specs pin
the ordering against the fake server.

**Consequence — observing the agent's own edits is deferred, not open.**
grok-build also syncs from the *write* path (`notify_file_changed(path,
content)`), and pikuri should eventually too; the shape is settled so the
deferral is a scheduling choice:

- The event is emitted by `Workspace::Workspace`, beside the read-before-edit
  ledger it already owns, and bridged to `c.emit_event` in
  `Workspace::Extension#configure` — the `Tasks::Extension` shape. `WriteGate` is the
  wrong hook: it is stateless, it runs *before* the write, and a refused write
  must not notify.
- The payload is the path, never the bytes; every consumer reads content through
  the `Workspace` seam anyway.
- It must never be load-bearing. `bash`, `git checkout` and any build the agent
  runs also write files, so an edit notification is *structurally* incomplete —
  re-opening on read stays the correctness guarantee, the same split
  `pikuri:D_walked_path_denylist` draws between `denied?` and `denied_roots` pruning.
- The event fills a dirty set the next `lsp` call drains, coalesced per path, so
  a 50-file refactor is not 50 re-opens; that is also the second caller
  `Lsp::Mailbox` was waiting for.
- What it buys over re-open-on-read is one measured thing: a file the agent has
  just *created* is invisible to `workspace/symbol` until something opens it
  (`S_index_follows_didopen`), and under re-open-on-read nothing opens it until
  the model asks a position question naming that exact file — so symbol-only
  lookup of a just-written class fails. The other gains are softer: jdtls
  rebuilds ahead of the next call rather than during it, and this is the
  precondition for surfacing diagnostics after an edit, which all three
  harnesses do *without* a diagnostics tool (also deferred, per
  `D_lsp_operation_surface`). It changes no `pikuri-lsp` interface, so shipping
  it later costs one listener arm.

---

## D_lsp_trifecta_legs — Why is the `lsp` tool `:no_egress` when its child goes online, and `untrusted: :hard` unconditionally?

**Context.** `Mcp::Extension` declares `ASSUMED` unconditionally, and both
gems spawn a user-configured foreign stdio binary with inherited env and no
sandbox — so "why doesn't `lsp` declare what `mcp` declares?" is a fair
question with a non-obvious answer. One declaration, three axes, questioned
once.

**Decision.** `private:` rides the host's answer, `untrusted: :hard`
unconditionally, `egress_payload_review: :no_egress` — declared on the
*tool*, with `Lsp::Extension` contributing nothing.

**Rejected: tagging egress on the vetted-destination argument.** The
tempting version is that a well-behaved server only fetches from a vetted
set of hosts (jdtls pulling a jar from Maven Central), which is too weak to
tag. That argument must not be written down, because it argues for the
opposite of its conclusion: `pikuri:D_egress_axis_shape` rejected a
`:safe_vetted_set` rung outright, so "vetted destination" is a *rung* and
the phrasing lands `lsp` on the map as `:tool_vouched` + `:unreviewed`
forever. It is also untrue — the hosts come from the project's
`build.gradle` / `settings.xml`, so they are project-controlled. The
argument that survives is the one that entry used to drop
`egress_human_author`: a seat whose outbound bytes do not originate in the
model's choosing holds no leg to grade.

**Rejected: inheriting MCP's `ASSUMED` on the shared foreign-binary shape.**
The distinction that breaks the parity is that **an MCP server contributes
model-callable tools with model-supplied arguments; an LSP server
contributes none.** One pikuri-authored tool, fixed schema, and pikuri
chooses every JSON-RPC request that leaves — no foreign tool surface, hence
nothing undeclarable. Declaring `ASSUMED` anyway would actively *widen* the
answer: `legs | ASSUMED` flips egress to `:unreviewed` /
`:attacker_reachable` (verified), the opposite of the measured truth.

**Rejected: riding `filesystem.trusted?` the way {Pikuri::Workspace::Read}
does.** `read` declares `untrusted: filesystem.trusted? ? :none : :hard`,
and that works because the vouching and the reach are the same set: the host
asked a human whether this checkout is trusted, and `read` is confined to
the checkout. `lsp` is not — the index reaches the whole bundle, jars and
the JDK (`J_index_reaches_jars`), and `H_ancestry_leaves_root` has a query
about a workspace class answering out of four unrelated gems. A user who
said "yes, I trust this repo" made a claim about the code they checked out,
not about four hundred transitive jars, nor a `-sources.jar` nobody has ever
diffed. Riding `trusted?` would stretch a human's answer past the question
they were asked.

**Rejected: confining results to the root to earn `:none`.** The first thing
someone will propose when the map goes loud. It deletes
`J_index_reaches_jars` — searching inside jars, the one thing grep can never
do — so the tag is *the price of the capability*, not a defect to engineer
away.

**Consequence, stated because a user will otherwise meet it as an
unexplained alarm.** On an untrusted checkout nothing changes; `read` is
already `:hard` there. On a **trusted** one, adding `lsp` to a wiring that
holds `fetch` or `web_search` lights the untrusted leg and can flip the
trifecta verdict, because `read` declares `:none` there and `lsp` does not.
That is correct rather than unfortunate — the jars were never vouched for,
and a trusted repo with a poisoned dependency is the realistic attack — and
`pikuri:D_egress_axis_shape` already blesses declaring a true axis for the map's
sake when no verdict moves. This is the stronger case, where one does.

---

## D_lsp_per_agent — Why does every agent start its own language servers, when a server holds nothing a conversation produced?

**Context.** An agent is one conversation (`pikuri:D_agent_is_one_conversation`), so
`pikuri-code`'s `/clear` and every resume build a new agent, and `Lsp::Extension#configure`
builds a new `Servers` with it. jdtls is the expensive case: 78 s cold on a multi-module repo,
7.7 s warm with its data directory in a persistent cache (`book/lsp.md`). MCP had to split
into a shared catalog and per-agent connections because a server's *state* would otherwise leak
between conversations (`D_mcp_catalog_and_connections`); the question is whether LSP has the
same problem, and if not, why it doesn't share.

**It does not have the leak.** pikuri has no unsaved buffers: every call opens the document with
its disk text and closes it afterwards (`D_lsp_document_sync`), so the server's documents and
index are a cache of the disk, and a fresh server on the same root rebuilds the same cache from
the same files. The denylist is applied by `Sources` against each agent's own `Filesystem`, not
by the server. A server is bound to one root (`StdioEntry` has no `root:`), so a pool would be
keyed by root and registry entry, and an agent on another workspace would never be answered
from someone else's folder.

**Decision.** Per agent anyway: `LspTool` and `Servers` are `P_one_agent`, the servers start on
this agent's first call and die with it.

**Rejected: a shared pool keyed by root.** The protocol has no sessions. One connection is one
client: one `initialize`, one set of open documents, the client presumed the authority for every
URI it opened. Two agents on one connection is a *multiplexer* — the client side renumbering
requests, reference-counting `didOpen` / `didClose` per URI so one agent's close does not drop a
document the other is still asking about, a `close` that waits for the last user rather than
killing a child mid-request, and a cancellation that stops one agent's wait without aborting the
other's. That is the machinery `ra-multiplex` / `lspmux` exist to provide for rust-analyzer, and
it buys back jdtls's warm start on a `/clear`. A coding agent is one session by design; the
saving does not pay for the gem stopping being teachable.

**Consequences.** A `/clear` on a Java project waits out jdtls's warm start again, and N agents
over one project run N sets of servers. A host that finds that intolerable is the trigger to
revisit, and the pool it would build is keyed by root, never shared across roots.

---

## D_no_skills_in_sub_agents — Why does a sub-agent get no skill catalog and no `skill` tool?

**Context.** Two halves of "does a sub-agent get skills?" were settled by
different accidents, and neither was settled on purpose.

The `<available_skills>` block is contributed by `Skill::Extension`, and
sub-agents don't inherit extensions — a blanket rule whose headline
rationale is privilege separation (`book/subagents.md`). So the block's
absence is a *consequence* of a rule argued for other reasons.

The `skill` **tool** is the open half. Tools reach a child by name:
`SubAgentTool` filters `parent.tools` by `persona.tool_names`, so a persona
naming `skill` would get it, and `SkillTool#for_sub_agent` already rebuilds
it over `Skill::Activation::Sealed` for exactly that case. Nothing has ever
asked — both bundled personas (`RESEARCHER`, `FILE_MINER`) name narrow
toolsets and no `skill`. The
mechanism is *prepared*, never *active*, and the question of whether it
should be has been answered by omission. This entry answers it deliberately.

**Decision.** A sub-agent receives no skills: no catalog in its system
prompt, and no `skill` tool. A persona that needs domain instructions carries
them in its own `system_prompt:`, which is the sanctioned route and the only
one.

**Why.** Privilege separation is *not* the argument here, and saying so
matters — a skill body is text, not a capability, so handing one to a child
breaches no boundary the no-inheritance rule protects. The case stands on
three other legs.

- **A persona is a closed brief, not a general agent.** The child gets
  `persona.system_prompt` *verbatim* — not appended to the parent's, which is
  invisible to it. {Pikuri::SubAgent::Persona}'s whole premise is that it is
  the single source of truth for what the child is. An agent that can pull in
  instructions its brief never mentioned is an agent whose brief is no longer
  complete, which trades a property that makes personas auditable for a
  convenience nobody has asked for. pikuri ships **no general-purpose
  persona**; every one is narrow enough that its full instruction set fits in
  the prompt its author wrote.
- **A skill body assumes a toolset the persona may not hold.** Skills are
  written against a general harness and say so: `SkillTool::DESCRIPTION`
  tells the model the loaded skill "may reference helper scripts and files in
  its base directory — use the `read` tool." That is dead advice for
  `RESEARCHER` (three network-read tools, no workspace) — it spends context
  and invites a call that can only fail. Skills also bind to *ecosystems*
  rather than tasks: `writing-rdoc` fires on `**/*.rb`, which tells an agent
  whose job is reading the web nothing it can act on.
- **Determinism.** A child reachable by the parent's promotions has a surface
  that depends on which files the parent happened to read — two identical
  `agent(name: 'file_miner', task: …)` calls in one session would see
  different skills because of unrelated earlier work. `Activation::Sealed`
  exists to prevent this; this entry is why it is welded shut rather than
  merely defaulted.

**Alternatives rejected.**

- **Let a persona opt in by naming `skill` in `tool_names:`.** Costs nothing
  to allow — the plumbing works today and the sealed view already narrows it
  correctly (ungated skills only). Rejected as the *posture*, not as an
  impossibility: it remains one word away the moment a persona has a real use
  for it. What it lacks is a case. "The author might add a skill later" is
  not one — that skill's content belongs in `system_prompt:`, where it is
  chosen rather than matched.
- **Thread extensions into the child so it gets the catalog block too.** Not
  on the table: that reverses the blanket no-inheritance rule, whose
  rationale is a security boundary (`tool_names:` is the child's entire
  surface, so a prompt-injected `RESEARCHER` has no `bash` to call) that has
  nothing to do with skills and should not be relitigated through them.
- **Delete the sub-agent plumbing as dead code** — `SkillTool#for_sub_agent`,
  `Activation::Sealed`, `PathActivationListener#for_sub_agent → nil`. It is
  unexercised by every bundled wiring, so it reads as dead. It is not dead —
  it is the *enforcement* of this decision for the opt-in path deliberately
  left open. Delete it and the next persona to name `skill` silently inherits
  the parent's promotions, which is precisely the accident
  `D_skill_path_activation` had to fix once already (it "held only by
  accident at first"). Unexercised guards against a future wiring are worth
  their lines.

**Consequences.**

- **The `paths:` gate is unreachable downward by construction**, which
  `D_skill_path_activation` records as accepted-rather-than-fixed. This entry
  is why it was accepted.
- **{Pikuri::SubAgent::Persona}'s yardoc is the place a persona author will
  look** and is currently silent in both directions; it should carry the
  one-line form of this decision, so it reads as one story with
  `SkillTool`'s header (which already carries the tool-side half).
- **Reopen when** a persona has a concrete need — a general-purpose sub-agent
  (there is none today), or one whose instructions genuinely vary per project
  in a way `system_prompt:` cannot cover. The cheapest move then is the first
  rejected alternative, not new machinery.

---

## D_slash_commands — Why two command registries, a user turn, and no scheduling function?

**Context.** Moving the `wh` bundle from `~/.claude/skills/wh/SKILL.md` to
`~/.claude/commands/wh.md` made it invisible to pikuri twice over: the catalog
scans no `commands/` dir, and requires a *directory* holding `SKILL.md`. The
second motive is stronger and came from measuring a 12-skill catalog: two of
those skills were slash commands filed as skills, and their descriptions were
resident tokens spent telling the model to ignore them (`wh`'s read *"Only
invoked manually."*). A bundle the human invokes belongs on a surface that was
never advertised, where it costs nothing.

**Decision.** A separate `Command::Registry`, scanning `.pikuri/commands` /
`.claude/commands` under the same `Bundle::Base` search bases as the catalog.
Its expansion lands as the **user's** turn. There is no scheduling function:
the host holds both handles already (`registry.expand(name, arguments:)` then
`run_loop(user_message:)` or `Interloper#inject_user_message`). Typed
resolution, which only a host can do because nothing in the library sees all
three namespaces, is **host built-in > command > skill**.

**Alternatives rejected.**

- **One catalog holding both kinds.** Rejected because "never advertise a
  command to the model" would become a `reject { it.command? }` that a future
  refactor drops silently — costing tokens every turn and offering the model a
  half-working `skill(name: "wh")`. Two types, and the mistake is
  unrepresentable. The records and the scans genuinely differ too (one `.md`
  with `:`-joined path namespaces and an interpolatable body, vs. a directory
  of `SKILL.md` plus sidecars).
- **A `kind:` flag on `Skill::Extension#schedule_load_skill`.** Rejected: that
  path injects `:system`, and every consequence is wrong here.
  `on_user_message` would not fire (`pikuri-memory` hangs its per-turn
  prefetch there, so a memory layer would never see `/wh`); on Anthropic a
  `:system` block is hoisted and therefore *sticky*, turning a one-shot
  request into standing instructions; and a `:system`-only turn renders as
  no messages at all on Anthropic, which answers it with a 400, which an
  ordinary user turn never hits.
- **A `Pikuri::Slash::Menu` façade merging both registries.** Rejected for
  now: the merge is five lines of presentation over two arrays that already
  carry `name` + `description`, and the halves *dispatch* differently, so a
  merged record needs a kind discriminator — at which point the library models
  the TUI's popup. The two registries ship with deliberately parallel shapes
  so a second host can write the merge in five lines; if two hosts write the
  same five, the façade earns its place then.
- **Raising on a name collision.** Rejected: `Catalog::Bundled` already
  answers the skill-vs-skill form by keeping the first entry and warning, and
  two collision policies in one codebase is worse than either.
- **Letting a skill win the typed name.** Rejected on asymmetric
  reachability: if `/wh` resolves to the skill, the *command* becomes
  unreachable by anything — nothing else can invoke it, by design — whereas
  the skill loses only its slash affordance and stays fully model-invocable.
  One side of the fork drops a capability, the other drops nothing.
- **A host built-in losing to a scanned file.** Rejected as a real hijack:
  commands are scanned from the project root, so a cloned repo shipping
  `.claude/commands/plan.md` would capture `/plan` — the read-only plan-mode
  toggle — and the failure is invisible, reading as a chatty model rather than
  a disabled gate.
- **Parsing `argument-hint:` into slots** so the library could reject `/wh`
  with no arguments. Rejected: it is display chrome for a menu, and a body
  handles a missing argument better than a validator can (`wh.md` already
  says "if no label was given, use 'swingai'").

**Consequences.**

- **`Registry` and `Renderer` are pure functions over disk**, testable and
  usable with zero agent integration — which is what let two synchronous
  `bin/` demos wire the feature before `pikuri-tui` exists.
- **`Registry#get` carries two contracts**: `nil` for a name that isn't there
  (an ordinary typo, fixable by retyping) and a raise for one that is there
  but refused (a fact about a file on disk). A host written against only the
  first dies on the second.
- **Commands still need an `Extension`** — a declaration-only one, because a
  surface that contributes no tool lands nowhere in the `Pikuri::Trifecta`
  tree, and an agent holding all three legs would report two. It grades the
  untrusted leg through `pikuri:D_bundle_trust_grading`'s per-base channel.
- **`Trifecta::Contribution` gained a `label:`.** Extension legs used to be
  unioned into one row hardcoded as `(mcp)` — honest only while MCP was the
  only contributor. A second one made the banner blame an MCP server that
  wasn't wired, against `Report#attribution`'s whole purpose.
- **The chain's third leg landed 2026-08-17**, in `bin/pikuri-code` — the one
  bundled script wiring commands *and* skills, so it is the only place the
  full `host built-in > command > skill` order is observable. Three shapes
  chosen there, each over a live alternative. It is **argument-less**: a
  command is a template with `$ARGUMENTS` to interpolate, a skill body is
  fixed text, so an argument would have nothing to do — and `/name extra`
  silently ignoring the tail is worse than not offering it. It **enqueues
  without running a turn**, so the body arrives with the human's next
  message; the alternative — `run_loop(user_message: nil)`, the bare load
  `schedule_load_skill` documents — spends a completion on an
  acknowledgement, which is precisely the tax `feedback.txt`'s *"skill load
  costs a turn"* reported, and that this feature answers. And a *refused* name
  gets a **human-only** second line naming the skill as installed-but-gated,
  read from the unfiltered `Catalog`: decision 7 of
  `D_skill_path_activation` makes the gate answer the model as if the name
  existed nowhere, which is right for the model and useless to someone who
  just read that name in the startup banner. Nothing in that branch reaches
  the conversation, so the gate leaks nothing to the model.

## D_command_inlining_legs — Why no bash pre-execution in a slash command, and why is `@path` not a refusal?

**Context.** Claude Code expands two more things in a command body. `` !`cmd` ``
runs a shell command *before the prompt is sent* and inlines its stdout, gated
only by the command file's own `allowed-tools:` frontmatter — i.e. gated by the
untrusted file itself. `@path` inlines a file's bytes.

**Decision.** Neither ships, and they get *different* handlings from the same
premise. A body containing `` !` `` is **refused**: `Registry#get` raises
`RefusedError`, the scan warns, and detection is deliberately over-eager
(fence-blind, and matching `allowed_tools` beside the documented
`allowed-tools`). `@path` is simply **not interpolated** — it passes through as
literal text, with no warning and no refusal. `allowed-tools:` is refused on a
command while still being ignored on a skill.

**Alternatives rejected.**

- **Implementing `` !`cmd` `` behind pikuri's confirmer + sandbox.** Rejected:
  it makes a `.md` that travels with a clone into arbitrary code execution
  triggered by typing a slash. Without it a command is *text*, and its worst
  case is prompt injection into a turn the human deliberately asked for —
  which is also what keeps the feature inside `pikuri-skills` instead of
  earning its own gem. Wanting it back is a feature request, which is exactly
  the signal to have before building the gated version.
- **Passing the `!` line through as literal text** so the human can see it.
  Rejected, and this reversed an earlier lean: a literal `` !`git status` ``
  sitting in the prompt reads to the *model* as an instruction, so the likely
  outcome is not "visibly misbehaves" but "the model runs it through the real
  `bash` tool a beat later" — the refused behaviour, arrived at
  unpredictably. An exception has no second reading.
- **Refusing `@path` too.** Rejected: unlike `!` it has a harmless second
  reading. A literal `@docs/style.md` left in the text reads as a path
  mention, and the worst case is the model calling `read` — through the gated
  tool, against the workspace, exactly as wanted. Detection would also have to
  be over-eager to be safe, and `@`-shapes false-positive on the email
  addresses in the very file that motivated the feature.
- **Ignoring `allowed-tools:` on commands, as skills do.** Rejected: pikuri
  fixes tools at `configure` time and cannot narrow them mid-conversation, so
  ignoring the key runs the command with the full toolset when its author
  asked for a fenced one. That is a *widening*, not a no-op.
- **Refusing `allowed-tools:` on skills too**, for symmetry. Rejected on
  compatibility asymmetry, and the two halves are only defensible together:
  the key is one of the six official Agent Skills fields, so refusing it on
  the shipped skill surface would break catalogs doing nothing wrong by
  carrying a field the standard defines (`R_skills`' finding 3 is the
  general form — a key the host doesn't implement is advertised anyway). On
  the command surface the key is not spec, it is Claude Code's own, and its
  documented job is gating the pre-execution pikuri refuses.

**Consequences.**

- **Refusal is a scan-time fact stored on the record**, so `#refused?` and its
  reason are free to a menu; only `#get` raises. Skipping the entry at scan
  time instead would make it silently absent, which is the same
  discoverability failure one layer up.
- **`RefusedError` is host-facing**, never reaching a tool, so the
  `"Error: …"`-string convention for model-visible failures does not apply.
- **The answer outlives the command surface.** *"Just add bash
  pre-execution, Claude Code has it"* is the recurring proposal, and it is not
  reconstructible from code that never grew the feature — which is why this
  entry stands even though nothing shipped for it.

## D_command_substitution — Why is command substitution fence-aware, and why does the append read the body the same way?

**Context.** Measured against Claude Code 2.1.233 (headless, throwaway project,
reproduced on two models): the expansion is wrapped in
`<command-message>` / `<command-name>` / `<command-args>`; arguments a body
never references are appended after two blank lines as `ARGUMENTS: <raw>`; and
`$n` indexes the argument list **0-based** while being documented and
universally written as 1-based, so `$1` yields the second word.

**Decision.** `$n` is **1-based**. An out-of-range `$n` stays **literal**, as
it does there. Substitution skips fenced blocks and inline code spans, for
*both* tokens — and the "body references neither" check that gates the append
runs over the same segmentation, as one pass. The append copies Claude Code's
exact spelling. No XML wrapper; a `(this command lives in …)` footer instead,
and only when the directory holds a sidecar.

**Alternatives rejected.**

- **Matching the 0-based bug.** Rejected: nobody authored *against* it — the
  shape it produces is a body that silently reads the wrong word, likelier
  papered over than noticed — and matching it means matching it forever.
- **Blanking an out-of-range `$n`.** Rejected on the same axis as everything
  else here: blanking makes a `$1` the author never meant as a placeholder
  silently vanish, while leaving it literal keeps the mistake visible in the
  transcript.
- **Substituting blindly, as the prior art does.** Rejected on the motivating
  file: `wh.md` carries `$ARGUMENTS` and `$1` inside backticks while writing
  *about* them, and a blind pass rewrites that sentence into one that asserts
  something false to the model. A command emitting a shell script has its
  `"$1"` hardcoded to one invocation the same way.
- **A `$$` escape for authors who mean the literal.** Rejected: it only works
  on files someone edits, and imported bundles nobody will edit are the whole
  reason to scan someone else's directory.
- **Fence-aware `$n` with blind `$ARGUMENTS`**, on the theory that
  `$ARGUMENTS` is distinctive enough that a mention means a placeholder.
  Rejected by counterexample in the same file: authors writing about commands
  backtick both tokens.
- **Reading the body blind for the append gate** while substituting
  fence-aware. Rejected as a data-loss bug: `wh.md`'s every `$ARGUMENTS` is
  backticked, so it counts as "referenced", gets no append — and gets no
  substitution either. The typed argument disappears with no error, on the
  most common invocation of the only command file we had.
- **Wrapping the expansion in `<command-*>` tags.** Rejected: the prior art's
  wrapper carries no *location*, so it does not solve the base-directory
  problem that was the only functional argument for having one. A wrapper we
  would have to extend anyway is a wrapper worth not having.

**Consequences.**

- **`` !` `` detection stays fence-blind while substitution is fence-aware**,
  and that is not an inconsistency: a false positive in detection is a loud
  exception on an editable file, a false positive in substitution is silent
  corruption. Whoever "fixes" one to match the other reintroduces the bug.
- **`wh.md` interpolates nothing and rides the append**, which is the correct
  reading of it and the reason the gate is shared.

## D_skill_path_activation — Why is a `paths:` skill out of play until its path fires?

**Context.** The axis is *what the catalog advertises, and when the body
arrives*. `Skill::Extension` contributes an `<available_skills>`
system-prompt snippet carrying every skill's description; on the author's
ten-skill catalog that is ~4.8 KB resident on every turn, of which at most
one entry is relevant to any given session. Two things made the status quo
hard to defend. The author's global AGENTS.md hand-wrote five skill nudges
*while that catalog was already resident* — nobody writes a redundant
nudge for a mechanism that works. And descriptions fail asymmetrically:
they work for capability-shaped skills, where the model feels a gap it
cannot fill, and fail for correction-shaped ones like `cop`, where the
model confidently does the wrong thing and never runs the relevance check
at all.

*Resident on every turn* must not be argued in raw token counts: the catalog
sits in the stable system prefix, so llama.cpp's slot prefix-reuse and
Anthropic's prompt cache both skip it after turn one and cloud cache reads
bill at ~0.1×. The compute framing is simply wrong. Two costs no cache
refunds, and they are what this decision is about. **Window capacity:**
cached tokens still occupy KV slots, so 3.8 k tokens of a 64 k window is
3.8 k the conversation cannot have — on a local GPU, VRAM held for the whole
session. **Attention:** every decoded token attends over the entire prefix,
so twenty-eight unused descriptions are twenty-eight distractors competing on
every token generated. Both scale with catalog **size**, which is why
per-entry editing — worth doing, and `when-to-use:` plus the `<location>`
trim did it — cannot reach them and only *withholding entries* can. Hence a
gate rather than a diet. Calibration at a real catalog size (Claude Code's
own `/context`, 2026-08-16, 28 skills): 3.8 k tokens of catalog, `dataviz`
~380 and `cop` ~310 per entry, against the Agent Skills spec's stated budget
of 50–100 — 3–6× over, on descriptions carrying TRIGGER/SKIP blocks because
they were doing the skill's job.

**Decision.** Adopt grok-build's `paths:` frontmatter key, with pikuri's
own placement:

1. The catalog **stays a system-prompt snippet** and carries every
   *ungated* skill in full.
2. A skill declaring a non-empty `paths:` is withheld **entirely** — no
   description, no name, no sibling section, and no hint that anything is
   withheld. The catalog does not advertise its own incompleteness.
3. When a tool **reads or edits** a file matching those globs, the skill's
   description is appended to the log as a system message.
4. A promotion carries a **description, never a body**.
5. A gated skill is **not loadable by name** before its path fires:
   `skill(name:)` refuses it exactly as it refuses a name that exists
   nowhere, with the same message. `SkillTool`'s `name` therefore stays a
   **free-form string, never an enum** of the active set — an enum would
   have to be rebuilt on every promotion, churning the tool schema
   mid-session on every provider.
6. `paths:` answers *"is this ecosystem in play?"*; `when-to-use:` answers
   *"is this the moment?"*. They compose on one skill and are not rivals.
7. The gate is the **default at every surface**, not the model's alone:
   {Pikuri::Skill::Extension#schedule_load_skill} refuses a pending skill
   exactly as the tool does, and so must any future picker or typed
   `/name`. One rule with no exceptions to remember — *a `paths:` skill
   is not in play until its path fires*. Two deliberate carve-outs, both
   because they are not invocation routes: `Catalog#get` stays unfiltered
   (the catalog is frozen, session-less, pure holding — the gate lives in
   its callers, never in the catalog itself), and `bin/pikuri-code`'s
   startup banner keeps reporting what is *installed*.

Prior art and the read of grok-build's implementation live in
`design/research.md` `R_skills` (*Frontmatter*, and *How grok-build's
conditional activation actually works*).

**Alternatives rejected.**

- **Delete the catalog; rely on `skill(name:)` plus path activation.** The
  model cannot call a tool with an argument it has never seen. The name
  has to come from somewhere, and every substitute is worse: an AGENTS.md
  nudge is the same words in a hand-maintained home that rots silently on
  a rename, where the catalog is regenerated from the filesystem at boot;
  path activation alone leaves a skill without `paths:` permanently
  unreachable, and `cop` is exactly that skill; a `skill_list` discovery
  call buys a round-trip.
- **Tier 0 — names-only for *every* skill, descriptions promoted on
  demand.** Measured at ~65 tokens for names against ~1.5 k for
  descriptions, so the ratio is tempting. Rejected because it withholds
  the descriptions that *work*: the file-shaped skills whose descriptions
  do fire are precisely the ones a glob can gate, while `cop` — which
  demonstrably never fires — has no predicate and would stay resident. It
  removes the working half and keeps the failing half, and makes every
  gated skill need two things to go right where it previously needed one.
  Gating per skill, chosen by the author, keeps the ratio without the
  inversion. No surveyed harness ships a names-only catalog; grok-build
  renders one only as budget overflow, and its source carries a comment
  rejecting a names-only footer as "wastes tokens and looks like skills
  with no description".
- **Move the catalog out of the system prompt, as grok-build does.** Its
  baseline goes into the first user message
  (`prompt/user_message.rs`), never the prompt — pitched as a better
  position on two counts: promotion mutates no prefix, and skill
  descriptions are `untrusted: :hard` text that would sit in a data
  position rather than the most-trusted slot in the request. **Declined
  outright 2026-08-17**, because reading the two counts against pikuri's own
  code shrank the offer to one and a half. The prefix count is already
  banked: `assemble_system_prompt` runs once per agent, at construction (a
  "/clear" is a new agent), and a promotion already rides the interloper, so
  nothing mutates a prefix mid-session here either. What remains is the
  trust position, in a sharper form: a *gated* skill's description arrives
  as `role: :user` while an *ungated* skill's identical bytes arrive in the
  system prompt. Incoherent, but a tidiness argument rather than a finding —
  `pikuri:D_bundle_trust_grading` reports this exposure and deliberately does not
  defend against it, and moving the block would only relocate it. Two things
  a reopen would have going for it, recorded so nobody re-derives them:
  seeding the baseline on the interloper makes one channel and one renderer
  carry both baseline and promotion, and requiring an interloper for a
  non-empty catalog would delete `Extension#arm_gate`'s two-branch fail-open
  outright, since that branch exists only because the two live on different
  channels. Against it, and untested: the resident block is in the strongest
  position for instruction-following, which matters most on the local models
  pikuri targets.
- **Move the baseline into `SkillTool`'s description instead.** Carried as
  an open fork for a day, on the reasoning
  that a persona replaces the system prompt but inherits the tool
  verbatim, so the tool is the only home correct for both agent kinds.
  Rejected: `D_no_skills_in_sub_agents` has since made "correct for both
  agent kinds" a property pikuri does not want, so the argument inverts
  into a hazard — a description built at `configure` time from the
  parent's catalog would hand the inventory to any persona naming `skill`,
  where `SkillTool#for_sub_agent`'s sealed `Activation` cannot reach it.
  It also cannot host promotions (a description is built once), and it
  wants the enum that decision 5 already rejected.
- **Advertise gated skills name-only, in a sibling `<contextual_skills>`
  section, and keep them invocable.** This was the decision as first
  accepted, reversed the same day on evidence. Three things killed it.
  It is shipped by **nobody**: grok-build holds a gated skill out of its
  `AvailableSkills` registry entirely (`has_skill()` refuses it), and
  Claude Code was then observed doing the same, down to returning the
  identical "unknown skill" message it returns for a name that exists
  nowhere (`R_skills`, *Frontmatter*, finding 4). One
  harness is noise; two independent ones are a signal, and this is the
  same convergence argument that chose the top-level `paths:` spelling —
  applying it to the spelling and declining it for the semantics would
  have been incoherent. It rests on an **unmeasured assumption that is
  weakest exactly where pikuri runs**: that a bare name is a strong
  enough recall cue, which is far likelier on Claude than on the local
  llama.cpp default. And it costs more than the names — a preamble
  explaining the two-tier scheme and the load-by-name-anyway caveat
  outweighs the ~65 bytes of names it was protecting.
- **Keep the `SkillTool` `name` argument enum-constrained** over the
  active set. Rejected as incompatible with decision 5, and the two
  surveyed harnesses agree by construction: the one that hides skills is
  the one that takes a free-form name. This retires the enum item carried
  as owed-regardless since this axis opened, and
  with it the lenient-name-validation reversal that blocked it —
  `validate_name`'s warn-and-continue posture stands, because a lenient
  name now reaches only a prompt block, never a tool schema.
- **Invent a `project-has:` predicate** for "this is a Gradle project"
  rather than "a Gradle file was touched". Not in the spec, not in
  grok-build, not anywhere; inventing a predicate no harness implements,
  to serve a saving in the hundreds of tokens, was the clearest thing to
  drop. Its motivating case is served by operator wiring instead.
- **Pre-inject the body on a path match.** A `paths:` in a downloaded
  bundle deciding to occupy 4 KB of a host's context is the skill *author*
  spending someone else's window — where the same act by a host loading a
  skill it named itself is legitimate, because it is spending its own.
  Same mechanism, different hand on it, opposite verdict. Note this is
  the one place the author/host asymmetry still bites after decision 7
  closed the operator exemption: a host may pre-inject a body it chose,
  but it may no longer name a *gated* skill to do it to.
- **`paths: []` as the spelling for "never advertise".** In the shipped
  implementation an empty list means **unconditional** — the exact
  opposite — and so does `["**"]`, because normalization drops a match-all
  to `nil`. It is also a YAML footgun with an inverted failure: a bare
  `paths:` with nothing under it parses to `nil`, so the author types the
  thing meaning "hide" and gets "advertise". A skill that should never be
  model-invoked wants `disable-model-invocation:`, which is a separate
  question and blocked on the host load path.
- **`metadata: {pikuri-paths: …}` over the top-level key.** Spec-clean,
  and the spec's sanctioned extension point — grok-build parses `metadata`
  too, so the shape is proven. Rejected because top-level `paths:` is what
  two independent harnesses already honour, and agreement is the whole
  value of not inventing a dialect. For a *newly invented* predicate there
  would be no agreement to buy and `metadata:` would win by default.

**Consequences.**

- **Anthropic and Bedrock pay a prompt-cache invalidation per activation,
  accepted.** ruby_llm's `providers/anthropic/chat.rb` partitions *every*
  `:system` message out of the array and folds it into `payload[:system]`,
  so an injected promotion rewrites the prefix. The OpenAI-compatible path
  — including the local llama.cpp default — keeps it positional
  (`providers/openai/chat.rb` `format_role`), so it costs nothing there.
  pikuri targets the OpenAI path first; this is a known trade, not an
  oversight.
- **The gated set is ecosystem filters, not moment triggers.** When a
  predicate cannot be exact, prefer over-firing to under-firing: an
  over-fire spends a few hundred bytes on an entry the model ignores, an
  under-fire withholds the skill at the moment it was needed. A coarse
  glob is also not *adding* a false positive relative to leaving a skill
  ungated — ungated shows it in every project — so it strictly shrinks the
  surface.
- **Measured on the author's ten-skill catalog:** five skills carry
  `paths:`, holding 2 828 of 4 798 description bytes (59 %); in a Ruby
  session roughly 1 465 bytes (31 %) stay withheld, since the Ruby-gated
  ones fire almost at once. Both numbers matter — the first is what the
  mechanism *can* gate, the second what it saves in one session. An
  earlier estimate of the same quantity, made by the party proposing the
  mechanism, was 3× off in the optimistic direction and was corrected only
  by writing the frontmatter it was estimating. Anyone re-opening this
  should author before estimating.
- **Cheap-to-gate and expensive-to-carry are nearly disjoint.** `gradle`
  (117 B) and `maven` (175 B) are the skills a project-type predicate fits
  best and the ones with nothing to save; `cop` (1058 B) is the largest
  description and the least gateable. Gating is a relevance measure that
  happens to save bytes, not a compression scheme.
- **Ships as one change:** frontmatter parsing, a glob matcher, a
  post-tool-call listener holding session-scoped activation state, and a
  catalog render that skips gated entries. Two rules the mechanism turns on,
  both stated in {Pikuri::Skill::PathActivationListener} and
  {Pikuri::Skill::Activation}: activation counts only model-supplied
  read/edit targets, never a path a tool *walked* to (a repo-wide `grep`
  would otherwise activate half the catalog at once — the **Denylist seam**'s
  distinction, from the other direction); and a skill is announced at most
  once per conversation, the set living on the extension instance, so a
  "/clear" — a new agent with a new extension — re-hides correctly. Both were then observed in
  Claude Code before pikuri wrote a line of it — `design/research.md`
  finding 4.
  **Every place that enumerates the catalog is part of the change, not just
  the render** — `SkillTool`'s not-found error lists the *activated* names,
  or one refused guess would dump the catalog it is hiding.
- **`paths:` still is not access control, and now looks like it.** The gated
  party controls the trigger, so it withholds and refuses but restricts
  nothing; the shape invites the wrong reading where before only the name
  did. The non-claim now lives in {Pikuri::Skill::Catalog}'s yardoc, where
  someone reading the code meets it.
- **The operator is gated too.** The exemption worth wanting is that an
  operator typing a name has already made the relevance judgment the model
  could not. Both surveyed harnesses refuse it anyway — Claude Code returns
  `Unknown command` for `/writing-rdoc` in a fresh session; grok-build builds
  `slash_skills()` from `startup_skills`, already stripped of held skills, so
  the name does not resolve when typed rather than merely failing to
  autocomplete. **What settled it was not the vote but what an exemption
  would be worth in practice:** `Catalog` is public and unfiltered, so a host
  building the obvious skill picker enumerates `catalog.list` — as
  `bin/pikuri-code`'s banner does — and re-exposes every gated skill on
  precisely the surface both harnesses gate. An exemption every naive host
  opts out of is a nominal convergence.
- **`paths:` auto-*advertises*; it never auto-loads.** Worth stating because
  the opposite reading makes decision 7 look redundant rather than
  restrictive: a promotion carries description + `when-to-use`, never a body,
  in both surveyed harnesses as in pikuri. So invocation stays the only route
  to a body, and gating it closes the sole path. pikuri ships **no cap** on a
  promotion — descriptions are capped at 1 024 chars by the standard, and the
  mechanism exists to spend a few hundred bytes at the moment they matter.
  grok-build's overflow arithmetic is there if a fat catalog ever wants one.
  A `force:` escape hatch on `schedule_load_skill` is the obvious future
  request, deferred until something concrete needs it.
- **A gated skill is unreachable to sub-agents, by construction.** They do
  not inherit extensions, so no listener ever promotes for them, and under
  decision 5 the name will not load either; `SkillTool#for_sub_agent` rebuilds
  the tool over `Skill::Activation::Sealed` so the child cannot resolve
  against the parent's promotions. Accepted rather than fixed: no bundled
  persona wires `skill` at all, and a persona that wants one should name it
  in `tool_names:` and carry the knowledge in its own system prompt. This
  retires the per-agent-vs-catalog-wide scope
  question the build note carried.
- **A promotion must carry the catalog's load instruction, not just the
  names.** It first announced availability only, while the resident block
  carried the imperative. Against a local `Qwen3.6-35B-A3B` on a repo task
  (2026-08-17): the block was delivered and attended to, the model named the
  promoted skill in its reasoning and *resolved to load it* — then read a
  neighbouring source file instead and imitated its style, never calling the
  tool. Told afterwards to load it, it rewrote its output substantially, so
  the skill's marginal value was real and had simply lost to a cheaper
  substitute. The lesson generalizes past this mechanism: **imitation
  transmits presence and never absence**, so every rule of the form "delete
  this" is invisible to a model reading exemplars — exactly the
  correction-shaped content a skill exists to carry. `format_promotion` now
  closes with the catalog's instruction, widened to outrank *inferred house
  style* alongside training, and keeps the `if none matches` escape because
  activation over-fires by design. Filtering stays the description's job,
  which is the authoring half and belongs in the book.
  **Weigh this as an anecdote, not a measurement:** a handful of runs against
  one model on one task, where separating a real effect from sampling noise
  would take on the order of a hundred. The change stands on a reason that
  needs no statistics — the promotion and the resident block advertise the
  same thing and should say the same thing — and the same caution applies to
  anything else in this repo reasoning from a single local-model transcript.
- **This is where the skills-surface work stops** (2026-08-17), on two
  readings. The origin was thinner than the notes it grew: the complaint is
  `design/ideas/feedback.txt`'s *"the standing prompt is heavy"*, which lists
  the catalog in an enumeration and then names what is actually not worth its
  bytes — the tool-schema restatement, the duplicated "don't mention the
  guidelines" material. The catalog was never its target. Nor does the prior
  art support trimming it: grok-build, built for the model that filed the
  complaint, renders a full resident inventory of *every* skill budgeted at
  up to **50 % of the context window**. Its one divergence from pikuri is
  position, not volume. So gating plus two cheap trims is the whole of what
  this axis earned — `<location>` left the catalog and promotion renders
  (`format_skill` keeps it, the copy sidecars resolve against), and a typed
  `/name` loads a skill in `bin/pikuri-code`. Unbuilt **by decision, not
  backlog**: listing a skill's sidecar files in the load result, and deduping
  a repeated load. What the trim does *not* touch: `Filesystem#readable:`
  over `catalog.roots` is load-bearing for reading **sidecar files**, not
  merely a direct-`read` fallback for `SKILL.md`.
- **A promotion needs the interloper**, since it reaches the model only
  through mid-loop injection. Every agent owns one since pikuri dropped
  `Agent.new(interloper:)`, so the gate is always on; an earlier `Skill::Activation::Open` turned it off for an agent built without
  one, rather than hide what nothing could bring back.
- **Reopen when** one of these trips: (1) the untrusted-description
  position becomes a real finding rather than a theoretical one, which
  argues for the placement move above; (2) activation counts per session
  turn out high enough on Anthropic that the cache trade stops being
  noise; (3) a third harness settles on a different spelling.

---

## D_headless_os_agent — Why does the OS agent launch no apps, and why does the sandbox mask the session's IPC surface?

**Context.** `pikuri-os` advises on GUI config (it prints the `gsettings`
command rather than applying it), and "let it launch apps / `xdg-open` a
file" sat on the deferred list as a post-v1 nicety. Measuring what
`FullFsNoNet` actually permits killed the nicety and exposed a hole in the
egress cut, on this host, GNOME/Wayland:

- A sandboxed `curl` gets nothing (`000`, loopback-only netns). The same
  `curl` handed to `systemd-run --user` returns **HTTP 200** — `systemd
  --user` spawns it in the *host* netns, parented outside the sandbox.
- `xdg-open file.png` on a `DBusActivatable=true` handler (loupe) is spawned
  by the session bus: host netns, full network, cgroup `dbus.service`, and it
  survives `--die-with-parent` because it was never a child.
- A plain `Exec=` handler (librewolf) forks *inside* the sandbox and is
  contained — **unless an instance is already running**, in which case the
  remote-instance handoff delivers the URL to the outside process. Measured
  both ways: cold browser → "Unable to connect"; warm browser → the GET
  landed in the listener's log. Containment that depends on whether the user
  happens to have their browser open is not a security property.

So the trifecta's egress leg reopened through the session, and the enabling
authority is one unauthenticated socket: the session bus is the user's own
bus, with the user's full authority and no polkit in front of it.

**Decision.** The OS agent is **headless**. Two halves, one decision:

1. **No launcher.** No `open`/`launch` tool, and no GUI-application arm to
   the config advice. The human is at the keyboard; opening a file or
   starting an app is a double-click, so the capability buys ~nothing while
   costing an egress channel.
2. **The sandbox subtracts the session's live IPC surface** — a tmpfs over
   `$XDG_RUNTIME_DIR` (session bus, Wayland socket, keyring / ssh-agent /
   at-spi, a rootless container daemon) and over `/tmp/.X11-unix`, plus a
   `/dev/null` mask over a `DBUS_SESSION_BUS_ADDRESS` pointing elsewhere.
   Abstract-namespace sockets need no mask: `--unshare-net` already scopes
   them (measured — reachable from the host, `ECONNREFUSED` inside).

Being headless is what *permits* half 2: with launching declined, nothing
legitimate wants those sockets.

**Alternatives rejected.**

- **Ship the launcher anyway, confirmer-gated.** Rejected on value, not just
  risk: it's an egress-capable tool in a deliberately offline agent, bought
  for a double-click. It would also have to pick a broken semantics —
  direct-exec keeps the egress cut but ships crippled apps (a browser with no
  network), `xdg-open` works properly *by* escaping the cut.
- **Deny `xdg-open` (a bash denylist).** The tempting one-liner, and the
  losing side of the enumeration game that `PASSIVE_BINARIES` is deliberately
  the winning side of: `gio open`, `gdbus call`, `dbus-send`, `systemd-run
  --user`, `setsid librewolf URL`, five lines of Python on the bus socket are
  all the same channel. Worse, a partial denylist manufactures false comfort
  — "no deny hit ⇒ contained" is exactly the wrong lesson. Remove the
  authority, not the names.
- **Accept and document it** (the status quo, with the confirmer as the only
  guard). Rejected because the innocuous *look* of the trigger is the whole
  problem: a human who has read "bash here is network-severed" approves
  `xdg-open ~/report.png` on that understanding, and it is not true. Every
  such binary is non-passive today, so the human *does* see the command —
  which is necessary but too thin a thread to hang the gem's premise on.
- **Mask the rootful container sockets too** (`/run/docker.sock` &c., reusing
  `Bubblewrap::DENIED_CONTAINER_SOCKETS`; mechanically easy — `--ro-bind
  /dev/null <socket>` masks one cleanly). Rejected on the **error-signal**
  argument that already decided the real `/dev` and
  `D_permission_wall_handoff`: a user outside the `docker` group — the common
  case, and the reason rootless docker exists — gets an honest `EACCES` from
  the untouched socket, which tells the model *and* the human exactly what is
  true. Masking it trades that for a confusing `ENOENT`, and then both waste
  turns wondering where the daemon went. It would also cost `docker ps` as a
  diagnostic. For a user who *is* in the `docker` group the socket is a live
  root-equivalent escape — but that user holds root-equivalent power outside
  the agent anyway, and the guard there stays the confirmer (`docker` is
  non-passive, so it reaches the human).

**Consequences.**

- Lost, and worth stating plainly: `systemctl --user` (session-bus state
  queries), a *rootless* `docker`/`podman` socket, `ssh-add -l`, and audio
  tooling. Still fine, measured: `systemctl`/`hostnamectl`/`loginctl` on the
  system bus, `journalctl` (including `--user`, it reads files), `gsettings
  get` / `dconf read` (dconf reads the file; only *writes* need the bus),
  `ps`/`lsblk`/`smartctl` and every file read. The masked runtime dir is
  user-owned and writable, so a program wanting its own socket there still
  works.
- **GUI config stays advice — applying it is declined, not deferred.** A
  `gsettings set` is a dconf write, which needs the masked session bus, so
  the agent prints the command and the human runs it — the same hand-off
  as `D_no_agent_sudo`. Don't re-add an apply arm: it means reopening the
  bus, which is the egress channel above.
- Residual paths out, all human-gated and none silent: the **system** bus
  stays bound (`systemctl status` needs it) — a transient unit there is
  polkit-gated and pops an *authentication dialog on the user's desktop*
  (observed; it is loud, and consistent with `D_no_agent_sudo`); **deferred
  execution** via a confirmed write (`~/.bashrc`, `~/.config/autostart/*`,
  `crontab`), which the write confirmer shows as a diff; and **rootful**
  container sockets, left visible on purpose so the denial is honest — see
  the rejected alternative above.
- The mask must stay *after* `--dev-bind / /` in the argv or the root bind
  covers it — invisible in review and silent under every other test, so
  there's an ordering assertion in the spec.
- `Bubblewrap` needs no change: it binds an allowlist that never included
  `/run/user`, so the coding agent never had the channel.

## D_no_agent_sudo — Why is a privileged action a human hand-off rather than agent-held root?

**Context.** `pikuri-os` operates the real host but runs unprivileged, so
anything needing root — installing a package, editing `/etc`, restarting a
service — is out of reach. The recurring question is whether the agent
should ever *acquire* root, most concretely for package installation. Three
barriers stack up today, and it's worth keeping them straight:

- Inside either bwrap sandbox, `sudo` cannot work at all: `bwrap` sets
  `PR_SET_NO_NEW_PRIVS`, which neuters the setuid bit (`sudo: The "no new
  privileges" flag is set`). No sudoers or password arrangement gets around
  it.
- Under `FullFsNoNet` the network is severed too, so an install's download
  leg fails independently of privilege.
- Under `Bubblewrap` the target is also wrong: toolchain dirs are ephemeral
  overlays, so an install would vanish at session exit.

So installation is reachable only under `Sandbox::NONE` (`--no-sandbox` /
`--yolo`) — which for `pikuri-os` re-opens the network and reassembles the
trifecta the gem exists to break. The fork therefore isn't "sandbox or
not"; it's what the *host* does when root is genuinely required.

**Decision.** The agent never holds root. It advises: hand the human the
exact `sudo …` command with an explanation, and let them run it in their
own terminal. A downstream host (`pikuri-tui`, a web UI) must not add a
privilege-acquisition path either. This costs no new mechanism — the
hand-off is the shipped `EACCES` path, and the human's "done" is an
ordinary next user turn.

**Alternatives rejected.**

- **Agent-held sudo via `sudo -S` on stdin, or `SUDO_ASKPASS` / `sudo -A`.**
  Mechanically possible under `Sandbox::NONE`. Rejected because it
  **collapses the confirmation posture the file tools are built on**:
  {Pikuri::Workspace::WriteGate} short-circuits an unwritable write instead
  of prompting, and that is precisely why there is no sensitive-path
  denylist to maintain — "the files worth confirming are simply the ones
  you can actually write." Grant root and *every* file becomes writable,
  the argument evaporates, and the denylist we deliberately avoided has to
  be built. `D_permission_wall_handoff` rests on the same precondition:
  root turns its wall into a suggestion.
- **polkit / `run0` / `pkexec`** — the strongest form, since the auth prompt
  renders in the desktop's trusted UI and pikuri never touches the
  password. Rejected anyway: it solves password *handling* and leaves the
  posture problem untouched, still granting root to an LLM-authored command.
- **A per-install password prompt** ("just ask each time"). Rejected: with
  `--new-session`, sudo's timestamp cache is per-tty, so the password is
  re-fed on every call — making it a **standing root capability** for the
  session rather than one authorized act, which is
  `design/ideas/bash-confirmer.md` §"The danger" at maximum privilege. A web UI is
  strictly worse: password over a transport, held server-side, no local
  trusted tty.

**Consequences.**

- **The two hand-off legs are asymmetric, and the prompt now says so.** A
  privileged *read* needs its output pasted back; a privileged *change*
  does not — verification is available to the agent locally, needing
  neither root nor network (`dpkg -l`, `apt-cache policy`, and friends are
  already in the passive allowlist, so it self-verifies without even a
  confirmation prompt). Observed on a live 2026-08-06 "install openjdk-21"
  run: the model handed back the correct `sudo apt-get install …` from the
  grounding block's `Packaging:` fact, then asked for apt's progress bars
  to be pasted back. That misfire is what the clause fixes.
- **Probing with a doomed command first is fine.** The same run spent two
  steps discovering the dpkg lock was unwritable before escalating. Left
  as-is deliberately: it's the honest-`EACCES` path working, and the
  opposite of `D_permission_wall_handoff`'s open caveat (escalating *too*
  fast, before gathering the partial picture).
- **Package availability works offline.** apt's package lists are local, so
  `apt-cache policy` names the exact candidate version with the network
  severed. The agent can confirm a package exists and what it would install
  before handing off — the network barrier never fires on that leg.
- **This closes the "package installation" item** that sat on the OS
  agent's deferred list as "post-v1". It is not deferred
  work; it is declined by posture, and the hand-off already ships.

---

## D_permission_wall_handoff — Why let an honest `EACCES` through rather than steer around it in the prompt?

**Context.** `pikuri-os` runs unprivileged inside a bwrap user namespace
where `sudo` doesn't work, so anything genuinely needing root must be handed
to the human. The question was how much of that escalation *strategy* the
system prompt has to spell out.

**Decision.** One line in `prompts/os-assistant.txt` states the hand-off (a
`Permission denied` means the real answer needs root → give the exact
`sudo …` command, explain it, ask for the output pasted back). No
elaboration beyond that. On the live test the model ran the probe, read
"Permission denied", recognized root was required, and handed back exact
`sudo nvme smart-log` / `sudo smartctl -a` with an explanation and a
paste-back ask — unprompted, and reaching for the NVMe-specific tool first.

**Alternatives rejected.**

- **Read-vs-mutate escalation sub-bullets in the prompt** — they existed and
  were trimmed as dead weight once the behaviour proved emergent.
  **Don't re-add them thinking they're load-bearing.** Prompt text is not
  free: every line competes for attention with the ones that *are* doing
  work, and this one was buying behaviour the model already had.

**Consequences.**

- **The precondition is the load-bearing half, and it's in the sandbox, not
  the prompt.** This only works because `FullFsNoNet` binds the *real*
  `/dev`. The earlier synthetic `--dev /dev` hid block-device nodes, so
  `smartctl` failed `ENOENT` ("No such device") while `lsblk` / `/sys`
  showed a healthy disk — an incoherent machine, and the model retry-looped
  instead of escalating. A prompt cannot fix an environment that lies. See
  {Pikuri::Code::Bash::Sandbox::FullFsNoNet} + `pikuri-code/design/architecture.md`.
- **Open caveat.** The model escalated *straight* to `sudo` without first
  gathering the partial non-root picture. Fine when root is genuinely
  required (SMART data is), but on a case with real partial value (a
  root-only log where `/sys` gives half the story) the leaner prompt may
  leave that on the table. Watch for it before calling a "gather partial
  first" nudge permanently unnecessary.

---

## D_sandbox_env_wall — Why does the Bubblewrap sandbox withhold environment variables, when pikuri never filters `ENV`?

**Context.** pikuri's rule (`pikuri:` AGENTS.md "Environment is not a secret
store", commit `d97eb67`) dropped a `scrub_env!` prototype: telling harmless
variables from secrets is an unwinnable game, and outside a real sandbox a
trimmed environment closes nothing, since the child reads the token's file
anyway. That commit also said clearing belongs to the isolation boundary,
naming "Bubblewrap `--clearenv`". It was never wired: revisiting the
MCP-revisited chapter, an exported `GITHUB_PERSONAL_ACCESS_TOKEN` was
readable by sandboxed `bash`, one `env | curl` from leaving.

**The first wall stays pikuri's rule: keep secrets out of the environment.**
Review what your shell exports and move tokens into permissioned files (the
config file, `gh`'s and `aws`'s own stores), which the sandbox's mounts
already hide. The environment pikuri starts with reaches every child, and
most have no wall: language servers, bare MCP servers, `--no-sandbox` bash;
any process running as you reads it from `/proc/<pid>/environ`. What follows
is the second wall, for the one child that has walls, catching what the
review missed.

**Decision.** The environment is part of the filesystem's wall. Wherever
pikuri walls off the filesystem it walls off the environment, by the same
rule; where it doesn't, the environment passes whole. `Sandbox::Bubblewrap`
withholds every inherited variable `Sandbox::EnvWall` rejects; `NONE`,
`FullFsNoNet`, bare MCP servers and language servers pass everything. A
variable passes on a baseline name (`PATH`, `HOME`, `LANG`, `LC_*`), a
build-tool option name (`MAVEN_OPTS`, `CC`), a user's `sandbox_env:` entry,
or a **path-shaped value**. The tool description names what is withheld.

**Why.** Docker gets this for free: it carries its own filesystem and its
own environment. A sandbox is your environment with walls raised, and every
part needs one. `/tmp`, `/run`, PIDs and git config already had theirs;
variables were the missing piece. Filtering is no longer theatre there: the
unshared PID namespace keeps pikuri's own `/proc/<pid>/environ` out of
sight (measured), so a withheld variable is really gone. The path rule
carries most of the load. A path tells the child nothing the filesystem
wall doesn't govern: `JAVA_HOME` works because the JDK is mounted, and
`GOOGLE_APPLICATION_CREDENTIALS=~/key.json` is harmless because the file
isn't. A token is never path-shaped. Deny by default fails *closed and
visibly*, as a build missing `FOO_HOME`, whose name is on screen.

**Rejected.**
- **`--clearenv`.** It empties the child but leaves the secret in `bwrap`'s
  own start-up block, readable as `/proc/1/environ` (measured). The wall is
  applied to the environment `bwrap` is spawned with, as `nil` entries in the
  spawn delta.
- **A denylist** (`*TOKEN*`, `*SECRET*`, `AWS_*`). It fails open and silent on
  the first secret with an unexpected name.
- **Filtering unwalled children too.** That is `d97eb67`'s theatre: a bare
  MCP server or `--no-sandbox` bash reads `~/.aws/credentials` directly.
- **Withholding the caller's own delta.** `BundlerEnv` restorations, git
  hardening and the git identity `Bubblewrap#env` adds are deliberate settings,
  not ambient inheritance, so they win over the wall.

**Consequences.** A sandbox now answers `#env(delta)` and
`#withheld_env_names`, so a host's own sandbox must add both. A build that
needs a non-path variable outside the lists breaks until the user names it
in `sandbox_env:`. A token inside the project (`.env`) is still readable; the
workspace is reachable by design. The banner's list of withheld names
doubles as the review the first wall asks for: a secret there should leave
your shell, not just the sandbox.

## D_sandbox_own_loopback — Why does sandboxed `bash` get a network namespace of its own, when the coding agent needs the network?

**Context.** `Sandbox::Bubblewrap` kept the host's network namespace (`--share-net`) because
`git pull`, `bundle` and `mvn` need the internet. Auditing the coding-agent chapter showed what
else a shared namespace shares: loopback. From inside the sandbox, Caddy's admin API on
`127.0.0.1:2019` answered with its live config (and takes a `POST /load` that replaces it); adb,
CUPS and the mem0 API sat on the same loopback. Those services authenticate nobody because
"only local processes can reach me" was their whole model, and sandboxed `bash` counted as
local.

**Decision.** When `pasta`(1) is installed, `bwrap` runs inside a network namespace that `pasta`
connects outward: `--tcp-ns none --udp-ns none --map-host-loopback none`, no inbound ports, DNS
through `--dns-forward` to a generated `resolv.conf`. The internet and the LAN work; the host's
`127.0.0.1` doesn't, except ports the user names under `sandbox_ports:`. Without `pasta` the
sandbox logs a warning, keeps the shared namespace, and `bin/pikuri-code`'s banner says so. A
sandbox answers `#host_loopback_ports` (`nil` = all of them), and the `bash` description tells the
model `localhost` is its own.

**Why.** Loopback is where the host keeps its unauthenticated control planes, and none of them
is anything a build needs. Cutting it costs a coding agent nothing it does in a normal day; the
one real use, testing against a dev server you run on the host, is one `sandbox_ports:` entry,
named by the user, like `sandbox_env:`. `pasta` is podman's own network helper (package `passt`),
unprivileged, already installed wherever rootless podman is, and measured here: host
`127.0.0.1` and `::1` refused, the host's own LAN address shadowed (so `0.0.0.0` services are cut
too), internet, LAN, DNS and `git ls-remote` fine, about 50 ms per command.

**Rejected.**
- **`--unshare-net` plus an HTTP proxy.** The OS assistant's cut, but a coding agent's tools
  speak more than HTTP (`git://`, `ssh`, a database client), and a proxy is a service to run.
- **slirp4netns.** Also installed here, but `pasta` is the one podman now picks, and the three
  things needed (no host loopback, named forwarded ports, a DNS forward) are one flag each,
  measured.
- **Failing without `pasta`.** Unlike `FullFsNoNet`'s severed network, loopback is not the
  posture's defining property; the filesystem cage still holds, so degrading loudly beats
  refusing to start on a box without `passt`.
- **Fixing each service** (a unix socket for mem0, a password on Caddy's admin API). Worth doing
  for the ones you own, but it leaves every other local service's model broken; the namespace
  fixes the class.

**Consequences.** The LAN stays reachable, the LLM server included: the VM is still the wall
for anything on your network. `pasta` runs its command as root of a fresh user namespace, so the
sandbox passes `--uid`/`--gid` to keep `bash` under your ids. A host's own sandbox must answer
`#host_loopback_ports`. A background server started in one `bash` call was already gone in the
next (`--die-with-parent`), so per-command namespaces change nothing there.

---

## D_conversations_gem — Why does one workshop gem host conversations, rather than pikuri's `Agent` or each host?

**Context.** `Agent#run_loop` is a blocking, thread-unsafe call with rules attached: serialize
every call, reset the `Cancellable` where the turn starts (`pikuri:D_host_resets_cancel`), route
a mid-turn message to the `Interloper`, start a turn for injections left at turn end, switch
models only between turns. pikuri-webui's `Runner`, pikuri-tui's `AgentSession` and Puri's
`Conversation` each obeyed them, each a little differently — and when the reset moved to the
host, none of the three called it, so one pin bump broke cancel in all three at once. webui's
store (512 lines) and Puri's (206) wrote one folder format, and each had the same titler.

**Decision.** pikuri-conversations hosts many conversations asynchronously: the turn state
machine, the threads, the request throttle, the `/props` probe, the stored format, the folder
and the titler. **A piece leaves `Agent` if it only matters when something else runs at the same
time, or across many conversations.** One `bin/` script has neither — tools run one at a time,
sub-agents inline, so one agent tree sends one request at a time, and a bin holds one
conversation — so anything a bin needs stays in core: answering dangling tool calls, the
empty-turn guard, the `Interloper` (pikuri-code's single-threaded REPL queues a `/skill` through
it). The same rule is what the gem refuses: a UI, an HTTP server, a database, and anything one
bin needs. It lives in the workshop because a scheduler is a feature, and pikuri grows by
explaining better (`pikuri:D_gem_placement`). It is conversation-centric, as the hosts are: for
the user the conversation *is* the agent. "Session" was rejected as a name, since in webui it
reads as the HTTP one.

**Alternatives rejected.**

- **An `Agent::Runner` in core**, owning a turn queue: `pikuri:D_host_resets_cancel` says why.
- **Each host keeping its own.** Three copies drifted, and a change to `Agent`'s contract broke
  all three in the same release.
- **A grab-bag `pikuri-ext` for host utilities.** Refuses nothing, and charges every host the
  union of every utility's dependencies. A utility that fails the rule above finds another home.
- **Several gems — throttle, store, scheduler.** The parts are already independent inside one
  (`Conversations` never references `Store`; the host joins them in `on_turn_end`), and a host
  that wants only the store requires the gem and never opens a list.

---

## D_conversation_turn_state — Why a plain state machine on a thread per task, rather than a pool or a serialized executor?

**Context.** A turn holds its thread through waits that are not load: a `Confirmer` parked on a
human, a long `bash`, a router's cold model load. A sub-agent's turn runs inside its parent's.
And the cancel reset must sit in the same critical section as the move to "running"
(`pikuri:D_host_resets_cancel`).

**Decision.** One `Mutex` per `Conversation` guards a plain state machine, and the work runs on
plain `Thread`s it starts — one per boot, per turn, per title, per agent release — unbounded, with
no concurrent-ruby. Load is bounded per HTTP request by the `Throttle`, never per turn
(`pikuri:D_llm_request_throttle`). Sub-agents stay plain `run_loop` calls on the parent's thread,
sharing its token. A thread per task names itself (`turn <id>`, which webui's Puma thread dump
shows, `pikuri-webui:D_puma_thread_dump`), and its start cost is nothing beside a turn's seconds.

**Alternatives rejected.**

- **A bounded pool.** N conversations parked on N confirmations hold every worker while the
  server idles, and the next conversation cannot start. A sub-agent submitted to the pool and
  awaited deadlocks it outright: the parent holds a worker, waiting for a child queued behind it.
  webui ran turns on a fixed pool first (`pikuri-webui:D_serial_turn_executor`).
- **`Concurrent::SerializedExecution` per conversation.** With `submit` injecting into a running
  turn (`D_submit_injects`), no second turn ever queues, so per-key serialization only duplicates
  the "running" flag. Once anything does queue behind a turn, a reset at post time wipes the
  running turn's cancel.
- **Confining a conversation to one thread.** `Agent` asks only that calls don't overlap; no
  `lib/` in pikuri or the workshop reads `Thread.current`, so a turn may run on its boot thread.

---

## D_submit_injects — Why does a message sent mid-turn join the turn, and why does a cancel keep what it hadn't delivered?

**Context.** A user types while the agent works: a correction, a "also check the tests". Then
they may press stop. webui settled both for itself (`pikuri-webui:D_interloper_mid_loop_input`);
tui re-sent its pending correction as a new turn after Ctrl+C, and Puri queued messages as
turns of their own and dropped them on cancel.

**Decision.** `Conversation#submit` while a turn runs injects into the agent's `Interloper` and
answers `:injected`; the turn reads it after its current tool batch. Injections that arrive too
late for the turn's last request start a bare turn in the critical section that would have gone
idle — **only after a completed turn**: after a cancel the stop button would look broken, and
after a failure an unreachable server would spin. A cancel keeps undelivered injections, counted
in `status.pending`; the host decides what they become — the next `submit` delivers them ahead of
its message (webui, tui), a blank one alone, or `discard_pending` takes them (Puri shows what it
took).

**Alternatives rejected.**

- **Queueing each message as a turn of its own.** The correction reaches the model only after
  the turn it was meant to correct has finished.
- **Dropping the injections on cancel.** Silently discards text the user typed and never saw
  rendered.
- **Handing them back on cancel**, as text: no host can put text back into its input box.
- **A routing hook in `submit`**, for Puri's "a message typed while a confirmation waits answers
  the confirmation". The host writes `confirmer.redirect(text) || conversation.submit(text)`;
  `redirect` is atomic and answers `false` once the confirmation is gone.

---

## D_no_idle_eviction — Why is an idle conversation's agent never closed to free what it holds?

**Context.** Every open conversation holds an agent, and an agent may hold MCP servers, language
servers and a containerised extractor. Closing an idle one and rebuilding it from its `History`
on the next message looks free: `Agent.new(history:)` resumes it.

**Decision.** An agent lives until `Conversation#close`. A host closes what it is done with — webui
on delete, tui and Puri on quit — and nothing in the gem closes on a timer.

**Why not evict.** A rebuild keeps the messages and loses everything outside them: the task
list, activated skills, and what each server held. MCP's tools come back from cached schemas, but
the browser a Playwright server had logged in does not (`pikuri:D_agent_is_one_conversation`).
The user would find it gone after a coffee break, with nothing to say why. webui rejected
reaping its own runners for the same reason, until residency actually hurts.

---

## D_title_after_turn — Why is a title asked after the first turn, and fired by the gem but stored by the host?

**Context.** webui and Puri named a conversation from its opening message, each with the same
titler class, each asking beside the first turn so the title showed while the answer streamed.
On a server with one slot the title's request won the permit, and the answer waited for it
(~2 s, measured in webui).

**Decision.** A `Conversation` opened `untitled: true` asks the list's `Titler` once, after the
first turn whose history holds user text has ended — completed, cancelled or failed — on a
`title <id>` thread, through the `Throttle`, and reports `Event::Titled`. After the turn, the
turn's requests are done before the title asks, so the race is gone rather than rarer. The cost
is cosmetic: the start stamp shows until the first answer is in. A failure is logged and not
retried; reopening the conversation `untitled: true` asks again. Which model titles is the
host's (`pikuri-webui:D_titler_connection`).

**The gem fires, the host stores.** A `Conversation` never references the `Store`, so it cannot
tell a stamp-titled conversation from a named one; the host says so with `open(untitled:)`
(`Store#stamp_titled?`) and lands the title through `Store#retitle`. A title landing once the
conversation is closing is dropped, and `close` cancels its request.

**Alternatives rejected.**

- **Beside the first turn**, as both hosts did: the permit race above. One rule for every host
  wins over Puri's title-while-streaming.
- **On open**, naming a stored conversation the moment anyone looks at it: names conversations
  only read (`pikuri-webui:D_lazy_retro_titling`).
- **On a shared executor the list owns.** Every other task already runs on a thread of the
  conversation's own, which `close` and `wait_settled` know how to wait for.

---

## D_history_file — Why does the workshop own the stored form of a conversation, and why are its only doors validators?

**Context.** pikuri hands a conversation out as `Agent::History`, an in-memory value it never
writes to disk (`pikuri:D_history_value_type`): a file format means a version, validating
untrusted bytes on the way back in, and attachment files confined to a folder, none of which a
deployment that never resumes should carry. pikuri-webui and Puri do resume — after a restart,
from a sidebar — and both stored conversations through the serializer pikuri used to ship
(`#to_json` / `#save`, `.parse` / `.from_h` / `.load`, removed in pikuri `5c87269`).

**Decision.** The serializer moved here, unchanged in format, as `Conversations::HistoryFile`
in pikuri-conversations, the gem that keeps conversations; every folder webui and Puri wrote
still loads. `parse`, `from_h` and `load` are the only doors in, and each raises `Error` rather
than returning something half-built. There is deliberately no "accepts a String or a Hash or a
History" convenience: one way in means one place validation could be skipped, i.e. none.

**Versioning is additive-only, and `version` is expected to stay `1`.** Unknown *keys* are
ignored so a file from a newer writer still loads; malformed *known* keys raise; a version above
`VERSION` is refused outright rather than best-effort loaded. The survey is the evidence
(`pikuri:R_persistence`): no system examined carries a per-record schema
version it migrates on — opencode's 30 SQL migrations never once rewrite the stored JSON's
shape, and grok-build reserves `deny_unknown_fields` for tool arguments and wire protocols while
never applying it to a session type. "One migration function per version bump, kept forever"
was over-engineering nobody in the field has needed.

**Validation is asymmetric**, because `Agent.new(history:)` repairs a call left without a result
(`pikuri:D_history_load_repairs`) — refusing it would make the crash case the one thing that
cannot be loaded:

| | | |
|---|---|---|
| result with no call | refuse | unrepairable — the call cannot be invented |
| one call answered twice | refuse | a live race would dedup; in a *file* it is corruption |
| call with no result | legal, repaired on resume | what a killed process leaves behind |

**Alternatives rejected.**

- **Keeping it in pikuri.** pikuri's reasons above: a format is a feature a deployment that
  never resumes pays for, and pikuri grows by explaining better.
- **Each host keeping its own.** webui and Puri already share one folder format; two copies of
  a validator is two places to forget the symlink check.
- **Building on `RubyLLM::Message#to_h`.** ruby_llm's format for its Rails persistence, and it
  moves when ruby_llm does — 2.0 renamed `model_id` to `model` and every token key. A file
  written today must load after ruby_llm moves, and pikuri's own per-message fields (`id`,
  `kind`, the display strings) have no slot in it.
- **`Marshal` or any binary form.** Unreadable, unhand-editable, and version-fragile across Ruby
  releases — for artifacts that outlive the process.
- **A top-level array of messages.** Can never grow a sibling key; an envelope can.

---

## D_history_container — Why is a saved conversation one JSON object rather than JSONL?

**Context.** A chat client writes often and reads rarely, so appending rather than rewriting
looks like the obvious shape — three of the five harnesses surveyed use an append-only JSONL log.
The question was whether to write JSONL from the start so a later version could simply append.

Measured first, on a whole-file rewrite (`JSON.generate` + temp file + atomic rename, mean of
ten):

| conversation | file | per turn |
|---|---|---|
| 200 messages @ 1.8 KB | 0.39 MB | 1.9 ms |
| 2000 messages @ 1.8 KB | 3.86 MB | 15.7 ms |

Against a turn that spends seconds on the model, that is 0.05–0.5%. The write-often instinct is
right about the access pattern and wrong about the constant — and 2000 messages is already past
where context management forces a compaction.

**Decision.** One JSON object per conversation, rewritten wholesale. What earns it is not the
measurement but the **1:1 property**: `HistoryFile.to_json` and `.parse` are literal inverses,
and there is no writer/reader layer that can be wrong on its own. Header-plus-records makes the
file an *encoding* of the value instead of the value.

Deferring is safe because adopting JSONL later is **not a version bump and not a migration** —
it is a sniff: *if the whole file parses as a single JSON object it is the v1 container,
otherwise read it as JSONL.* Three lines, nothing on disk rewritten, every file ever written
still readable. That is what makes this reversible rather than a bet.

Whole-file rewrite is also *safer* than append: with temp-file-and-rename the file on disk is
always a complete valid history, so there is no torn state to detect. Append trades that
guarantee for O(1) writes.

**Alternatives rejected.**

- **Storing the history as one long line, "so it is trivially JSONL too".** It is valid JSONL,
  but its record type is *an entire history*. The first append leaves line 1 an envelope holding
  every message and lines 2..N bare messages — permanently bimodal, two record types for every
  reader forever. It also costs diffability: a single-line blob is one wholly-changed line in
  `git diff`.
- **Numbered `1.json` / `2.json` segments rolled at a size threshold.** Each segment is a JSON
  *array*, so appending means either rewriting it (defeating the purpose) or omitting the closing
  `]` and repairing on read — JSONL reinvented, plus a rotation threshold, a naming scheme, an
  ordering rule and a which-segment-is-current question JSONL does not have.

**Consequences.** If append ever becomes real it is JSONL, and the reader must tolerate a torn
last line (crash mid-append: drop it, keep the rest) — PI's pattern, and the reason it needs
one. The append-only log the instinct reaches for already exists one layer up: grok-build treats
its event log as ground truth with the model-facing transcript as a rebuildable cache. A
`History` is the derived snapshot, and a derived snapshot wants wholesale rewrite.

---

## D_history_attachments — Why two attachment encodings in one folder, and why are the files allowed to rot?

**Context.** `Workspace::Read` hands the model images as bytes read from a **workspace path**
that may later change or vanish, and a user attaches images to a message. A stored conversation
therefore has to decide what an attachment *is* on disk.

**Decision.** Two encodings of one in-memory value: `HistoryFile.to_json` inlines attachments as
base64 for a single self-contained artifact; `HistoryFile.save(history, dir)` writes
`history.json` plus content-addressed files under `attachments/`, named by
`HistoryFile.stored_name` (a SHA-256 prefix plus the sanitized filename). Both load back to the
same value — pinned by `load(dir) == parse(json)`, which is what stops them drifting into two
formats.

**Attachments live in the history's own folder or the history does not load.** No sanitizing a
bad path into a good one, no escape hatch for a big file. A reference is a bare basename, and the
check compares the **resolved** path — a file sitting in `attachments/` may itself be a symlink
to `~/.ssh/id_ed25519`, which every textual check passes. The digest prefix in the name is
re-checked on load, so a file swapped underneath is refused. `parse` refuses a file-backed
history outright (a String has no folder to resolve against) and names `load` instead of
guessing.

**`save` never deletes, and never enumerates the folder.** An attachment the history no longer
references — after a compaction, say — simply rots there. `HistoryFile` writes into that folder
but does not own everything in it (`Store#stash` writes there too, ahead of a turn), and
removing a file a human put there is a worse failure than an orphan. Its only read is a `stat`
per *referenced* attachment (skip if already present, the name being content-addressed), so a
folder holding a thousand stale files costs nothing per save.

**Alternatives rejected.**

- **A path reference to the original file.** Smallest on disk, and the failure is invisible: the
  bytes are re-read at load, so a resumed conversation can show the model a *different* image
  than the transcript says it saw, or `ENOENT`. opencode does this for `@file` text mentions
  while inlining everything else — which reads as drift rather than design.
- **Degrading to the metadata note**, dropping the attachment. Cheap, honest, and breaks the
  round-trip property: a resumed vision conversation is missing the picture it is discussing.
- **Lazy attachment handles** in a history loaded from a folder. Saves memory, reintroduces
  exactly the path-reference failure (the folder can change or vanish underneath), and breaks
  `==` and therefore the convergence property above.
- **Sweeping unreferenced attachments**, or reporting them so a host can. The report was dropped
  because nothing consumes it, and it was the only reason `save` would scan the directory at all.
- **A format-own attachment type** beside the `Pikuri::Attachment` pikuri carries. A
  field-for-field copy with a conversion to maintain, and no safer: a field added to one and not
  the other is dropped on save just as silently. One type, and a spec pinning
  `Pikuri::Attachment.members` instead.

**Consequences.** Orphans accumulate silently and nothing will mention them — bounded by what one
conversation produced, content-addressed so they can never collide. If it ever matters the answer
is `rm`, not a feature.

---

## D_mcp_catalog_and_connections — Why does a process build the MCP catalog once, yet every agent spawn its own servers?

**Context.** An agent is one conversation (`pikuri:D_agent_is_one_conversation`): a webui holds N
of them at once, and `pikuri-code`'s `/clear` builds a new one. `Mcp::Extension#configure` used to
start every configured server per agent — spawn, handshake, the verifier's and synthesizer's LLM
passes — and hold one process per server for the agent's life. A per-process pool of live
servers would have saved that, but a server's *state* would then cross conversations: Playwright
logged into a bank in conversation A is still logged in for conversation B. pikuri cannot know
what a foreign server holds, so it assumes every one is stateful.

**Decision.** Two halves, split by what is safe to share.

- **`Mcp::Catalog`, once per process, built by the host.** It spawns each server, verifies it,
  writes its description, records its tool list, and closes it again. Immutable, so every agent
  shares it without a lock. The host builds it (with its transport, cancellable and
  `around_request`) because it outlives every agent it serves.
- **`Mcp::Connections`, per agent, lazy.** `mcp_connect` registers tools from the catalog and
  spawns nothing; a server starts on this agent's first call to one of its tools, and dies with
  the agent. Most conversations never start one.
- **Every spawn must list the catalog's tools**, or `ClientWrapper` refuses it
  (`SurfaceChanged`), and the agent stops trying. The surface was verified in another process;
  a new process — a connection's, or a restart after a crash — may answer differently, and
  re-verifying would put the LLM call back on every connection.
- **A resumed conversation gets its tools back from its `mcp_connect` calls**, read from the
  restored history in `configure`. Scanning the connects, not the `<id>__<tool>` calls: a server
  connected but not yet used was promised its tools ("Added 25 tools"), a re-connect must answer
  "already connected", and an id may itself contain `__`. Nothing is replayed; the server starts
  blank on the next call (`pikuri:D_history_load_repairs`).

Measured with the Playwright MCP image: building the catalog left no container running;
connecting spawned none; agent A's first call started one, agent B's another, and B's snapshot
showed `about:blank` while A's showed A's page; closing both left none.

**Alternatives rejected.**

- **A shared pool of live servers behind a lock.** Cheapest, and exactly the leak above.
- **Eager connections, one process per server per agent at `Agent.new`.** Isolated, but N open
  conversations cost N × M processes, mostly for conversations that never call a tool, and
  building an agent waits on every spawn.
- **Re-verifying each new process.** Puts the verifier's LLM call on every connection.
- **Restoring from the `<id>__<tool>` calls.** Loses a connected-but-unused server, and cannot
  split an id containing `__` from its tool name.

**Consequences.** A one-agent bin spawns each server twice: once for the catalog, once on the
first call. A server that changes its tools while pikuri runs is refused until pikuri restarts
and re-verifies it. Isolation is per *process*: an `HttpEntry` connection is a new MCP session,
which isolates only what that server isolates per session — see `SECURITY.md`.

---

## D_voikko_stemmer — Why Voikko for Finnish, and why a gem of stemmers that requires no language library?

**Context.** pikuri-rag stems in Ruby behind a `stemmer:` duck (`pikuri:D_ruby_stemming`), ships
only `Stemmer::Identity`, and leaves languages here. Finnish inflects and compounds: unstemmed,
`rag_search_keywords katu` misses *kadulla*, and *kone* misses *tietokoneella*.

**Decision.** {Pikuri::Stemmers::Voikko} indexes dictionary forms through the MIT `voikko` gem,
FFI to the distro's libvoikko and `voikko-fi`. Measured over the 28 catalogs in
`/usr/share/locale/fi/` (16 319 tokens; libvoikko 4.3.3, voikko-fi 2.5): 30% of distinct words
unknown, mostly English and names, and each answers itself so `porter` still stems it; 1.08 base
forms per word; `porter` over base forms merges 4 lemma groups of 2 278, one wrongly (*tulos* /
*tulo*); 41 000 words/s, so no cache. `index_stems` adds each compound part, cut by
`Voikko::Analysis#morphemes` and analysed again.

One gem for every language, not one per language: a stemmer takes an open handle of its library
and never requires it, so no library is a runtime dependency (the specs take theirs from the root
`Gemfile`), the host adds the one it uses, and the README names what each language installs. pikuri-stemmers stays MIT beside
GPL-2 `voikko-fi`, and an English-only host installs no native binding.

**Alternatives rejected.**

- **Snowball** (`libstemmer0d`) strips suffixes instead of analysing: *kadulla* and *kadun*
  become *kadu* while *katu* stays, and it is erratic on exactly the words Voikko does not know
  (*nokian* → *nokia*, *nokia* → *nok*), so it is no fallback either. It stays the candidate for
  a language with no dictionary, and Hunspell, which has none for Finnish, for Slovak and Czech.
- **`WORDBASES` for the parts** gives roots rather than parts (*yritys* → *yrittää*) and drops
  some (*versionhallintajärjestelmää* loses *hallinta*).
- **A gem per language** (`pikuri-finnish`). Each would be one class and one README section; the
  handle injection already keeps one language's library off another's host.
- **A stemming container**, Voikko, Hunspell and Snowball behind JSON on stdio, run
  `--network=none` like `pikuri-extractors`. Convenience, not security: a stemmer is C fed
  untrusted text, but one word at a time, a far smaller surface than whole-file parsers, and
  SQLite already tokenizes the same corpus in-process. Build it when provisioning dictionaries
  across machines hurts, or once a stemmer reads more than a word.

**Consequences.**

- CI installs `libvoikko1` and `voikko-fi`; without them the real-dictionary specs skip.
- A `voikko-fi` upgrade does not rebuild an index: it shifts a few words, and libvoikko exposes no
  dictionary version for `#id` to record.
- Unmeasured on a real corpus: how often `porter` merges Finnish lemmas wrongly.
