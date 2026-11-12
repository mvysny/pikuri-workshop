# pikuri-lsp — design & threat model

The gem's cross-cutting rationale: what it declares to the trifecta
detector and why, the three boundaries a foreign binary reading your
project has to respect, and the measurements the whole design rests on.

Per-symbol truth lives in the yardoc ({Pikuri::Lsp::ClientWrapper},
{Pikuri::Lsp::LspTool}, {Pikuri::Lsp::Registry::StdioEntry}); the forks —
what was rejected on the way here — live in `design/decisions.md`, as
`D_lsp_direct_not_mcp`, `D_lsp_operation_surface`,
`D_lsp_no_startup_timeout`, `D_lsp_scheme_fallback` and
`D_lsp_trifecta_legs`.

## What it does

One tool, `lsp`, with ten read-only operations. A call names an
`operation`, a `symbol`, and usually a `file` and `line`; the tool derives
the column itself, routes to the server that claims the file, waits for
that server's index if it is still building, re-opens the document with the
bytes on disk, asks, and renders. Servers start on **first use**, and no call is ever
on a clock (`D_lsp_no_startup_timeout`), so a host
that ships the gem without configuring one pays nothing, and a registered
server for a language the project does not contain is never launched.

The enum is static and hardcoded, sourced from the harnesses that shipped
one rather than from what two servers implement (`D_lsp_operation_surface`).

Nothing here writes: no rename, no formatting, no code actions, no
diagnostics. That is what keeps the threat model closeable — the moment the
gem applies an edit it needs the `Confirmer` seam, the read-before-edit
gate, and a much longer document than this one.

## The three boundaries

A language server is a foreign binary that reads the whole project and
answers with paths, so three rules are fixed and each is greppable.

**One root, never configurable.** The `Workspace` root is the child's cwd
*and* the `rootUri` it indexes. `StdioEntry` has no `root:` or `cwd:`
field, so the server's idea of the project cannot drift from the
confinement boundary. One value, one boundary.

**Every result is a walked path.** Nothing a server returns was supplied by
the model, so no `resolve_for_read` call stands in front of it —
`pikuri:D_walked_path_denylist` territory. Every row passes
`Filesystem#denied?` before it is rendered ({Pikuri::Lsp::Sources} and the
four enumerating arms of {Pikuri::Lsp::Renderer}), which fails closed and,
under the container wiring, is the only thing between an indexed
`~/.ssh/id_rsa` and the model. A path is *printed* only where
`resolve_for_read` would open it; elsewhere the row keeps a bare basename,
which is provenance the model cannot turn into a read.

**pikuri reads `file:` and nothing else.** A result can arrive as a
server-private URI — `jdt://contents/slf4j-api-2.0.18.jar/…`
(`J_library_is_not_a_file`) — and exactly one row of
`Sources::SCHEME_REQUESTS` maps a scheme to the request that asks *that
server* for its own text. An `http(s):` URI is printed, never dereferenced:
the URI was chosen by the server, so fetching it would be egress with the
payload in the path. Adding a row is a protocol decision, in code, not a
config field (`D_lsp_scheme_fallback`).

## Threat model: the lethal trifecta

The forks behind every line of this are `D_lsp_trifecta_legs`.

```ruby
Tool::TrifectaLegs.new(
  private: filesystem.private?,   # inherited from the host's answer
  untrusted: :hard,               # unconditional
  egress_payload_review: :no_egress
)
```

Declared on the **tool**, not on the extension: `lsp` is a real
`Pikuri::Tool` registered through `Configurator#add_tool`, so
`Trifecta.build` reads its legs directly. `Lsp::Extension` deliberately
does not override `trifecta_contribution` — a duplicate declaration would
not move the verdict (legs union per label, and `legs | legs == legs`) but
would grow a `(lsp)` row beside the `lsp` row, blaming the wiring for a
declaration that lives on the tool.

### Egress: absent, not vouched

