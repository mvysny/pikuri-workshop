# Agent Skills

The MCP chapters handed the agent new *capabilities*: a catalogue, GitHub, a browser. This one
hands it something stranger: *instructions*, packaged as a folder the model loads when it
decides it needs them. That decision is the whole difficulty, and most of the chapter is about
why the model so often decides wrong.

The worked example is a real skill, `cop`: ten kilobytes of rules for component-oriented
programming that the book's author keeps in `~/.claude/skills/cop/`. Its pain is easy to state.
Ask an agent for one more view in a layered codebase and it reads the code, copies whatever is
next to it, and hands you an `AbstractPersonView`, while a skill saying "compose components,
don't subclass to share code" sits in its prompt the entire time.

## What a skill is

[Agent Skills](https://agentskills.io/specification) is a small standard for packaging "when
you see *X*, do *Y*" as a folder: a `SKILL.md` (YAML frontmatter with a `name` and a
`description`, then a free-form Markdown body) plus whatever sidecar files the skill needs,
such as scripts, templates or reference docs. `cop`'s frontmatter:

```yaml
---
name: cop
description: >-
  Component-oriented programming — my default app architecture
  (Vaadin/Swing/Android/TUI): component boundaries, inheritance, dependency
  direction, data APIs vs strategies. Read it BEFORE writing the class
  declaration or proposing a structure, even for "just one more class" or when
  the existing code is layered — that layering is what this skill most often
  overrules. Use when about to subclass a framework widget/view …
---
```

`pikuri-code` looks for skills at startup under `.pikuri/skills`, `.claude/skills` and
`.agents/skills`, beneath the project root and your home directory, the project's winning a
name clash. The banner lists what it found:

```
Loaded 21 skill(s): amazon-appstore, android-emulator, cop, design-docs, …
Type /<skill-name> to load one yourself; the agent can also load them on its own.
```

Every skill's name and description go into an `<available_skills>` block in the system prompt.
The body stays on disk until the model calls the `skill` tool, which returns it along with the
skill's own directory, so the model can `read` a sidecar by its relative path. The same folder
works in Claude Code and `pi`: the banner above is twenty skills written for Claude Code,
loaded by `pikuri-code` unchanged.

## Loading one by hand

The smallest skill that does something visible. In a project of your own, save this as
`.pikuri/skills/lol/SKILL.md`:

```markdown
---
name: lol
description: Reply with "lol" to anything.
---

When the user asks anything, just reply "lol". Nothing else.
```

Start `pikuri-code` there and type the skill's name as a command:

```
> /lol
Skill 'lol' will load with your next message.
> What is the capital of France?
⊕ <skill name="lol" location="…/.pikuri/skills/lol/SKILL.md">
When the user asks anything, just reply "lol". Nothing else.
</skill>
lol
```

That's the whole mechanism: the body is text that joins the conversation, and the model
follows it. Now start again and ask the same question *without* typing `/lol`. On the test box
the model answered "The capital of France is **Paris**.", and in two more runs it ignored a
description rewritten to lead with its trigger ("Load BEFORE answering any user message…").
The skill was advertised the whole time. The model just never felt the need to read it.

The rest of the chapter is about that gap.

## Two ways a bundle gets invoked

A skill is *model-invoked*. Its description sits in the system prompt on every turn, so the
model can decide the skill applies and call `skill(name: …)`. That resident cost is what buys
the autonomy, when the autonomy works.

Some bundles never wanted it. A "generate this week's work log" prompt is one you fire
deliberately, by name: the model has no business judging when it applies, and paying tokens
every turn to tell it *not* to is the worst of both. Those are **slash commands**: one `.md`
file under `.pikuri/commands` or `.claude/commands`, invoked by typing `/name`, advertised to
nobody.

```markdown
---
description: Generate a weekly work log from git history.
argument-hint: <project-label>
---

Weekly log for `$ARGUMENTS`, Monday through today, from my commits.
```

Saved as `~/.claude/commands/wh.md`, that is `/wh swingai` in `pikuri-code`. What it expands
to becomes *your* message: the command is a typing shortcut, not a second kind of instruction,
which is why it lands as a plain user turn and not as the reference block, harness framing in
a `<system-reminder>` envelope, that a skill you typed in becomes.

The distinction to carry away: **who decides**. If the model should notice the situation and
reach for it, it is a skill, and it costs prompt tokens. If you know when you want it, it is a
command, and it costs nothing until you type it. A skill whose description says "only invoked
manually" is a bundle filed on the wrong surface. And `/lol` above is the middle case: a skill,
loaded the way a command is, because you decided.

