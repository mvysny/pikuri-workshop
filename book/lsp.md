# Language intelligence: the questions grep cannot answer

The coding agent you met in [the shell chapter](shell.md)
can read files, search them, and run your build. Ask it a question about
*meaning* and it starts guessing.

Here is the question that motivated this gem, in the author's own words:

> `ConfirmerPopup` vs `ask` vs the pikuri `Confirmer` interface is exactly
> the kind of thing an LSP hop settles in one call.

Grep can find the string `ask` in four hundred places. It cannot tell you
which `ask` the call at `read.rb:165` reaches, which class actually
implements the seam, or what the chain of ancestors above it is. Those are
questions a *parser with a project-wide index* answers, and every language
you work in already ships one: the language server your editor talks to.

This chapter wires one onto an agent. It is a short gem — one tool, ten
read-only operations — but it is the chapter with the highest density of
**silent failures** in the book, and that is why it is worth reading even
if you never configure a language server. The lesson underneath it is
general: *a protocol designed for a human staring at an editor pane
answers an agent's questions with well-formed lies, and the framework's
job is to keep the lies apart from the truths.*

The transcripts below were measured in pikuri's own repository, where this
gem was written, so they name pikuri's classes. Run against the workshop's
checkout the names differ; the shapes do not.

## What a language server actually is

Sixty seconds of protocol, because the shape explains most of the design.

A language server is a **child process** speaking JSON-RPC 2.0 over its
own stdin/stdout, with LSP's framing:

```
Content-Length: 87\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{…}}
```

Header block, `\r\n\r\n`, then exactly N bytes of JSON. No newline
delimiting: read the header, then `read(n)`.

Three message shapes — **request** (has an `id`, expects a response),
**response** (echoes the `id`), **notification** (no `id`, no reply). The
channel is bidirectional and asynchronous: the server sends *you* requests
too (`window/workDoneProgress/create`, `workspace/configuration`) and may
block waiting for your answer. So a client is a demux loop keyed on `id`,
never a "write, then read the next message" pair. Lifecycle:
`initialize` (request) → `initialized` (notify) → work → `shutdown`
(request) → `exit` (notify).

That is genuinely most of it. The non-obvious core is about twenty lines:

```ruby
def write(msg)
  body = JSON.generate(msg)
  @stdin.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  @stdin.flush
end

def read
  headers = {}
  while (line = @stdout.readline("\r\n").chomp("\r\n")) != ''
    k, v = line.split(': ', 2)
    headers[k.downcase] = v
  end
  JSON.parse(@stdout.read(Integer(headers.fetch('content-length'))))
end
```

pikuri writes its own client rather than taking a gem, and the reason is
worth knowing before you go looking for one: **there is no Ruby LSP client
gem.** `lsp-client` on rubygems is an empty placeholder — 35 bytes of
tarball. `language_server-protocol`, with its 283 million downloads, is
the *protocol SDK*: framing plus typed structures, no lifecycle, no id
correlation, no spawn, and a reader shaped for a server's main loop.
Everything else with a promising name *is* a server. The structural reason
is that LSP clients live in editors, and editors are written in
TypeScript, Rust, Emacs Lisp and Vimscript. Nobody needed a Ruby client
until agents wanted language intelligence.

Two coordinate details that cost more than they look. LSP positions are
**0-based** in both axes, and its `character` is an offset in **UTF-16
code units** unless you negotiate otherwise — offer
`general.positionEncodings: ["utf-8", "utf-16"]` and ruby-lsp takes
`utf-8`, while jdtls ignores the offer entirely and stays on utf-16. So
the conversion is not a fallback for a hypothetical server; it is code one
of the two servers in this chapter needs on every single call. pikuri
converts in exactly one place, and everything above it is 1-based, because
the model reads files through a tool that prints 1-based line numbers.

## The failure mode that shapes everything: a successful empty answer

Point a fresh client at a project, send `textDocument/definition`, and you
can get this back:

```json
{"result":[]}
```

A successful, well-formed, empty answer. The indexing progress
notification arrives *afterwards* — the server had not read your project
yet, and said so nowhere.

