# Private-context taint + egress levels

Status: **designed, not built.** The model is settled (this file).
One part deliberately left open: *where the mechanism lives* (Q3 —
core listener/control vs coupling egress tools to the taint state).
Staging area — drain into source + `book/` as it lands.

**Moved here from pikuri on 2026-11-21**, whole. The levels bite only
where a context holds a private source *and* `fetch` — `bin/pikuri-code`
and the OS assistant, not pikuri's secretary, which never fetches. Where
building it needs something from pikuri (Q3 below), that session asks
pikuri for it.

Sibling: the trifecta detector, **shipped** ({Pikuri::Trifecta},
pikuri's `book/trifecta-detector.md`). That is the **static, design-time** check
("this wiring *could* hold all three legs" → report at boot). This note is
the **dynamic, runtime** enforcement ("all three are live in this context
*right now* → sever the egress leg"). Same tag model (`:private` /
`:untrusted` / `:egress`); the detector *audits*, the taint *enforces*. Both
evaluate per-node (each agent context tracks its own taint).

No integrity counterpart: keeping untrusted bytes out of a parent with
opaque handles was rejected (`pikuri:D_no_quarantined_handles`), so this note's
enforcement covers the **confidentiality** leg only (private in → sever
egress).

Also related:
pikuri's [`security-open-questions.md`](https://github.com/mvysny/pikuri/blob/master/design/ideas/security-open-questions.md)
§"Egress is broader than `web_search`";
[`security-open-questions.md`](security-open-questions.md)
§"An egress allowlist below the tool layer" (what survives of the
allowlist once this note kills the `fetch` one); and
[`typed-transports.md`](typed-transports.md)
(the provider-privacy cousin — see "Reroute is not a trifecta break"
below).

## The core idea: coarse, monotonic context taint

When a `:private`-tagged tool produces output into a context, the
**whole context is marked private from that moment on** — and stays
that way (monotonic; you can't un-see a secret). The UI marks it. From
that point, egress is constrained by the configured privacy level.

**No content sniffing, no per-datum tracking.** A private source was
called → the context is private. That's the entire rule. Fine-grained
"which tokens are sensitive" tracking through an LLM context is
unsound — the model blends everything — so coarse-and-honest is the
only defensible option. The cost is monotonicity (see "the human is
the only clean post-taint egress").

Taint trigger = any `:private`-tagged tool returns into the context:
a `Workspace::Filesystem(private: true)` read, a private MCP source
(Gmail/Calendar), **or a sub-agent returning private data** — which
taints the *parent*, consistent with the detector's rule that
`:private` propagates upward at full strength. Enforcement is
per-context: a sub-agent that itself touches private + holds egress
taints and severs *itself*.

### The same flag carries `:untrusted`, for display only

The mechanism is tag-agnostic — watch the stream, flip a monotonic
per-context flag when a tagged tool returns, let the UI mark it — so it
tracks `:untrusted` alongside `:private`. What each one buys differs:

- **`:private` in** → the levels below apply: egress constrained or severed.
- **`:untrusted` in** → **nothing is severed, the UI just says so.** This
  agent has now read attacker-authorable content, so its output is suspect
  and a human reading along should know. That leg is handled by the
  wiring, decided before any bytes arrive: the static map, the sub-agent
  boundary weakening it to `:weakened`, and the confirmers that show the
  human the bytes. A flag flipped after the bytes arrived cannot retrofit
  any of that.

Worth having because it is the one question the static detector cannot
answer. At boot it can only say a wiring *could* read untrusted content, and
a declared "this agent stays clean" was rejected for being both derivable and
silence-able (`pikuri:D_no_static_poisoned_flag`). Observation needs no declaration,
which is exactly why the badge is cheap where the static flag was not.

## The structural insight: who controls the destination

The whole feature rests on one distinction between the two egress
tools — **who picks the recipient**:

- **`web_search`** — the model (and any injection) picks the *query*;
  **pikuri** picks the *destination* (one of a few baked-in engines).
  The attacker **cannot point it at their own server.** Worst case:
  a search engine learns a laundered query ("side effects of
  `<secret-drug>`"). Bad, but *bounded* — a write-only dead-drop the
  attacker can't read back. **Whitelisted by nature.**
- **`fetch`** — the model (and any injection) picks the *entire URL,
  host included* → straight to `exfil.com/?d=<secret>`. The recipient
  *is* the attack. **Exfil by nature.**

That's the game. `web_search`'s destination is pikuri-controlled;
`fetch`'s is attacker-controlled. Everything below follows.

### Why "levels of maliciousness" is the wrong axis

It's tempting to allowlist by *operator* malice (Google good,
sketchy-host bad). It fails: the load-bearing property is **attacker
observability — can the adversary read back what was sent** — not
operator malice. `pastebin.com` has a benign operator and is a perfect
exfil sink (attacker reads the paste). DNS has no operator and leaks
(attacker runs the authoritative nameserver). So "benign operator" is
not safe; "attacker can't read it back" is.

We do **not** try to classify read-back automatically — no rule can.
Instead pikuri hard-codes a tiny list of search engines vetted *by
that principle* (write-only from an attacker's view), and **kills the
fetch whitelist entirely** (next section).

### Killed: the fetch whitelist  → this reason belongs in the docs

A *user-curated* fetch whitelist recreates the pastebin hole with the
user's own hand. The hosts people actually want to fetch are
**interactive**, hence attacker-readable. Canonical doc example:
a user whitelists `github.com` (they read issues) — now the attacker
exfiltrates via a gist, a `raw.githubusercontent.com/<attacker>/…`
URL, or a PR comment. Same for a company wiki (open edit) or anything
with a paste/upload. And the user **cannot** be asked to judge "is
`github.com` attacker-readable?" — that's the unjudgeable-content
problem one level up. So:

> **`fetch` has no whitelist.** It is severed post-taint, or
> unrestricted. Nothing in between. The `github.com` example above is
> the concrete illustration to put in the security guide.

## The three privacy levels

| level | name | on taint, `web_search` | on taint, `fetch` |
|------|---------|------------------------|-------------------|
| 1 | **Sealed**  | severed | severed |
| 2 | **Bounded** | allowed — vetted write-only engines only, routed to the most-private | severed |
| 3 | **Off**     | n/a — no taint tracking | unrestricted |

- **Sealed** — nothing private egresses, ever. Pure local; matches the
  "local llama, no telemetry" identity.
- **Bounded** — a usable assistant: it can still look things up, but
  cannot be driven to a novel host. The residual risk is exactly the
  bounded one ("a search engine may learn a sensitive query").
- **Off** — not a privacy *choice*; it's opting out (the neighbour of
  `--yolo`).

Levels 1↔2 are the real user choice. Levels only bite **post-taint**,
so `bin/pikuri-chat` (no private source, never taints) is unaffected
regardless; this matters for `bin/pikuri-code` and the assistant.

### Reroute is not a trifecta break

"Route to the most-private engine" inside Bounded reduces the
*residual* leak severity (which benign operator profiles you); it does
**not** break the trifecta — the secret still egresses. It's the
dynamic, context-granular cousin of typed-transport-classes
(provider privacy). What *bounds* the trifecta risk in Bounded is
`web_search`'s destination-pinning + write-only property, not the
choice of engine.

## Default + onboarding: start Bounded, then offer Sealed at the cliff

Defaulting to Sealed would teach a new user an agent that's barely
usable. So:

1. **Start at Bounded (2)** while the user walks the documentation
   path — not yet entering or indexing anything sensitive.
2. **At the moment they first handle sensitive data** (point a private
   workspace at real files, index a private corpus, connect Gmail),
   put them before an explicit choice:
   - *stay Bounded* — accept that a search engine may learn sensitive
     content (framing: it already does — check your own search
     history), **or**
   - *flip to Sealed.*
3. After flipping to Sealed, a tool returning **"DISABLED FOR PRIVACY
   — you are in Sealed mode"** is self-explanatory: the user knows they
   threw the switch.

(Open: whether the "first sensitive action" trigger is detectable
cleanly enough to drive the prompt, or whether it's a setup-time
question. Leaning: it fires on first `:private` taint.)

## The human is the only clean post-taint egress

Monotonic taint means automatic egress is gone once private data
enters. The **only** clean way to egress afterward is a payload the
tainted, injection-drivable agent did **not author** — i.e. the human
types the query / URL themselves. The human is not *approving* the
agent's egress (Round-1 lesson: they can't judge laundered content);
they are *authoring* it, so it's clean by construction. The human
typing "book flight LHR→JFK" is the air gap.

This also kills the tempting "spawn a fresh, untainted sub-agent to do
the egress" escape: the tainted parent would write the sub-agent's
task prompt, leaking the secret into it (the transcriber problem — see
pikuri's `book/trifecta-detector.md` §"Propagation", which is why egress
propagates up at full strength). Only a *human-authored* payload breaks
the chain. This is where the "human-gated egress" idea finally lives —
correctly placed, as **author**, not **approver**.

## Open (Q3): where the mechanism lives

Left open deliberately. The lean: taint is a *context-level* fact and
enforcement is best done by watching the event stream, so this is
probably a **pikuri-core listener/control** that flips a taint flag
when a `:private`-tagged tool returns and blocks/limits egress
tool-calls when tainted — keeping `web_search` / `fetch` **stateless**
(no `Confirmer` wired into pikuri-core tools), consistent with the
house rule "grow by adding listeners/controls, don't complicate the
tools." The alternative is coupling the egress tools to the taint
state directly. **Not decided.**

### Constraint on either answer: sever *before* the tool body runs

Whichever way Q3 goes, enforcement has to refuse the call, not clean up
after it. The reason is {Pikuri::Web::UrlCache}: `fetch`, `web_scrape` and
`web_search` each hold their cache in a **class-level constant**, so it is
one on-disk store (`~/.cache/pikuri/url_cache/<tool>/<sha256-of-key>.txt`,
2 h TTL) shared by every agent in the process *and* every pikuri process on
the machine. The write happens inside the tool body, just downstream of the
HTTP call. Sever first and nothing private-derived is ever written; let the
call happen and redact the response instead, and a private-derived query
string has already been hashed onto disk alongside its result. Cheap to
honour now, expensive to discover later.

Given that ordering, the shared cache does **not** undermine the per-node
taint model, which is worth stating because a process-wide store under a
per-context model looks like a hole (checked 2026-08-28):

- **Out:** a tainted agent's egress is severed, so it never populates the
  cache.
- **In:** a hit requires presenting the exact key, so a reader must already
  hold the query or URL it is asking about. The residual is a weak
  existence oracle — a result that looks staler than now — on a string the
  reader already knew.
- **Poisoning:** agent A caching attacker bytes from URL U just means B
  gets A's copy of what U was going to serve B anyway; the TTL, if
  anything, *reduces* the attacker's ability to vary payload per victim.

## Open: docs rollout (the *what*, not yet the *how*)

- The killed-fetch-whitelist reason — the `github.com` /
  `raw.githubusercontent` / gist / paste example — as the concrete
  illustration of "attacker-readable ≠ malicious operator." Likely in
  pikuri's `book/security.md` / this repo's `book/security-revisited.md`.
- The Bounded→Sealed choice moment, including the "Google already
  knows — check your history" framing.
- Named, teachable concepts: *taint*, *Sealed / Bounded / Off*,
  *destination-controlled vs attacker-controlled egress*,
  *human-as-author not approver*.
- `web_search` vs `fetch` as the teaching contrast for the whole idea.

## v1 scope, in one place

- Coarse monotonic context taint, triggered by any `:private`-tagged
  tool returning into the context (no content sniffing). UI marks it.
- The same flag tracks `:untrusted` arrival, **display only** — no
  severing, no levels.
- `:private` propagates up from sub-agents (taints the parent);
  enforcement is per-context.
- `web_search`: destination pinned to a few pikuri-vetted write-only
  engines. `fetch`: **no whitelist** — severed post-taint or
  unrestricted.
- Three levels: **Sealed** (sever all) / **Bounded** (search-only,
  fetch severed) / **Off** (no tracking). Default **Bounded**, with an
  explicit offer to flip to **Sealed** at first sensitive action.
- Post-taint egress only via a **human-authored** payload.
- Q3 (mechanism location) and docs rollout left open.