The model supplies `operation`, `symbol`, `file` and `line`, and none of it
reaches a socket — it reaches an in-memory index. A seat whose outbound
bytes do not originate in the model's choosing holds no leg to grade, which
is the same reasoning `pikuri:D_egress_axis_shape` used to drop
`egress_human_author`. Four sentences the reader is owed, none of them a
tag:

1. pikuri-lsp never dereferences a remote URI — the `http(s):` refusal and
   the one-row scheme table above, both greppable.
2. The registered server may go online on its own. jdtls resolving a jar
   from Maven Central is a function of the project's build files, and
   happens identically if the model never issues a single call. The hosts
   come from `build.gradle` / `settings.xml`, so they are
   *project*-controlled — which is why "it only fetches from vetted hosts"
   is not the argument here.
3. There is one steering path, stated so nobody thinks it was missed: the
   model edits `build.gradle`, the server re-imports, and fetches a host
   that file names. That takes a confirmed `Write`, and `bash` running
   gradle produces the same fetch — the leg belongs to `write`.
4. A malicious *registered* server means all bets are off. It needs no
   clever channel; it can POST `~/.ssh` directly. That is the same boundary
   `Mcp::Registry::StdioEntry` already has — user-chosen argv, inherited
   env, unsandboxed — so it is precedent, not special pleading.

**Why this does not collide with MCP**, which is the objection to expect:
`Mcp::Extension` declares `ASSUMED` unconditionally because the tool list
arrives at runtime from a server you did not write. Both gems spawn a
user-configured foreign stdio binary, so the parity question is fair, and
the answer is that **an MCP server contributes model-callable tools with
model-supplied arguments; an LSP server contributes none.** One
pikuri-authored tool, fixed schema, and pikuri chooses every JSON-RPC
request that leaves. No foreign tool surface, hence nothing undeclarable.

### Untrusted: `:hard`, unconditionally

{Pikuri::Workspace::Read} declares
`untrusted: filesystem.trusted? ? :none : :hard`, and that conditional
**cannot be copied here**. It works for `read` because the vouching and the
reach are the same set: the host asked a human whether this checkout is
trusted, and `read` is confined to the checkout.

`lsp` is not. The server's index reaches outside the root by design — the
whole bundle, jars, the JDK (`J_index_reaches_jars` sells that as the
feature), and `H_ancestry_leaves_root` shows a query about a workspace
class answering out of four unrelated gems. The `jdt:` row widens it once
more, pulling text out of a **jar**, the one place this gem reads bytes the
user never checked out. A user who answered "yes, I trust this repo" made a
claim about the code they checked out, not about four hundred transitive
jars Maven resolved, nor a `-sources.jar` nobody has ever diffed. No
question the host currently asks has an answer that could honestly turn
this leg off, so it is a constant.

Nor is the exposure theoretical: `F_hover_on_constants` has one `hover`
returning an entire yardoc class comment, and `J_class_file_contents` has
22,639 bytes of attached source arriving from a jar. **Quoting third-party
prose into the context in bulk is this gem's marquee feature, not an edge
case of it** — and a sources jar is the cheapest place in a dependency tree
to put text aimed at a model, since it is fetched separately from the
binary and scrutinized far less.

**The consequence, on purpose.** On an untrusted checkout nothing changes:
`read` is already `:hard` there. On a **trusted** one it does — `read`
declares `:none`, so a wiring with `fetch` or `web_search` that sits below
the verdict line today will light the untrusted leg the day `lsp` is wired
in. That is correct rather than unfortunate (the jars were never vouched
for, and a trusted repo with a poisoned dependency is the realistic attack)
but it means adding LSP to a trusted-repo session can flip the verdict, and
a user should read it here rather than discover it as an unexplained alarm.

### Private: inherited, not claimed

`private:` rides `filesystem.private?` — the host already asks whether the
project is private and feeds the map, and LSP reads the same project. No
`Lsp::Registry#private?` mirroring MCP's, because sensitivity is a property
of the files, not of who reads them.