For a human in an editor this is a non-event: you press the key again a
second later. For an agent it is the worst answer available, because the
model does not conclude "too early", it concludes **"this symbol has no
definition"** and proceeds to act on that. It will hand-roll the function
it could not find, or tell you the method does not exist.

And the two reference servers fail *oppositely*, which is the detail that
makes a generic rule possible:

- **ruby-lsp answers early and wrongly** — the `[]` above.
- **jdtls does not answer at all.** During a 74-second cold Gradle
  import, every `definition` sent got no response whatsoever; the whole
  backlog flushed at 77.87s with correct answers.

So there are three genuinely different things a client can be looking at,
and an agent has to be able to tell them apart:

1. **The server does not support this operation** in this workspace.
2. **The server answered, and the answer was nothing.**
3. **The server could not be asked** — still indexing, or dead.

pikuri keeps them as three distinct sentences the model reads, and that is
the most consequential rendering rule in the gem:

```
Error: the ruby server does not support goToImplementation in this workspace
— it advertises no implementationProvider

The server answered no results for goToDefinition on "resolve_for_read".
That is what it said, not proof that none exist.
```

The third is not a sentence at all: pikuri **waits**, which is the next
section.

### What a shipped client does instead, and why it is worse

This is not a strawman. Claude Code ships its own LSP tool with nine
operations, and run against pikuri's repo on the same ruby-lsp version,
its first `goToDefinition` after startup returned:

```
No definition found. This may occur if the cursor is not on a symbol,
or if the definition is in an external library not indexed…
```

Two guesses offered for at least four real causes — and the actual one
here, that the index did not exist yet, is not among them. The readiness
signal was
right there: a `hover` issued in the same batch correctly failed with
`server is starting`. One code path used it and another did not.

The same client, asked about a file outside the project it was rooted at,
also said `No definition found`. The honest reason existed —
`VaadinBootBase.java is a non-project file, only syntax errors are
reported` — and went to the editor-diagnostics side channel, where no
model would ever see it.

**Collapsing "I don't know" into "there is nothing" is how a harness
teaches a model a falsehood.** It is a rendering rule, not a per-server
workaround, which is what makes it cheap enough to have no excuse for.

### The one place pikuri waits instead of reporting

Every other server misbehaviour in this chapter gets *relayed*: the tool
says what the server said and lets the model decide. Indexing is the
exception, because there is nothing in `[]` for a model to reason about.
So the first call against a cold server blocks until the index is built,
and the rule is one line, the same for every server: **no progress token
open, and nothing said for 1.5 seconds.**

Four things about that rule earned their way in by measurement:

- **You have to ask for progress.** Declare
  `window.workDoneProgress: true` in the handshake and tokens flow; omit
  it and jdtls emits *zero* `$/progress` messages, narrating its startup
  only through `language/status`, a custom notification outside the spec.
  The readiness signal is contingent on what the client asked for.
- **Quiescence alone is a false edge.** A cold Gradle import held one
  `Initialize Workspace` token open from 2.08s to 76.43s — a clean edge —
  but a plain two-file project produced eight transient tokens, several
  opening and closing inside the same millisecond, and there *all* tokens
  were closed 0.9 seconds before the server could answer anything. Hence
  the settle debounce, which is not the timeout: it never abandons the
  wait, it only refuses to call an idle moment the end.
- **There is no clock anywhere.** No startup timeout, no per-call
  deadline. A cold jdtls import against a real multi-module repo took 78
  seconds, and any timeout short enough to be useful as a liveness check
  is short enough to abort that. What replaces it: progress events the
  host renders, and Ctrl+C — **the human is the timeout**
  (`D_lsp_no_startup_timeout`). Warm, that same project came up in 7.7s,
  which is why a server's data directory belongs in a persistent cache
  rather than a per-run temp dir.

- **The window opens at `initialized`, not at spawn.** This one was found
  re-running the chapter's diagnostic for this book: on a cold start, two
  runs in nine declared the index ready and then got nothing for every
  question. ruby-lsp spends about six seconds answering `initialize`, and
  only after `initialized` does it open its indexing token. pikuri had
  started the quiet clock when it spawned the child, so the handshake
  itself counted as 1.5 seconds of silence, and a wait that began before
  the token arrived returned at once, to an empty index: the exact `[]`
  this section exists to prevent. The clock now restarts when `initialized`
  goes out, keeping any task the server opened meanwhile; six cold runs
  after the fix answered correctly every time.

