# Agent Skills (stub)

> **Stub chapter.** This is a holding place. The guide doesn't yet
> have a workflow concrete enough to motivate Agent Skills the way
> they deserve — coming back to flesh this out once the assistant
> walkthrough and a few more advanced coding-agent recipes land in
> the guide. What is here already: what they are, a minimal `lol`
> demo, the three ways a bundle gets invoked, why a skill needs a
> trigger at all, and how to write a description that fires. What
> is missing is the reader's own itch.

## What they are, in one paragraph

[Agent Skills](https://agentskills.io/specification) is a small
standard for packaging "when you see *X*, do *Y*" instructions as
a folder. Each skill is a directory with a `SKILL.md`
(YAML frontmatter — `name`, `description` — followed by a free-form
Markdown body) plus any sidecar files the skill needs. `pikuri-code`
discovers skills at startup
under `.pikuri/skills`, `.claude/skills`, or `.agents/skills`
beneath the project root and the user's home directory.
A skill's description gets advertised to the LLM in an
`<available_skills>` system-prompt block; the `skill` tool loads
the body into the conversation on demand. The same folder works
across `pikuri`, Claude Code, and `pi` — all three implement the
same standard.

## A minimal `lol` skill

The smallest skill that works. Drop this at `~/.claude/skills/lol/SKILL.md`:

```markdown
---
name: lol
description: Reply with "lol" to anything.
---

When the user asks anything, just reply "lol". Nothing else.
```

Restart `pikuri-code`. The boot banner
now reports the skill is loaded. Asking anything should trigger
the model to call `skill(name: "lol")`, load the body into
context, and answer accordingly.

That's the whole mechanism. The `<available_skills>` snippet
tells the model the skill exists; the `skill` tool loads the body
when the model decides the skill applies; the body is just text
that joins the conversation.

## Two ways a bundle gets invoked

A skill is *model-invoked*. Its description sits in the system
prompt on every turn, forever, so the model can decide the skill
applies and call `skill(name: …)`. That resident cost is what
buys the autonomy.

Some bundles never wanted it. A "generate this week's work log"
prompt is one you fire deliberately, by name — the model has no
business judging when it applies, and paying tokens every turn to
tell it *not* to is the worst of both. Those are **slash
commands**: one `.md` file under `.pikuri/commands` or
`.claude/commands`, invoked by typing `/name`, advertised to
nobody.

```markdown
---
description: Generate a weekly work log from git history.
argument-hint: <project-label>
---

Weekly log for `$ARGUMENTS`, Monday through today, from my commits.
```

Saved as `~/.claude/commands/wh.md`, that is `/wh swingai` in
`pikuri-code`. What it expands to becomes *your* message —
the command is a typing shortcut, not a second kind of
instruction, which is why it lands as a user turn and not as
the `:system` reference text a loaded skill becomes.

The distinction to carry away: **who decides**. If the model
should notice the situation and reach for it, it is a skill and
it costs prompt tokens. If you know when you want it, it is a
command and it costs nothing until you type it. A skill whose
description says "only invoked manually" is a bundle filed on
the wrong surface.

## A third answer: the model decides, once the project proves relevant

"Model-invoked, so it costs prompt tokens forever" has a middle
setting. Ten skills at a couple of hundred words each is five
kilobytes on every turn, and in any one session nine of them are
about a language you are not writing today. A skill can name the
files it is about:

```yaml
paths:
  - "**/*.rb"
  - "**/*.gemspec"
```

Now it is not in the prompt at all — not its description, not its
name, not a placeholder saying something was left out. The first
time the agent reads or edits a `.rb` file, its description
appears in the conversation and the model can load it. Nothing
happens in your Java project. `/clear` puts it back to sleep.

Patterns follow `.gitignore` rules, which is a good thing to know
before writing one: `build.gradle` with no slash matches at any
depth, `src/main` with a slash is pinned to the project root, and
a bare `ideas` covers everything under it. One trap: `paths: []`
does **not** mean "never advertise" — an empty list, `["**"]`, and
a `paths:` with nothing under it all mean *always*, because that
is how the other harnesses reading this key behave.

This is a relevance filter, not a permission: the agent can reach
a hidden skill any time it reads a matching file, and *it* chooses
which files to read. What it buys is a smaller prompt and fewer
irrelevant instructions competing for attention — not containment.

An inventory that grows mid-conversation may sound unsettling, but
it is not new: `mcp_connect` already adds tools to a running agent
the same way. What arrives here is smaller — a description, never a
body. Loading still takes the deliberate `skill` call.

pikuri will not run shell commands out of a command file, the
way Claude Code's `` !`cmd` `` does — a `.md` that arrives with
a cloned repo would otherwise be arbitrary code execution behind
a keystroke. Such a file is refused outright, and so is one
declaring `allowed-tools:`. See the
[trifecta chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/trifecta-detector.md) for how a command's
bytes are graded once they are in the conversation.

## Why a skill needs a trigger and an MCP server doesn't

Connect an MCP server for your calendar and the model uses it the
first day, unprompted, off a one-line description. Write a skill
saying "compose components, don't subclass to share code" and it
will read your codebase, copy whatever is next to it, and hand
you an `AbstractPersonView` — with the skill's description
sitting in the prompt the entire time.

That is not a writing-quality problem, and tuning the wording
does not fix it. The two advertise different things.

An MCP server advertises a **capability**. The model wants to
know what is on your calendar, has no way to find out, and a tool
appears that does exactly that. It can *feel the gap*, so the
description only has to name the thing that fills it.

A skill usually advertises a **correction**. The model already
has an answer it is satisfied with, and the skill's job is to say
that answer is wrong. It cannot feel the absence of a rule it
does not know it broke — nothing in "write a Ruby class" tells it
that a relevance check is due. So the description has to win a
race it is never told it is running.

Corrections are also mostly **subtractive**: delete the
tautology, never write that, cut the rationale section. That is
the hardest shape to transmit, because the loudest competing
signal is the code already in the context window — and an example
can only demonstrate what is *there*. You can copy a neighbouring
file's tag style. You cannot learn "cut your rationale section"
from a file whose author already cut theirs. **Imitation
transmits presence and never absence.**

Which is why a subtractive rule loses to the nearest exemplar
unless something puts it in front of the model at the moment it
is about to break it. That moment is what a trigger is for, and
it is why `paths:` exists on skills and has no counterpart on an
MCP server.

And what firing late costs is not the round-trip. It is the work
already done under the wrong model: an agent that reads a dozen
files, sketches an `AbstractPersonView`, and *then* meets the rule
has to throw the sketch away — and that discarded reasoning is far
more context than the skill body would ever have cost. Which is
why the fixes worth reaching for are the free ones, a description
that leads with the moment and a trigger that arrives before the
recon starts. Pre-loading bodies to save the round-trip spends
resident tokens in every session to buy back one turn in a few.

## Writing a description that fires

The description is not documentation. It is the only thing the
model sees until the body loads, so it is a routing decision —
"is this my situation?" — and everything that does not help
answer that is costing you tokens on every turn.

Four rules, roughly in order of payoff.

**Lead with the trigger, not a summary.** The model reads the
description while deciding, so the deciding half goes first:

```yaml
# Loses: describes the content, and the trigger never arrives.
description: Guidance on high-quality Ruby doc comments, covering
  the philosophy of what belongs at each level.

# Fires: names the moment, then the content.
description: Writing or reviewing Ruby rdoc / YARD comments — which
  level each fact belongs at, and what to delete. Read BEFORE typing
  the comment, whenever you are about to edit a `#` comment, a
  `@param` tag, or a class header in a `.rb` file.
```

**Cut the narrative.** No history of why you wrote the skill, no
pitch for how useful it is. If a sentence would not change the
model's yes-or-no, delete it.

**Know which budget you are spending.** An ungated description is
resident on every turn of every session, forever, so it has to be
tight. A `paths:`-gated one is paid only when its glob fires, so
it can afford to be trigger-heavy — spell out the edge cases,
including when *not* to load. The same words are cheap in one
place and expensive in the other.

**State a ban literally, not categorically.** "Never write `Not
thread-safe`" beats "skip the negative", and "never open with
'This class …'" beats "avoid boilerplate openings". A categorical
ban asks the model to first classify its own output as an
instance of the category and only then obey — two steps where a
literal string is one, and the classification step is the one
that fails. Reach for the category only when you cannot enumerate
the strings.

## Why this chapter is a stub

The honest reason: a skill is a refactor of *repetition*. The
chapter that motivates skills well is the one where the reader
has used `pikuri-code` enough to feel "I
keep retyping the same setup at the start of every session" —
and the guide isn't there yet. A `lol` demo proves the wiring
works, but it doesn't show why anyone would write a real skill.

What a fuller chapter will cover, once the guide has the
workflows to anchor it:

- The anatomy of a `SKILL.md` *body* — the description is covered
  above, but not what sidecars (scripts, templates, reference
  docs) are for, or how body length trades off against context
  window pressure once the skill is loaded.
- The Agent Skills standard itself — how `pikuri`'s
  implementation lines up with Claude Code's and `pi`'s, what's
  portable, what isn't.
- One or two skills the guide author actually uses, with the
  pain that motivated each.
- Discovery order, naming collisions, scoping skills to a
  specific project vs the user's home directory.
- When a skill is the right tool versus when a fresh persona
  ([the sub-agents chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/subagents.md)) or an MCP server
  ([the MCP chapter](mcp.md) / [the MCP-revisited chapter](mcp-revisited.md))
  would fit better.

Until then: <https://agentskills.io/specification> is the
authoritative reference, and the `pikuri-skills`
[README](../pikuri-skills/README.md) covers the API surface.

## What's next

[The messages array is not the prompt](wire.md) is the
debugging chapter, and it opens on a skills bug: a path-triggered
promotion that fired correctly, appended correctly, and reached
the HTTP payload correctly, while the model went on insisting it
could only see five skills. It could. The chapter is about the
step between your messages array and what the model actually
reads — the one place none of your own assertions can reach.