## The unsandboxed child

`Code::Bash` defaults to `FullFsNoNet` (`--unshare-net`), and the coding
agent's prompt tells the model that the commands it runs cannot reach the
internet. **The LSP child is not sandboxed at all.** So a repo gets network
through jdtls that it explicitly does not get through `bash`.

That asymmetry is deliberate, and it cannot simply be resolved by
inheriting the bash posture: a netless jdtls cannot import a Gradle project
that must resolve its dependencies, and ruby-lsp's custom-bundle mode
shells out to `bundle install`. A sandbox that breaks the tool on its two
reference servers is not a defense, it is a removal. What contains the
child instead is the boundary above — a user-chosen binary, the same trust
decision an MCP entry already carries, with the *results* gated on the way
back in.

One thing pikuri does correct: the child is spawned de-bundlerized
({Pikuri::BundlerEnv}), so a Ruby language server resolves gems from the
project it serves rather than from pikuri's own bundle.

## Measurements

Every design call above, and every one in `design/decisions.md`, rests on these.
They are cited by id from the specs, the reconstructed fixtures
(`spec/fixtures/README.md`) and `bin/pikuri-lsp-check`, which re-measures
them against a live server and reports *ok* / *DRIFT* / *no answer* — run it
after a server upgrade. Five through the protocol client, and the two R
findings with `--drive`, which asks the same questions through the `lsp`
tool, because a fault in `Renderer` is invisible from below it. A finding
about a message pikuri may not send is in neither pass: see
`S_rangeless_didchange_crash` for why probing undefined behaviour cannot
inform a decision.

Ids are stable and never renumbered; the families mark which run produced
the finding. Where a finding was confirmed in a server's own source it says
so, and those are the ones that will not change by asking differently. The
throwaway clients' transcripts were not kept — these paragraphs are the
durable part, which is also why the fixtures are faithful reconstructions
rather than captures.

### F — first runs, `rubocop --lsp` and `ruby-lsp` 0.26.10 over this monorepo

Later re-run through a third, independent client (Claude Code's own LSP
tool) against the same repo and server version.

**F_capabilities_per_workspace.** The same `ruby-lsp` binary advertises
different capabilities in different projects: no formatting provider here
purely because pikuri's `Gemfile` has no rubocop ("Auto detected formatter:
none"), and that row flips in a rubocop-bundled project. Capability
knowledge must come from *this* workspace's `initialize` response, never
from a matrix keyed on the binary.

**F_empty_before_index.** A `textDocument/definition` fired right after
`initialized` returned `{"result":[]}` — a *successful* empty answer, with
the indexing `$/progress` `begin` arriving afterwards. For an agent this is
the worst failure mode available: the model concludes the symbol has no
definition. Non-uniform per method, too — `references` did return results
pre-index in that same run.

**F_definition_candidates.** Ruby dispatch is dynamic, so `definition` on
`workspace.resolve_for_read(path)` returned four hits: both overrides *and*
two copies inside a released gem of the very file being edited. A ranked
list of candidates, never "the definition" — and the out-of-root half is
what makes the walked-path gate load-bearing.

**F_two_location_shapes.** ruby-lsp answers with `LocationLink`
(`targetUri` / `targetSelectionRange`), not plain `Location`; servers choose
by the `linkSupport` capability the client declares. Parse both.

**F_fuzzy_workspace_symbol.** Query `resolve_for_read` returned
`resolve_for_write`, `resolve` and `oversized_root_refusal` — matched on
scattered letters. Any name→position hop must filter for exact-name hits
before feeding a position onward.

**F_reference_volume.** 40 hits for `resolve_for_read`: 4 lib call sites, 2
declarations, **34 spec hits**. Reproduced to the exact number by the third
client, uncapped and ungrouped. `definition` and `hover` on a *constant*
are worse — every file reopening `module Faraday` is a definition of it, so
one call returned 45 locations.