Waiting costs real time only once. In a fresh run against pikuri's monorepo
the first call paid 6.1 seconds for ruby-lsp's index; every later call in
the same session came back in 0.00–0.41s.

## Capabilities are per workspace, not per binary

The handshake's `initialize` response is where a server declares what it
can do. The instinct is to record that per binary — "ruby-lsp supports
these things" — and it is wrong.

The same ruby-lsp binary advertises **different capabilities in different
projects**. In pikuri's monorepo it offers no document-formatting provider,
purely because pikuri's `Gemfile` has no rubocop in it ("Auto detected
formatter: none"); in a rubocop-bundled project that row flips. Capability
knowledge has to come from *this* workspace's response, every session.

The absences bite harder than the presences. ruby-lsp advertises 23
capability keys, and four of pikuri's ten operations are not among them:

```
not advertised here: goToImplementation, goToTypeDefinition,
                     incomingCalls, outgoingCalls
```

Call one anyway and the raw protocol error comes back —
`Method not found: textDocument/typeDefinition` — which is what the
shipped client leaks to its model. pikuri checks the advertised capability
at dispatch and refuses in its own words, naming the missing provider so
the model learns *why* rather than that the tool is flaky.

Which raises the obvious question: if capabilities are per workspace, why
is the tool's `operation` enum static? Because a schema computed from live
capabilities would have to advertise the union of every registered
server's anyway, and would silently *move* whenever a server restarted or
a project gained a formatter. A moving tool description is worse than a
fixed one the model can learn. **Static enum, gate at dispatch.**

## Four silent-empty traps, which are one trap wearing four hats

Now the part that generalises past LSP. Each of these returns a
well-formed, successful, empty-or-wrong answer, with nothing anywhere
saying "I could not really answer that":

1. **The index does not exist yet.** The `[]` above.
2. **An init option you did not declare.** Navigation to any Java library
   symbol returned `0 location(s)` — silently, with clean diagnostics, so
   the classpath was demonstrably fine. jdtls withholds library
   definitions unless the client declares
   `initializationOptions.extendedClientCapabilities.classFileContentsSupport`,
   a non-spec extension. Declare it and `LoggerFactory` goes from nothing
   to a hit in the same 7.7 seconds.
3. **A fuzzy index hit that is not your symbol.** `workspace/symbol` is a
   *fuzzy* search on every server, and the fuzziness differs. ruby-lsp
   indexes **fully qualified** names and scores queries with
   Jaro-Winkler against a 0.7 threshold, so a bare `Confirmer` scores
   0.455 against `Pikuri::Workspace::Confirmer` and is never returned —
   while 27 unrelated things that share some letters are. jdtls's index
   holds **types only**, so a Java method name returns 0 hits and a class
   matched on a substring. Feed either straight into a position-based
   call and you have navigated confidently to the wrong symbol.
4. **An advertised provider wired to a stub.** ruby-lsp advertises
   `typeHierarchyProvider` truthfully — its `supertypes` half works — and
   every `subtypes` call returns nothing, because the implementation is
   `# TODO: implement subtypes`, replying `nil`. **A capability gate
   cannot catch this**, because one provider key covers both directions.

There is a fifth cousin worth the sentence, because it inverts the usual
"garbage in, error out" expectation. The `languageId` a client sends on
`didOpen` is free-form, and re-opening the same `.rb` file under five of
them showed `ruby`, `python` and `x-nonsense` behaving identically —
while `erb` and `rbs` returned `nil` and zero symbols, silently. Nonsense
is safe; **plausible-but-wrong is fatal and quiet.** That is why pikuri
derives the id from a built-in extension table instead of asking a human
to type one.

Here is trap 3, live, and how pikuri renders it — note the last line,
which is the whole point:

```
workspaceSymbol "Confirmer" — 27 symbols

  pikuri-code/lib/pikuri/code/extension.rb:99  field @confirmer  @confirmer = confirmer
  pikuri-workspace/lib/pikuri/workspace/confirmer.rb:123  method confirm?  def confirm?(request:)
  pikuri-core/lib/pikuri/agent/extension.rb:46  method configure  def configure(c); end
  … (22 further rows elided here; the real observation shows 25 of the 27)
  ... 2 more, not shown

Notes:
- no symbol is named "Confirmer" here; the full list follows.
```

