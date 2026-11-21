# More confirmers: what's still open

**Moved here from pikuri on 2026-11-21**, whole. The ingest gate's first consumer is the OS
assistant here, and the fatigue work is the same question as [`bash-confirmer.md`](bash-confirmer.md)'s.
`Confirmer` itself is pikuri's (`pikuri-workspace`), so a session that needs a new field on its
`Request` asks pikuri for it.

The confirmer seat itself shipped ({Pikuri::Workspace::Confirmer}, the Confirmer seam in
pikuri's `pikuri-workspace/AGENTS.md`): editable gates on the `agent` task and on the secretary's
`web_search` query, plus `Redirected` for steering. A model-picked `fetch` URL gets no confirmer,
and why is in {Pikuri::Web::FETCH}'s yardoc. Two questions remain.

Related: [`private-context-taint.md`](private-context-taint.md) (the human as *author*, not
*approver*), `pikuri:D_no_quarantined_handles` (the human as the one clean *reader*, which
`Q_ingest_gate` turns into a gate), [`templated-subagent-replies.md`](templated-subagent-replies.md)
(the same return leg, gated by a type instead of a human),
[`bash-confirmer.md`](bash-confirmer.md) (fatigue: risk tiers, dry-run, session grants).

## `Q_structured_request` — ask less, and headline the consequence

pikuri's `book/security.md` §"The human gate, and why fatigue is the enemy" links here as its plan. The
secretary asks on every note write and every search; the goal is to ask only on the consequential,
and when it asks, headline the consequence rather than echo every byte.

`Request` today is `question` + verbatim `detail` + `editable` + `change` (a diff), so the chrome
echoes a string the caller built. It wants **structured action context**: kind (write / search /
compose / bash), target (path, query, URL), egress destination, inside or outside the workspace.
Then the seam renders the presentation, and a sticky rule ("don't ask again for new notes") keys on
fields instead of raw strings.

- What do secretary transcripts show the human actually rubber-stamps? `pikuri:D_secretary_wiring` already
  defers "confirm only edits to notes the agent didn't write" to practice.
- Which fields does a rule key on, and does a rule outlive the session?

## `Q_ingest_gate` — a human checks a sub-agent's reply before the parent reads it

The other axis: not where bytes go, but what comes *in*. A researcher with web tools and no
filesystem returns a summary; before it joins the parent's context, the human confirms it. The
interposition point is {Pikuri::SubAgent::SubAgentTool}'s return, which today deliberately passes
the reply through unconfirmed.

Why it's attractive: it stacks on the existing attenuation (the reply already crosses as
`:untrusted_weakened`), it hands the human one short summary rather than a URL or scraped HTML, and
a fully captured child can only try to re-inject through that summary. Honestly: a subtle injection
in plausible research text still gets past a human, so it raises the bar and closes no leg.

No binary here needs it yet: the secretary searches from the parent and has no sub-agents. It
would earn a build when a parent holding private data delegates to `RESEARCHER` (the OS assistant
here is that shape).

- Does a gate on *inbound* content fit `Request`/`#ask`, or want its own shape? `Approved` would
  carry an edited summary; `Redirected` would steer whom?
- On decline, is the summary dropped entirely? (Dropped is cleaner: "declined but summarized"
  re-leaks.)
- Per reply, or sticky for a turn? Sticky slides toward approver fatigue.