**F_position_encoding.** Offer `general.positionEncodings:
["utf-8","utf-16"]` and ruby-lsp picks `utf-8`, removing the UTF-16
code-unit conversion. jdtls ignores the offer entirely and answers
`positionEncoding: nil`, staying on the 3.17 utf-16 default — so the
conversion is mandatory code exercised by one of the two shipped examples,
not a fallback for a hypothetical server.

**F_hover_on_constants.** `hover` on `Pikuri::FileType` returned the
constant, a definition link and the *entire* yardoc class comment; `hover`
on a `def` line returned nothing at all. ruby-lsp resolves documentation
through its constant index, so hover's value is split down the middle — on
a constant it answers "what is this class for?" in one call.

**F_unadvertised_providers.** ruby-lsp advertises 23 capability keys, 20 of
them providers. **Absent:** `typeDefinition`, `implementation`,
`declaration`, `callHierarchy` — and calling one anyway returns
`Method not found: textDocument/typeDefinition`, the raw protocol error a
shipped client leaks rather than a clean refusal.

### J — `jdtls` 1.58 / JDK 25

Three fixtures: a two-file plain-Java project, and a copy of the
`vaadin-boot` Gradle multi-module repo run cold and warm (copied to a
scratch dir precisely because a jdtls import writes `.project` /
`.classpath` / `.settings/` into the project directory).

**J_progress_opt_in.** Declare `window.workDoneProgress: true` and tokens
flow; omit it and jdtls emits **zero** `$/progress` messages, narrating
startup only through `language/status`, a custom notification outside the
spec. The readiness signal is contingent on what the client asked for.

**J_readiness_edge.** A cold Gradle import held one `Initialize Workspace`
token open from 2.08s to 76.43s — a good edge. But it is bracketed by
transient tokens: the plain project produced eight, several opening and
closing inside the same millisecond, and there **all** tokens closed 0.9s
before the server could answer. "No tokens open" is a false ready-edge; the
settle debounce is what makes the rule usable, and a debounce is not a
timeout — it never abandons the wait.

**J_jdtls_defers_replies.** Every `definition` sent during that 74-second
import got *no response at all*; the backlog flushed at 77.87s with correct
answers. `F_empty_before_index` is a ruby-lsp behaviour, not LSP's — and
since a false-early gate is harmless against a server that defers and
essential against one that lies, one generic quiescence gate covers both.

**J_init_options_required.** Navigation to any library symbol returned
`0 location(s)` — silently, with empty diagnostics, so the classpath was
fine. jdtls withholds library definitions unless the client declares
`initializationOptions.extendedClientCapabilities.classFileContentsSupport`,
another non-spec extension. Declaring it flips `LoggerFactory` from nothing
to a hit in the same warm 7.7s.

**J_library_is_not_a_file.** That hit came back as
`jdt://contents/slf4j-api-2.0.18.jar/org.slf4j/LoggerFactory.java?=…`, a
virtual URI. `Filesystem#denied?` cannot be applied to it and the model
cannot `read` it, so for non-`file:` results the tool must return *content*
or forfeit library navigation. The URI itself runs to ~300 characters, its
query string encoding the whole classpath entry — never show one to the
model.

**J_class_file_contents.** `java/classFileContents` answered that URI in
10ms with **22,639 bytes**, the complete attached source from the sources
jar. Two consequences: the reply is a bare String, not the `{text:}` object
a spec-shaped request returns, so the parse layer accepts both; and a whole
class is far too much for one observation.

**J_warm_start.** Same repo, same `-data`: 78s cold, 7.7s warm. That is why
the data directory belongs in `Paths.cache` (shared, persistent) rather
than `Paths.new_temp`.

**J_index_reaches_jars.** `workspace/symbol("StringUtils")` returned 5
hits, every one a `jdt:` URI inside a binary jar. The decisive case is
`ArrayUtils`, which appears nowhere in the source and is never imported: 2
hits anyway. Grep over the project finds nothing and grep over `~/.m2`
finds unreadable binary. Prefix queries work and are noisy (`StringUt` → 11
hits), which is `F_fuzzy_workspace_symbol` confirmed on a second server.