The list is still useful — it is the fastest way to see what *is* in the
index — but the model is told, in one sentence, that nothing in it is the
thing it asked for.

## An agent is not an editor, so it does not own documents

LSP has a document model, and it assumes the client is a text editor: you
`didOpen` a document, you stream `didChange` edits as the human types, the
server holds the buffer, and the file on disk may be stale for hours.

An agent breaks that assumption at the root. When pikuri's `write` or
`edit` tool runs, the bytes land **on disk, immediately**. There are no
unsaved buffers, ever. So the tool never owns text the disk lacks — and
the correct thing to send is not an edit stream at all.

Getting there took a measurement run per candidate, and every
option lost:

- **A rangeless whole-document `didChange`** — the obvious "here is the
  file's new text" move — leaves jdtls correctly updated and **crashes
  inside ruby-lsp**, which reads `edit[:range][:start]` unconditionally.
  The document keeps its *old* text. A notification has no reply channel,
  so the only report is a `window/logMessage` line; what the model sees is
  the next query failing with a raw Ruby backtrace. But the crash is not
  really why it loses: **this shape was never ours to send.** Both servers
  advertise *incremental* sync, and `TextDocumentSyncKind` is how a server
  declares which of the two shapes it accepts — a client has to support
  both precisely so it can comply with whichever it is handed, and pick
  neither. Shopify has closed that bug report three times, once from the
  author of a client who then agreed with them.
- **The ranged whole-document change** is honoured by both — and then
  desynchronizes ruby-lsp's *index* from the document it just updated:
  `documentSymbol` reports the renamed method while `definition` on that
  same method returns `[]`. The cause is an optimization,
  `RubyDocument#should_index?`, which reindexes only when the edit's start
  position looks like a declaration — and a whole-file replace starts at
  line 0, column 0, which is the `frozen_string_literal` comment. **The
  optimization that makes editor typing cheap makes whole-file
  replacement invisible.**
- **`didClose` and forget**, as the refresh mechanism, drops ruby-lsp's copy so the next request
  re-reads disk, and does nothing at all on jdtls, which keeps answering
  its pre-close copy.
- **`workspace/didChangeWatchedFiles`**, the spec's own out-of-band "the
  disk changed" channel, changed nothing on either server. ruby-lsp's
  source states the rule outright: it handles the change *unless the
  client already holds that URI*. **A client that opened a document is
  presumed to be its authority** — which is exactly the assumption an
  agent writing straight to disk violates.

What works on both servers is the thing the spec forbids: **re-send
`didOpen` with the file's current disk text before every call.** No
versions, no digests. Both servers replace their copy wholesale, both
resolve a renamed symbol at its shifted position, and ruby-lsp's index
flips over too. The spec says a document must not be opened twice; neither
server minds.

That "neither server minds" is worth being uneasy about, and it is why the
matching **`didClose` is sent** even though no measurement asked for it.
The spec caps a document's open count at one and wants the pair; a client
that only ever opens is not resting on a measurement but on two servers'
tolerance, and no number of additional servers tested converts tolerance
into a guarantee. A server that trusted the count could leak a document per
call, or answer from a buffer it should have dropped. So the close is sent
because it is owed — and the deviation shrinks to one, re-opening a
document that is already open.

Two details in that close are the kind protocol code gets wrong. It goes
out **after the reply**, not alongside the request: ruby-lsp happens to be
safe either way because it runs a single worker thread, but a server
answering in parallel could process the close first and answer about a
document it had just dropped. And it brackets the whole *call*, not each
request — `supertypes` asks a `prepare` hop and then one request per level
about the same document, so closing after the first would sabotage the
rest.

It is also nearly free, and that is not luck: the text pikuri sends is the
text it already read to work out the column, which the next section
explains.

The portable lesson: **when your process model differs from the one a
protocol assumes, expect to violate the spec exactly there** — and pin
the violation with a diagnostic you can re-run, not with a reading of the
specification.

## Never ask the model for a coordinate it has never seen

