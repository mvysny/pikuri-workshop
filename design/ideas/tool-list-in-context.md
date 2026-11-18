# Does the whole tool list need to be resident? — gating tool schemas

Status: **open question, deliberately parked.** Split out of what is now
the `paths:` build note (now shipped, `D_skill_path_activation`), where it was a
thread: the author's framing (2026-08-16) is that a user accumulates
*tools* the way they accumulate skills — thunderbird, vectordb, memory, a
pile of MCP servers — and only a slice of them applies to any one
project. Gate the **tool list** on `paths:` the same way and only
advertise what this project needs.

It lives in its own file because it is a different noun with a different
answer: the mechanism is shared with skills, but the constraints, the
rivals and the destination `design/decisions.md` entry are not.

**Scope.** This note owns tool-schema residency: what the tool surface
costs, why pikuri's shipped answers already cover the cases that exist
today, and what would have to be true for gating to earn its way in. It
does **not** own anything about skills (→ the three `skill-*.md` notes),
though it shares their caching arithmetic.

Related:

- pikuri-workshop's `D_skill_path_activation` — the matcher and the
  `Event::ToolCall` plumbing this would reuse, including the path-args map
  that is the first design problem either way. Its **Context** also carries
  the caching arithmetic, and you should read that before quoting any token
  count here: caching refunds prefill but never window capacity or
  attention, and separately the expensive *operation* is prefix
  **mutation** — which bites harder for tool schemas than for skills,
  since schemas sit at the very front of the prefix, so gating one
  invalidates everything.
- **The origin complaint**, from the 2026-08 in-harness review (Grok 4.6;
  it lived in `design/ideas/feedback.txt`, deleted 2026-08-25 once its last item
  closed): *"the standing prompt is heavy — safety block + harness +
  AGENTS.md + skills catalog + tool schemas on every turn."* Only the
  tool-schema clause reaches this note, and it is the whole reason the
  note exists. The skills-catalog clause was answered by
  `D_skill_path_activation`. The other two halves the review named — a
  tool-schema restatement in prose, and duplicated
  don't-mention-the-guidelines material — were prompt-editing rather than
  gating, and on inspection (2026-08-25) describe nothing pikuri ships:
  `pikuri-code/prompts/coding-system-prompt.txt` and
  `pikuri-core/prompts/agent-loop.txt` name no wired tool (the standing
  convention, which has its own grep tripwire) and carry no
  guidelines-secrecy material. Closed by observation, not by work — most
  likely the reviewer was reading its own vendor preamble. Nothing of
  that item is open anywhere but here.


## The prize is genuinely bigger than the skills one

Measured on this repo, 2026-08-16. Proxy for the tool side: every
heredoc body plus every single-line `description:` string in the 30 files
under `pikuri-*/lib/` that define a `Pikuri::Tool` — which is what a
JSON schema is mostly made of, modulo ~20–30 % scaffolding.

| | bytes | ≈ tokens |
|---|---|---|
| all 30 pikuri tools' schema prose | 22 KB | ~5.5 k |
| the 12-skill `~/.claude/skills` catalog render | 5.9 KB | ~1.5 k |

Per item: ~730 B/tool vs ~380 B/skill-description. So **the whole tool
surface is roughly 4× the whole skill catalog** — and it is paid on the
same terms the catalog is: resident, every turn, scaling with what's
*installed* rather than what's *used*. (Deliberately no
window-percentage here — a percentage only looks alarming on a small
window, and the asymmetry is the argument at any window size.)


## …but pikuri already answers it twice, and both beat a matcher

1. **Per-binary wiring.** No shipped binary wires all 30 tools.
   `bin/pikuri-thunderbird` doesn't pay for `vectordb_*`. "Which tools
   does this project need?" is answered at *construction*, by a human, in
   Ruby — which is precisely pikuri's counter-move to the wall of JSON.
2. **Sub-agent personas.** A persona owns its toolset verbatim and costs
   the parent exactly one `agent` schema. That's *better* than gating,
   because the sub-agent's whole context is separate — the parent never
   pays the observations either. The "vectordb tools don't belong in a
   coding agent's list" case is this pattern's to answer, though no
   bundled persona does it: pikuri-vectordb ships corpus tools and no
   persona, and the host that wants one wires it
   (`D_corpus_trust_declaration`).

