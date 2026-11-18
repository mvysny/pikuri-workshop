# pikuri-os design notes

The settled design rationale that fits neither the user-facing guide
chapter ([`book/os-assistant.md`](../../book/os-assistant.md)) nor
the per-class YARD headers — the cross-cutting *why* that spans several
classes at once. The gem's threat model (kernel-severed egress +
confirmed mutations + the passive-command detector) is **not** here:
it graduated into the book's OS-assistant chapter and the Sandbox seam
([`../pikuri-code/AGENTS.md`](../../pikuri-code/AGENTS.md)) plus the
Confirmer / Workspace seams
([`../pikuri-workspace/AGENTS.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/pikuri-workspace/AGENTS.md)). What remains for this file
is what no single class owns:

1. how file search pairs with the rest of the agent;
2. whether the default local model is deep enough for diagnosis.

## File search: the index, then grep

The file search is pikuri-fileindex's, wired by {Pikuri::Os::Extension}
over the whole disk. Why keyword recall over the desktop's index and not
embeddings, and why localsearch before recoll, is
[pikuri-fileindex's architecture note](https://codeberg.org/mvysny/pikuri/src/branch/master/pikuri-fileindex/design/architecture.md).

What pikuri-os adds is the fallback. The index misses source code and
anything inside a git checkout, and a query worded differently from the
file. pikuri-os has full-disk `read`, `grep`, `glob` and `bash`, so the
agent rephrases and then greps the likely folders; nothing else needs
building. Embeddings would only close the rarest miss, a real gap in
meaning, and stay declined.

## Model fit: is ~3 B active enough to diagnose?

The default `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M` splits the question in
two. Factual recall scales with *total* params — 35 B is ample for FHS,
man pages, apt. The worry was reasoning depth, which scales with the ~3 B
*active* budget: a causal chain like "service failed → the log says Y →
therefore Z" might come out shallow. Initial testing says it doesn't — the
model carries a real diagnosis end to end, not just flag recall. The
design hedges anyway: the agent iterates with tools rather than
one-shotting, and verifies recall by *reading* (a man page beats a
remembered flag). **Revisit** if longer causal chains show the active
budget falling short. Why an MoE at all, and the same-tier and
dedicated-box swaps, is the book's first-conversation chapter
([`book/chat.md`](https://codeberg.org/mvysny/pikuri/src/branch/master/book/chat.md) §"Why a mixture-of-experts model").