Every position-based LSP request takes a line *and a character*. The
shipped clients take both from the model. pikuri takes a **name**:

```ruby
lsp(operation: 'goToDefinition',
    symbol: 'resolve_for_read',
    file: 'pikuri-workspace/lib/pikuri/workspace/read.rb',
    line: 165)
```

The column is derived — one line read, one string search, no index and no
server involvement. The reason is not that the arithmetic is hard, it is
that **nothing in the model's input contains a column.** `read` prints
line→text; `grep` prints `file:line:text`. A column could only be
*invented*, by counting characters in a line the model saw as prose, with
tabs and multibyte and exactly the failure profile you would expect.

And being wrong is not an error, which is what makes it dangerous:

- `references` at the return type of `public String greet(String name)`
  returned **80,609 locations**. At the parameter type, the same 80,609.
  At `greet`, 2.
- `prepareTypeHierarchy` at the first non-space column of a declaration
  line returned 0 items in 6 cases out of 6 on ruby-lsp, and exactly 1 at
  the column of the symbol text itself. On jdtls it answers from *every*
  column including the keywords — while `definition` there returns 0 at a
  keyword column. The two servers disagree about both halves, in opposite
  directions, per operation.

That second one has a corollary worth internalising: `workspace/symbol`
reports the *keyword* column on ruby-lsp (`class Tool` at column 2) and
the *symbol* column on jdtls. So feeding an index hit's own range back
into a position-based call is the failure, not the shortcut. The column
always comes from the line's text.

`symbol` alone still works — it searches every configured server's index —
but it is best effort, for trap 3's reasons, and it says so when it comes
up empty:

```
Error: "ConfirmerPopup" is not in any server's index. Pass file: (and line:)
to anchor the query on a line you have read — a bare name is matched against
fully qualified names, and some servers index no methods at all
```

## What the model actually reads back

An LSP answer in an editor lands in a pane a human scrolls. An LSP answer
in an agent lands in a **context window**, and the volumes are not
editor-shaped. So the renderer caps and groups, which no shipped client
does:

```
findReferences "resolve_for_read" — 57 results

In source (12):
  pikuri-lsp/lib/pikuri/lsp/anchor.rb:143  resolved = filesystem.resolve_for_read(file)
  pikuri-lsp/lib/pikuri/lsp/navigator.rb:297  resolved = @filesystem.resolve_for_read(file)
  pikuri-workspace/lib/pikuri/workspace/filesystem.rb:218  def resolve_for_read(path)
  …

In tests (45, showing 5):
  pikuri-workspace/spec/pikuri/workspace/filesystem_spec.rb:144  assert_equal ws.temp + 'foo.txt', ws.resolve_for_read('/tmp/foo.txt')
  …
```

The source/tests split is there because 45 of those 57 hits are specs.
That a method is well covered is real information; it is not what the
question was about, so the tests group states its size and shows a
handful.

Grouping matters more than capping, and one measured case shows why. Ruby
namespaces are reopened per file, so asking for a class's ancestors can
return 14 rows **all named `Pikuri::Tool`** — one per file that reopens
the namespace — with the real declaration ordered *last*. A naive cap
would have cut precisely the row you wanted:

```
supertypes "Read" — 3 levels

  1. Pikuri::Tool  pikuri-core/lib/pikuri/tool.rb:35  (+13 more files declare this name)
  2. Object  outside the workspace: compat.rb:20  (+5 more files declare this name)
  3. Kernel  outside the workspace: kernel.rb:3  (+13 more files declare this name)  (and 3 other ancestors at this level)
```

`hover` is the other shape worth knowing, because on a *constant* it is
the single highest-value call in the set: it returns the class's whole
documentation comment. In a codebase whose yardoc is the declared source
of truth, one `hover` answers "what is this class for?" without reading
the file. It is also where an answer runs long, so it is truncated with an
explicit marker rather than quietly:

```
hover "Confirmer"

Port for resolving a "may I do this?" confirmation to a decision …

... [461 bytes omitted; total was 3453 bytes; the rest is documentation the server holds] ...
```