**J_type_definition_recovers_var.** With `var names = new
ArrayList<String>()`, `typeDefinition(names)` → `java.util.ArrayList` while
`definition(names)` → the local declaration. Different answers to different
questions, and with `var` the type appears nowhere in the source, so
nothing else can recover it. `implementation` resolves an interface to its
implementor and works at method level too.

### H — type hierarchy, both servers

ruby-lsp against this repo (`H_subtypes_stub` … `H_qualified_name_match`),
then jdtls 1.58 against a six-file UI-shaped fixture built for the
argument: `Widget` (abstract) ← `Panel` ← {`FancyPanel`, `Button`},
`Clickable` (interface) ← `Button`.

**H_subtypes_stub.** Every ruby-lsp `typeHierarchy/subtypes` call returned
nothing, from `prepare` items that `supertypes` then answered correctly.
The reason is in `server.rb:1203`: `# TODO: implement subtypes`, replying
`nil`. An advertised capability wired to a stub — and **a capability gate
cannot catch it**, because one provider key covers both directions and
ruby-lsp advertises it truthfully for the half that works.

**H_namespace_reopenings.** `supertypes(Pikuri::Workspace::Read)` → **14
results, every one named `Pikuri::Tool`**, one per file that reopens the
namespace, with the real declaration ordered *last*. Grouping by name and
preferring the declaration is mandatory; capping alone cuts the useful row.

**H_ancestry_leaves_root.** `supertypes(Pikuri::Tool)` → 6 results, all
`Object`, out of an `.rbs` core stub and four unrelated gems that merely
reopen `Object`. Out-of-root, useless, and arriving from a query about a
workspace class.

**H_no_module_ancestry.** `prepare` on `include Pikuri::Agent::Extension`
resolves the module cleanly, and then **both** directions return 0. "Who
includes this module?" is unanswerable, and so is `include`/`prepend`
ordering — the one thing the hierarchy was promoted for.

**H_keyword_anchor_empty.** `prepareTypeHierarchy` at the first non-space
column of a declaration line returned 0 items in 6 cases out of 6; at the
column of the symbol text itself, exactly 1 in all six. And
`workspace/symbol`'s own reported column for `class Tool` is **2** — the
keyword — so feeding a symbol hit's range straight back in is the failure,
not the shortcut.

**H_qualified_name_match.** `workspace/symbol` indexes the *fully
qualified* name, so `"Confirmer"` → 25 hits, **0 of them a class**;
`"Tool"` → 81 hits, none of them `Tool` itself. Both halves are deliberate
in the source: `workspace_symbol.rb` sets `name: entry.name` (the FQN), and
`index.rb:199` scores with `DidYouMean::JaroWinkler` against
`ENTRY_SIMILARITY_THRESHOLD = 0.7`, which is prefix-weighted — so a short
query against a long namespaced name falls off a cliff. An exact-name
filter must compare the **last `::` segment**, never `name`.

**H_implementation_is_transitive.** On jdtls, `goToImplementation` answers
"list all subtypes" transitively in one call, and on concrete classes too:
`Panel` → 2, abstract `Widget` → **3**, interface `Clickable` → 1, concrete
method `paint` → 2 overriders. The concrete-class row is the surprising one
and the deep-UI case.

**H_subtypes_direct_only.** jdtls's `typeHierarchy/subtypes` works but is
*strictly weaker* for the same question: `Widget` → **1** (the direct child)
against `implementation`'s 3, with one round trip per level to descend.
Combined with `H_subtypes_stub`, there is **no server on which `subtypes`
is the best available answer**.

**H_supertypes_no_substitute.** From `FancyPanel`: `Panel`, then `Widget`,
then `Object`, one call per level. `goToDefinition` on the name after
`extends` answers one level for free, so the value is specifically the
*chain*, which a tool can walk internally. Note where level 3 landed —
`Object` came back as a jar URI, so an ancestor walk reaches non-`file:`
results routinely.

