# pikuri-conversations: papercuts from the first host migration

Status: **collected from the hosts' moves onto the gem (2026-11-14); fixed ones are deleted,
these are what is left.** Each is small, and each cost the host a workaround or a paragraph. The bigger find from the same
migration has its own file: `injection-overtakes-turn-message.md`.

## `clear` answers `:busy` while the agent boots

`close` closes a boot no message waits on; `clear` still refuses every boot. A conversation
opened with `boot: true` sits in `:booting` for its probe — a connect timeout against an
unreachable server — so a `/clear` typed then is refused, and pikuri-tui logs "clear
conversation ignored: a turn is in progress" for a turn that does not exist. Not a guard
away: the boot thread would still install an agent built from the old history, so the fix
needs the boot to learn it was superseded (a generation counter it checks before installing,
say) and a fresh boot started behind it.

## From pikuri-tui's move onto the gem (2026-11-14)

From moving pikuri-tui's three shells (`Chat` / `Code` / `Computer::App`) off their
own turn loop.

### No way to send a skill and a message as one turn — `Q_system_with_message`

`/<skill> rest` should put the skill's body ahead of `rest` in one turn. `inject_system` from
`:idle` starts a bare turn at once, so `inject_system(body)` then `submit(rest)` runs the skill
alone and injects `rest` mid-turn (or, per `injection-overtakes-turn-message.md`, ahead of it).
pikuri-tui branches on `status.state`: idle or running, it schedules through the current
agent's `Skill::Extension` (which it must track per agent) and `submit`s; otherwise it
`inject_system`s and `submit`s into the boot queue, where order holds. Options:
`submit(text, system: [body])`, or `inject_system(text, run: false)` that only queues, so the
following `submit` carries it.