Which bounds the scope honestly: **this is a feature for a future
general-purpose host** (a `pikuri-tui` that wires everything because it
can't know what you'll ask), not for anything in `bin/` today. AGENTS.md's
warning applies — don't propose a library feature whose value rests on a
demo's shortcut; here it's the opposite, the demos are *fine* and the
hypothetical host is the one with the problem.


## Three things make tools harder to gate than skills

- **Withholding a tool withholds a capability, not a document.** A skill
  the model never sees → it does the work with worse instructions. A tool
  it never sees → it *can't do the work at all* and has no way to ask.
  That asymmetry is why `mcp_connect` advertises `<available_mcps>`
  rather than hiding servers outright. (Note the skills notes reach the
  same conclusion from the other side: withhold the description, never
  the name.)
- **The bootstrap hole.** A path matcher fires only *after* some tool
  touched a matching path, so the trigger tools (`read`, `glob`,
  `file_list`) must always be wired. Fine for families downstream of file
  work; useless for intent-driven ones — nothing the model *reads* tells
  you it is about to want `thunderbird_mail_search`. Half a real toolbox
  is unreachable by this predicate.
- **Cache invalidation, and it's the whole prefix.** Tool schemas sit at
  the very front of the request; adding one mid-conversation invalidates
  the *entire* cached prefix. Paid **per activation**, where
  `mcp_connect` pays it once per session by design. Note this is the same
  wall the skills case hits with the system prompt, and there the escape
  is "announce via an interloper injection, which *appends*". Tools have
  no such escape: a tool must actually be in the list to be callable.

Removal is worse than addition — history containing a call to a tool no
longer declared is a shape some providers reject. **Gating is add-only.**


## Rivals, in the order to exhaust them

1. **Per-binary wiring + sub-agent personas** — shipped, free,
   human-authored, and it's what pikuri is *for*.
2. **Model-driven activation** — `mcp_connect`'s shape, generalized:
   advertise a *family* in one line, let the model materialize the
   schemas with a connect call. Paid once, model-controlled, no bootstrap
   hole, and `Configurator#add_raw_tool` already exists. This is what
   Claude Code does at scale today: the session this note was written in
   has ~100 MCP tools deferred to names-only, with a `ToolSearch` tool
   that fetches schemas on demand.
3. **Path-gated tools** — last, only for a general-purpose host, and only
   for path-shaped families.


## Open questions

1. **Does this survive contact with per-binary wiring?** My read is no,
   not until a general-purpose host exists — but the shared machinery
   (the `paths:` matcher, the path-args map) is the same either way, so
   building it for skills costs nothing extra and keeps the option.
   **Don't build the tool half speculatively.**
2. **Is `mcp_connect`-shaped activation the better generalization for
   *both* nouns?** Possibly the answer splits by axis: harness-driven
   `paths:` for skills (cheap, additive, appends), model-driven connect
   for tools (expensive, prefix-busting, deserves an explicit decision).
   Shared with `D_skill_path_activation`'s reopen criterion 2.
3. **Is per-tool the right granularity, or per-family?** Every rival
   above advertises a *family* (`<available_mcps>` lists servers, not
   tools). A gate that operates per tool multiplies activations — and
   each one is a full prefix invalidation.


## Graduation plan (when this settles)

- **Its own `design/decisions.md` entry**, on the tool-surface axis — explicitly
  *not* the shared what-the-catalog-advertises entry the three skill
  notes route to. The fork is real and someone will re-propose it the
  first time a general-purpose host exists.
- The durable nugget whichever way it goes: **per-binary wiring and
  sub-agent personas are pikuri's answer to tool-list bloat**, plus the
  add-only / prefix-invalidation constraint that makes mid-conversation
  tool gating expensive. Point {Pikuri::SubAgent::Persona}'s yardoc at
  it, since "a persona costs the parent one schema" is the load-bearing
  half and is currently only implied.
- The measurement (30 tools ≈ 22 KB of schema prose, ~4× the skill
  catalog) is worth keeping wherever the entry lands — it is the reason
  anyone raises this, and re-deriving it is a half-hour.