**H_references_not_substitute.** `references(Widget)` → 4 hits, of which
exactly **one** is the `extends` site; the rest are variable declarations.
Nothing in the reply labels which hit is a subtype, and the
signal-to-noise only worsens with a widely-used base class.

### S — document sync and anchoring, both servers

The fixture renames a method **and** shifts it by three lines, so
memory-vs-disk shows up in the name and in the position independently.

**S_rangeless_didchange_crash.** Both servers advertise *incremental* sync,
so the rangeless whole-document `didChange` is a shape neither one asked
for. jdtls tolerates it and updates correctly; ruby-lsp raises inside
`document.rb:98` (`push_edits` reads `edit[:range][:start]`
unconditionally), keeps its **old** text, and — a notification having no
reply channel — reports only a `window/logMessage` line, so what the *model*
sees is the next query failing with a raw Ruby backtrace.

This is a measurement of *our* misuse, not of a server bug. Which arm of the
`TextDocumentContentChangeEvent` union travels is the **server's** call,
declared as `TextDocumentSyncKind`; a client must support both so it can
comply with either, and may not substitute the one it prefers. Shopify has
closed that report three times — ruby-lsp
[#575](https://github.com/Shopify/ruby-lsp/issues/575),
[#1273](https://github.com/Shopify/ruby-lsp/issues/1273),
[#3148](https://github.com/Shopify/ruby-lsp/issues/3148), and in #1273 the
reporter was the author of the ycmd client and ended up agreeing. Kept as a
finding because it is what a naive port of the editor mechanism does, and
deliberately **not** probed by `bin/pikuri-lsp-check`: the response to a
message the server never agreed to accept is undefined, so no outcome can
inform a decision, and an "it works now" reading would mean only that this
one server tolerates what the contract still forbids.

**S_index_desync.** The *ranged* whole-document change is honoured by both
for the document itself, and then desynchronizes ruby-lsp's index from it:
`documentSymbol` reports the renamed method while `definition` on that same
method returns `[]`. `RubyDocument#should_index?` reindexes only when the
edit's start position looks like a declaration, and a whole-file replace
starts at 0:0 — the `frozen_string_literal` comment. The optimization that
makes editor typing cheap makes whole-file replacement invisible.

**S_didopen_jdtls_only.** ruby-lsp answers `definition` and
`documentSymbol` for a document that was never opened, because `Store#get`
reads from disk for any URI it does not hold. On jdtls the same `definition`
returned `[]` while `documentSymbol` worked — so the precondition is
per-server *and* per-operation, and readable off no handshake.

**S_index_follows_didopen.** On ruby-lsp a `.rb` file created after boot is
invisible to `workspace/symbol` however long you wait; one `documentSymbol`
against it makes it a hit, because `server.rb:495` reindexes while serving
that request family. An operation nobody would call for its result can be
the only way to freshen the index.

**S_reopen_works.** Re-sending `didOpen` with the current disk text before
every call works on **both** servers and is the only mechanism that does:
both replace their copy wholesale, both resolve the renamed symbol at its
shifted position, and ruby-lsp's index flips too. It is spec-forbidden (a
document must not be opened twice) and neither server minds. No versions,
no digests, and the text it needs is the text the tool already read to
derive the column. What pikuri does *not* take from "neither server minds"
is permission to skip the matching `didClose` — the close is owed by the
contract rather than earned by a measurement, so it is sent per call and
is the one piece of this policy no probe re-measures (`D_lsp_document_sync`).

**S_didclose_ruby_only.** `didClose` drops ruby-lsp's store entry so the
next request re-reads disk; jdtls keeps answering its pre-close copy. The
close-and-forget scheme is not portable, which is what promotes
`S_reopen_works` from an option to the policy.

**S_watched_files_ignored.** `workspace/didChangeWatchedFiles` changed
nothing on either server while the client owned the URI. ruby-lsp's source
states the rule outright — `index.handle_change(uri, content) unless
@store.key?(uri)` — a client that opened a document is presumed to be its
authority, which is exactly the assumption an agent writing straight to
disk breaks.

**S_anchor_strictness.** Probing every token of a Java declaration:
`prepareTypeHierarchy` returned 1 item at **every** column including the
keywords (ruby-lsp returns 0 at the keyword, `H_keyword_anchor_empty`),
while `definition` returned 0 at both keyword columns. And
`workspace/symbol`'s reported column is the *symbol* column on jdtls
against ruby-lsp's *keyword* column. The two servers disagree about both
halves, in opposite directions, per operation.

**S_wrong_anchor_explodes.** `references` at the return type of
`public String greet(String name)` returned **80,609** locations; at the
parameter type, the same 80,609; at `greet`, 2. The volume problem has no
ceiling, and a cap is not an optimization.

**S_jdtls_types_only.** jdtls's `workspace/symbol` returns types only:
`"shout"` (a method in the fixture) → **0 hits**; `"greet"` → 1 hit, which
is the *class* matched on a substring. This is `H_qualified_name_match`
inverted — there a bare name misses because the index stores FQNs, here a
method name misses because the index stores no methods at all.

**S_language_id_ignored.** The same `.rb` file re-opened under five
`languageId`s: `ruby`, `python` and `x-nonsense` behaved identically, while
**`erb` and `rbs` returned `nil` and zero symbols**, silently. ruby-lsp
selects a document class by id and falls through to the Ruby parser for
anything unknown, so garbage is safe and plausible-but-wrong is fatal and
quiet. jdtls ignores the field outright. That inversion is why pikuri
derives the value from a built-in table instead of asking a user to type
it.

### E — the `lsp` tool driven end-to-end, `ruby-lsp` 0.26.10 over this monorepo

A fourth run, and the first through the *tool* rather than the protocol:
`LspTool` over a real `Servers`, called across all ten operations, so
`Navigator` dispatch, `Anchor`, `Sources` and `Renderer` were in the path.
The F / J / H / S runs all probed the client beneath that, which is why a
rendering fault survived them. Both findings here were *spotted* through the
tool and then isolated with raw requests, which is what `--drive` exists to
repeat: `bin/pikuri-lsp-check --drive` re-measures them.

**E_hover_not_on_a_def_line.** `hover` on ruby-lsp answers where a name is
*used*, and on a constant wherever it appears — but not on the `def` line of
the method it names. Five anchors, one server, one run: a method
declaration → `nil`; the same method at a call site → 561 bytes; `class
Sources` on its own declaration line → 2,752 bytes; a constant reference →
1,011 bytes; a local variable → `nil`. So it is not "declarations are
silent" (a class declaration is the richest answer of the five) but
specifically a method's own name at its definition, which has no receiver to
resolve.

That is the anchor an agent reaches for first. Asked to document a method,
the natural line to name is the one holding `def`, and on this server it is
the single position that answers nothing — while the tool's honest report
("the server answered no results … not proof that none exist") gives the
model no hint that a call site would have worked. Deliberately **not** fixed
in the `hover` summary the model reads: this is one server's behaviour, jdtls
answers hover on a method declaration, and a per-server hint in a shared
description is the known-stub list `D_lsp_operation_surface` refuses. The
route that does work project-wide is `documentSymbol`, already the documented
answer for a method a project-wide index does not hold.

**E_same_line_references.** `references(resolve_for_read)` returned two
locations on one line — `def resolve_for_read(path) = @filesystem.resolve_for_read(path)`,
a declaration and a call — and they rendered as two byte-identical rows,
counted twice in the header and charged twice against the group cap. pikuri
prints no column by design, so column-distinct results are row-identical, and
the dedupe has to be on the rendered row: `Location` identity does not
collapse them. Not specific to endless-method style — any `foo(foo(x))`, or a
declaration whose body re-invokes it on one line, does the same.