Notice what those transcripts *do not* contain. `hover` on a `def` line
returns nothing at all on ruby-lsp, and `goToDefinition` on a dynamically
dispatched Ruby method routinely returns several candidates — including
copies inside an installed gem. Both are relayed as they came. pikuri does
not smooth them over, and the reason is a design rule with teeth: **every
server is broken in its own way, and the ways do not generalize.** There
are language servers for thirty-odd languages, each with its own list; a
harness that special-cases two of them gets those two right and says
nothing about the third. So the tool reports what the server said, and a
capable model handles "that looks stale, let me ask another way" the way
it handles a failing test.

The one thing that is never relayed is a *lie* — which is where this
chapter started.

## The path in a row is a path nobody asked for

Every path in those transcripts is a **walked path**: the model did not
supply it, so no path-resolution gate stood in front of it. That is the
same category as a `grep` hit or a directory listing row, and pikuri holds
every tool that walks to paths on its own to the same rule (one of the five
seams `rake tripwires` re-checks): every row is checked against the workspace's
credential denylist before it is rendered, and a path is *printed* only
where the workspace could actually open it. Elsewhere the row keeps a bare
basename, which is why `Object` above reads `outside the workspace:
compat.rb:20`: provenance the model can see and cannot turn into a read.

That obligation follows the paths into *prose*, which is the part worth
watching for in your own tooling. `hover` is the one operation that answers
markdown rather than rows, and ruby-lsp fills its answer with editor-shaped
links — `[version.rb](file:///home/you/proj/lib/version.rb#L9,3-9,20)`, a
VS Code convention down to the column numbers. Those are walked paths too,
arriving in a shape the row path never sees, so every `file:` URI in the
blob is rewritten to the same `lib/version.rb:9` citation a row carries —
keeping its link only where the workspace would open the file, and
collapsing to a refusal where it would not. It is the same check; what
changed is that the answer stopped being a list and started being a
paragraph, and a check written against rows would have quietly stopped
applying.

The sharper point is about *trust*, and it will change a verdict on your
own wiring. A language server's index does not stop at your project. It
reaches the whole bundle, the JDK, four hundred transitive jars — one
measured `workspace/symbol` for `StringUtils` returned five hits, every
one inside a binary jar, and the decisive case was `ArrayUtils`, which
appears nowhere in the project's source and is never imported: two hits
anyway. And the marquee feature of `hover` is quoting third-party prose
into your context *in bulk*: 22,639 bytes of attached source arrived from
a sources jar in one measured call.

