# pikuri-conversations: papercuts from the first host migration

Status: **collected from the hosts' moves onto the gem (2026-11-14); fixed ones are deleted,
this is what is left.** Each is small, and each cost the host a workaround or a paragraph. The
bigger find from the same migration has its own file: `injection-overtakes-turn-message.md`.

## `clear` answers `:busy` while the agent boots

`close` closes a boot no message waits on; `clear` still refuses every boot. A conversation
opened with `boot: true` sits in `:booting` for its probe — a connect timeout against an
unreachable server — so a `/clear` typed then is refused, and pikuri-tui logs "clear
conversation ignored: a turn is in progress" for a turn that does not exist. Not a guard
away: the boot thread would still install an agent built from the old history, so the fix
needs the boot to learn it was superseded (a generation counter it checks before installing,
say) and a fresh boot started behind it.