pikuri will not run shell commands out of a command file, the way Claude Code's `` !`cmd` ``
does: a `.md` that arrives with a cloned repo would otherwise be arbitrary code execution
behind a keystroke. Such a file is refused outright, and so is one declaring `allowed-tools:`,
a narrowing pikuri can't honour. See
[pikuri's trifecta chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/trifecta-detector.md)
for how a command's bytes are graded once they are in the conversation.

## A third answer: the model decides, once the project proves relevant

"Model-invoked, so it costs prompt tokens forever" has a middle setting. Ten skills at a couple
of hundred words each is five kilobytes on every turn, and in any one session nine of them are
about a language you are not writing today. A skill can name the files it is about:

```yaml
paths:
  - "**/*.rb"
  - "**/*.gemspec"
```

Now it is not in the prompt at all: not its description, not its name, not a placeholder
saying something was left out. The first time the agent reads, writes or edits a matching file,
its description appears in the conversation and the model can load it:

```
→ Read(a.rb)
· skills available: rbstyle, writing-rdoc (matched a.rb)
⊕ These skills just became relevant to the files you are working with, and are now loadable: …
```

Nothing happens in your Java project. `/clear` puts it back to sleep, along with the rest of
the conversation.

Patterns follow `.gitignore` rules, which is a good thing to know before writing one:
`build.gradle` with no slash matches at any depth, `src/main` with a slash is pinned to the
project root, and a bare `ideas` covers everything under it. One trap: `paths: []` does
**not** mean "never advertise". An empty list, `["**"]`, and a `paths:` with nothing under it
all mean *always*, because that is how the other harnesses reading this key behave.

This is a relevance filter, not a permission: the agent can reach a hidden skill any time it
reads a matching file, and *it* chooses which files to read. What it buys is a smaller prompt
and fewer irrelevant instructions competing for attention, not containment.

An inventory that grows mid-conversation may sound unsettling, but it is not new:
`mcp_connect` already adds tools to a running agent the same way. What arrives here is
smaller, a description, never a body. Loading still takes the deliberate `skill` call.

## Why a skill needs a trigger and an MCP server doesn't

Connect an MCP server for your calendar and the model uses it the first day, unprompted, off a
one-line description. Install `cop` and the model will read your codebase, copy whatever is
next to it, and hand you an `AbstractPersonView`, with the skill's description sitting in the
prompt the entire time.

That is not a writing-quality problem, and tuning the wording does not fix it: `lol` lost with
a trigger-first description too. The two advertise different things.

An MCP server advertises a **capability**. The model wants to know what is on your calendar,
has no way to find out, and a tool appears that does exactly that. It can *feel the gap*, so
the description only has to name the thing that fills it.

A skill usually advertises a **correction**. The model already has an answer it is satisfied
with ("Paris" is a fine answer), and the skill's job is to say that answer is wrong. It cannot
feel the absence of a rule it does not know it broke: nothing in "add a person view" tells it
that a component rule is due. So the description has to win a race it is never told it is
running.

Corrections are also mostly **subtractive**: don't subclass, never write that, cut the
rationale section. That is the hardest shape to transmit, because the loudest competing signal
is the code already in the context window, and an example can only demonstrate what is
*there*. You can copy a neighbouring file's tag style. You cannot learn "don't add a base class"
from a file whose author already added one. **Imitation transmits presence and never
absence.**

Which is why a subtractive rule loses to the nearest exemplar unless something puts it in
front of the model at the moment it is about to break it. That moment is what a trigger is for,
and it is why `paths:` exists on skills and has no counterpart on an MCP server.

And what firing late costs is not the round-trip. It is the work already done under the wrong
model: an agent that reads a dozen files, sketches an `AbstractPersonView`, and *then* meets
the rule has to throw the sketch away, and that discarded reasoning is far more context than
the skill body would ever have cost. Pre-loading bodies to save the round-trip spends resident
tokens in every session to buy back one turn in a few.

`cop` itself ends on the same finding, from use rather than theory: "Skills don't reliably
self-activate on 'starting to code'; the dependable trigger is a one-line pointer in the
*project's own* CLAUDE.md / AGENTS.md." `pikuri-code` reads both at startup
(`Loaded context from …/AGENTS.md`), so the line works here too:

```markdown
- **Read the `cop` skill before designing components or app architecture.**
  This is a component-oriented app; the skill carries the architecture. Not
  conditional — nearly every task here is component/UI work.
```

So the triggers, from most dependable to least: you typing `/cop`; an unconditional line in
the project's context file; a `paths:` glob that fires on the first matching file; and last,
the description alone.

## Writing a description that fires

The description is not documentation. It is the only thing the model sees until the body
loads, so it is a routing decision ("is this my situation?"), and everything that does not
help answer that is costing you tokens on every turn.

Four rules, roughly in order of payoff.

**Lead with the trigger, not a summary.** The model reads the description while deciding, so
the deciding half goes first:

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

**Cut the narrative.** No history of why you wrote the skill, no pitch for how useful it is.
If a sentence would not change the model's yes-or-no, delete it.

**Know which budget you are spending.** An ungated description is resident on every turn of
every session, so it has to be tight. A `paths:`-gated one is paid only when its glob fires, so
it can afford to be trigger-heavy: spell out the edge cases, including when *not* to load.
`cop`'s description is over eight hundred characters of triggers, ungated; the same words would be
cheap behind a `paths:` gate, and they are what that budget is for.

**State a ban literally, not categorically.** "Never write `Not thread-safe`" beats "skip the
negative", and "never open with 'This class …'" beats "avoid boilerplate openings". A
categorical ban asks the model to first classify its own output as an instance of the category
and only then obey: two steps where a literal string is one, and the classification step is
the one that fails. Reach for the category only when you cannot enumerate the strings.

## What a skill can reach, and where it stops

The book asks every cage the same question. A skill has no process of its own, so the question
turns into two: whose text reaches the model, and what runs when a skill ships a script.

**A skill is text a folder puts into your prompt.** Every ungated description lands in the
system prompt at boot; a `paths:` promotion and a skill you type in arrive as reference blocks
(user turns in a `<system-reminder>` envelope, for reasons [the wire chapter](wire.md) gives);
a body the model loads arrives as a tool result. The project's skill folders are
whatever the repository you `cd` into ships, and the Agent Skills standard exists precisely so
bundles travel. A cloned repo's `.claude/skills` reaches your prompt without asking you
anything. What pikuri does about it is grade it: the trifecta report counts a project's bundles
as content an attacker may control, unless you vouch for them at boot. The grading blocks
nothing; it is the report telling you which legs you hold.

**The agent can write one for next time.** The project root is writable, and `write` asks only
before overwriting an existing file, so the agent (or an injection steering it) can create
`.claude/skills/helpful/SKILL.md` without a prompt. The next session loads it, and "did you
write the files under this directory yourself?" would invite a *yes*. So git answers first. At
boot, `pikuri-code` compares every file under the project's skill and command folders with
`HEAD`, and a file no commit vouches for (untracked, gitignored, changed) makes the project's
bundles untrusted without the question:

```
These skill and command files match no commit, so this project's bundles count as untrusted
(an agent may have written them; review and commit them to vouch for them):
.claude/skills/helpful/SKILL.md.
```

Committing is how you say you read what is there. Outside a git repository there is no commit
to compare with, so a project's bundles always count as untrusted. The check hashes bytes with
`git hash-object --no-filters` rather than running `git status`, which can run a repository's
own clean filters; `Pikuri::Bundle::Unreviewed` has the detail. Your home skill folders are
vouched for without a check, because the agent can't write there: they reach the file tools
read-only and sandboxed `bash` as a throwaway overlay. Turn off both the sandbox and the
confirmer (`--yolo`) and that stops being true, so then home bundles count as untrusted too.

**A skill's script runs where `bash` runs.** A sidecar script does nothing until the model runs
it through `bash`, so it gets [the shell chapter](shell.md)'s cage: Bubblewrap's view of your
files, the confirmer for anything that isn't provably read-only, and the network, which the
sandbox shares. A script from a skill you didn't write is code you didn't write; past what
Bubblewrap stops, the wall is the same as everywhere else in this book, a virtual machine
around the whole process.

**Sub-agents get no skills.** A sub-agent's `skill` tool sees a sealed catalog, and no bundled
persona names it, so a `FILE_MINER` reading a hostile file can't load a skill it found
mentioned there.

## When a skill is the wrong tool

- **You know when you want it:** a slash command. It costs nothing until you type it.
- **It should apply to every task in this project:** one line in `AGENTS.md`, like `cop`'s
  pointer above. A skill whose trigger is "always" is a context file with extra steps.
- **The model lacks a capability, not a rule:** an MCP server or a tool. The model feels that
  gap on its own.
- **The work needs a different set of tools, or a separate context:** a persona, run as a
  sub-agent ([pikuri's sub-agents chapter](https://codeberg.org/mvysny/pikuri/src/branch/master/book/subagents.md)).

What remains is a skill's real niche: a correction or a body of know-how that applies to
*some* tasks, is too big to keep resident, and has a moment you can name, best of all as a
file pattern.

## What's next

[The messages array is not the prompt](wire.md) is the debugging chapter, and it opens on a
skills bug: a path-triggered promotion that fired correctly, appended correctly, and reached
the HTTP payload correctly, while the model went on insisting it could only see five skills. It
could. The chapter is about the step between your messages array and what the model actually
reads, the one place none of your own assertions can reach.