So the `lsp` tool declares its untrusted-content leg **unconditionally**,
where the `read` tool declares it conditionally on whether the host vouched
for this checkout (`pikuri-code` never does, since its file tools also read
your dependency caches). A human who answered "yes, I trust this repo" made a claim
about the code they checked out, not about four hundred jars Maven
resolved or a `-sources.jar` nobody has ever diffed. The consequence is
deliberate and worth knowing before it surprises you: on a *trusted* repo,
adding a language server to a wiring that also has web access can light a
trifecta leg that was dark before. [Measuring the
trifecta](https://codeberg.org/mvysny/pikuri/src/branch/master/book/trifecta-detector.md) explains what that reads like at boot;
`pikuri-lsp/design/architecture.md` argues the declaration line by line.

For the same reason, one thing is fixed and not configurable: the
workspace root is the server's working directory *and* the `rootUri` it
indexes. There is no `root:` field in a server entry, so the server's idea
of your project cannot drift away from the boundary that confines the
agent.

## The server itself is in no cage

Everything above gates what comes *back* from the server. The server
process is another matter, and it is the answer to the book's standing
question, what can this reach and where does it stop: **a language server
runs as you, on your host, outside every sandbox in this book.** The `bash`
tool runs inside Bubblewrap; the language server sees your whole home
directory, `~/.ssh` included, and the network.

And it runs your project's code to do its job. ruby-lsp builds a private
bundle in `.ruby-lsp/`, whose `Gemfile` begins with
`eval_gemfile(File.expand_path("../Gemfile", __dir__))`: your project's
`Gemfile`, which is Ruby, evaluated by a process with your full rights,
before the model has asked anything. jdtls importing a Gradle project runs
`build.gradle` and its plugins the same way. For your own repository that
is what your editor already does every day. For a repository you just
cloned from a stranger, the first `lsp` call is the moment its build
script runs on your machine, unsandboxed.

Caging the server the way `bash` is caged doesn't work: a server without
the network cannot import a Gradle project that resolves dependencies, and
one without your home cannot find the toolchain it indexes. A cage that
breaks the tool on both reference servers is a removal, not a defense. So
the containment is the same trust decision an MCP entry carries: you chose
the binary, and the results are gated on the way back in.

**Where it stops.** Don't configure a language server for a repository you
don't trust. When you need one anyway, the wall is the same as everywhere
else in this book: a virtual machine around the whole process.

## Wiring it

A server entry is two facts — the binary and the files it claims:

```yaml
# ~/.pikuri-examples-config.yaml
lsp_servers:
  ruby:
    command: [ruby-lsp]
    files:   ['*.rb', '*.rake', '*.gemspec', Rakefile, Gemfile]
```

`files` holds *basename* globs, not extensions, because `Rakefile` has
none — and it is the dispatch key, so a file type nothing claims is
refused rather than guessed at (`Error: no language server is configured
for .md files`).

A Java entry exercises every remaining field, and each of the three extras
is one of this chapter's traps made concrete:

```yaml
  java:
    command:      [jdtls, -data, /home/you/.cache/pikuri/jdtls]
    files:        ['*.java']
    env:          { JAVA_HOME: /usr/lib/jvm/java-21 }
    init_options:
      extendedClientCapabilities: { classFileContentsSupport: true }
```

The `-data` directory is what makes the difference between 78 seconds and
7.7; `env` is the per-child credential-and-config channel; and
`init_options` is the flag without which every library symbol answers with
silence.

Onto an agent, it is one extension:

```ruby
registry = Pikuri::Lsp::Registry.from_h(config['lsp_servers'])

Pikuri::Agent.new(transport: transport, system_prompt: prompt) do |c|
  c.add_extension Pikuri::Lsp::Extension.new(registry: registry, filesystem: filesystem)
end
```

An empty registry makes the whole extension a no-op — no tool, no child,
no teardown — so shipping the gem costs a host that never configures a
server exactly nothing. Servers start on **first use**, not at boot, so a
registered-but-missing binary is reported by the call that needed it, and
a pure-Ruby project never launches the `java` entry its owner added once.
The child is spawned de-bundlerized (`pikuri:D_de_bundlerized_children`), so a
Ruby language server resolves gems from *your* project rather than from
pikuri's own bundle.

One thing the gem will not do, ever: write. No rename, no formatting, no
code actions, no workspace edits. That is what keeps its threat model
closeable — the moment it applies an edit it needs the confirmer seam, the
read-before-edit gate, and a much longer document. **The gem is named
after what it refuses to become.**

## The diagnostic, and why the specs cannot replace it

Every measurement in this chapter is a claim about software that ships new
versions. `subtypes` might get implemented. jdtls might index methods. A
server might start advertising a provider it used to omit. Each of those
would quietly invalidate a design decision.

The specs cannot notice. They run the client against a fake server and a
dummy binary, both of which behave the way pikuri expects *by
construction* — and CI's image has no language server installed at all. A
live spec tagged to skip when the binary is absent would be worse than
nothing: it reports green by staying silent.

So the probes live in a dev script instead, with **three** outcomes per
probe rather than two:

```
$ ruby pikuri-lsp/bin/pikuri-lsp-check

Probes
------
  ok       the encoding offer is honoured (F_position_encoding)
             the server took the utf-8 offer, so offsets need no conversion
             guards: PositionEncoding exists at all: pikuri converts when it is not
  ok       open / ask / close, twice over, gives the same answer (S_reopen_works)
             two open/close rounds, the same answer (5 location(s))
             guards: the document-sync policy: re-open on read, never didChange, and close what was opened
  ok       a bare name may score below the index threshold (H_qualified_name_match)
             the index returned 22 hit(s) and none is "Bash"
             guards: why symbol-only lookup is best-effort and file+line is what the tool teaches
  ok       the operations the enum names are advertised here
             not advertised here: goToImplementation, goToTypeDefinition,
             incomingCalls, outgoingCalls — the gate refuses these cleanly
             guards: the capability gate at dispatch, per workspace
  ok       an advertised provider actually answers (H_subtypes_stub: the # TODO trap)
             supertypes: 13 row(s); subtypes: 0 row(s)
             guards: relay-do-not-work-around: no per-server known-stub list

5 probes: 5 ok, 0 drifted, 0 unanswered.
```

That is the workshop's checkout, anchored on `class Bash`. The same check
once printed `5 probes: 5 ok` here with every answer empty: zero
locations twice ("the same answer"), zero hits ("none is `Bash`"), and a
hierarchy that answered nothing ("an empty answer is not a stub"). Each
probe compared nothing with nothing and called it a pass. That was the
readiness race from earlier in the chapter, and the diagnostic built to
catch silent failures had rounded one to a clean bill of health. A probe
that got nothing to measure now says `no answer` and why, the same rule
the `lsp` tool applies to the model.

`ok` means the finding still holds. `DRIFT` means the server changed its
mind and a decision wants re-reading — an invitation, not a failure, which
is why each probe names the decision it guards. `no answer` means the
probe could not run here and says why, because "absence of evidence" is
not something a diagnostic should round to a clean bill of health. Every
finding id in that output (`F_`, `J_`, `H_`, `S_`) is a paragraph in
`pikuri-lsp/design/architecture.md`, cited from the specs and the fixtures too, so a
drift leads somewhere.

If that shape feels familiar, it is the same one as the wire check in
[the messages array is not the prompt](wire.md), for the same reason: both
guard a **silent** failure in a layer you do not own, and neither can be
covered by an assertion on your own side of the boundary.

### The other layer, and how it announced itself

Every probe above talks to the *protocol client*. That turned out to be
half the surface. Driving the `lsp` tool end to end — the same questions,
but through `Navigator`, `Anchor`, `Sources` and `Renderer`, reading what
the *model* would read — immediately turned up something no protocol probe
could see: `findReferences` printing two byte-identical rows, because a
line holding both a declaration and a call yields two locations that differ
only in the column pikuri never prints. Both rows counted in the header,
and both spent a slot of the cap, which bites hardest exactly when the
answer is long.

The lesson generalizes past this bug. A probe is blind to everything
*above* the layer it drives, and a rendering fault is invisible from
underneath: the protocol traffic was perfectly correct. So the diagnostic
grew a second mode, `--drive`, which asks every operation through the tool
and then checks what a rendered answer owes rather than what the server
said — no repeated rows, every printed path one this workspace can open.
Point it at a method declaration and it also re-measures the quietest
finding here: on ruby-lsp, `hover` answers at a call site, answers on a
class declaration, and answers *nothing* on the `def` line of the method
it names — which is the first place an agent asked to document a method
will look.

## The takeaway, portable to any harness

- **An empty success is the worst answer a tool can give a model.** Keep
  "unsupported", "nothing", and "could not ask" as three distinct
  sentences, and never merge them into a helpful paragraph of maybes.
- **Ask a foreign process what it can do, per workspace, per session.** A
  capability matrix keyed on the binary will be wrong, and an advertised
  capability can still be a `# TODO`.
- **Never ask a model for a coordinate it has never seen.** If your tool
  can compute it exactly from something the model *did* see, compute it —
  an invented column is not an error, it is 80,609 wrong answers.
- **Relay foreign misbehaviour; work around only what you can state as
  one rule.** Two servers' quirk lists do not generalize to the third.
- **Where your process model differs from the protocol's, the spec is not
  the authority — the measurement is.** Then keep the measurement runnable
  so a version bump cannot quietly falsify it.
- **Every path a tool walks to on its own needs the same gate a path the
  model supplied would get** — and an index that reaches your dependency
  tree is not vouched for by anyone.

## What's next

[Task tracking](tasks.md) covers `pikuri-tasks`, the in-memory task list
that lets the model externalize a multi-step plan into a structured slot it
sees on every turn: a short chapter, and the last piece bolted onto
`pikuri-code` before [the completed coding agent](code.md) accounts for
all of them.

The vocabulary you have now is enough to read
[`pikuri-lsp`](../pikuri-lsp/README.md)'s sources directly — start at
`Connection` for the protocol, `Navigator` for what one call does end to
end, and `pikuri-lsp/design/architecture.md` for the threat model and the measurements
every line of it rests on.
