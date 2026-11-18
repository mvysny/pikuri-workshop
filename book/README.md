# The workshop

Book 2. [pikuri's book](https://github.com/mvysny/pikuri/blob/master/book/README.md)
builds an assistant you can run on your host with your real data, safe because of what's
*missing*. This one is about power, and most of it needs a cage: a shell, MCP servers, skills'
scripts, language servers and the coding agent all run code you didn't write, and nothing can
be left out to make that safe. Each of those chapters says what its cage buys and where it
stops.

**This page is the running order.** Chapters are named, not numbered, and the sequence lives
here and nowhere else.

Retrieval needs no cage either. pikuri's book ends its search on the desktop's file index,
keyword search somebody else keeps; here the vector-DB and hybrid-retrieval chapters build an
index of your own that searches by meaning. Their agent has no way to send anything out, and
its Qdrant container is there to keep the index on disk, not to hold anything in.

The cages end on the coding agent, completed, the way pikuri's security arc ends on its
secretary. Hosting then steps outside the single-agent shape, and needs no cage: what pikuri
leaves to the app that runs many conversations at once.

## Chapters

- [The shell and its cage](shell.md) — a bare `pikuri-code`: `bash`, the Bubblewrap sandbox, the human gate, and where they stop.
- [The OS assistant: your machine](os-assistant.md) — the opposite cut: the whole disk, no network.
- [Containers: Podman, or rootless Docker](containers.md) — the runtime the next chapters start, and why the `docker` group is root.
- [Searching by meaning: the vector DB](vectordb.md) — embeddings, a reranker, Qdrant, and what meaning buys over the desktop's keyword index.
- [Hybrid retrieval: the questions vectors can't answer](rag.md) — a keyword index beside the vectors, for every match and the exact word.
- [Memories](memories.md) — automatic capture with mem0, on the agents that can afford it.
- [Your first MCP server](mcp.md) — a stranger's code as a tool.
- [MCPs revisited: containerised servers](mcp-revisited.md) — putting that code in a box, and narrowing the box to one host.
- [Agent Skills](skills.md) — instructions and scripts loaded on demand, and slash commands.
- [The messages array is not the prompt](wire.md) — what reaches the model, and what it drops.
- [Language intelligence](lsp.md) — the questions grep cannot answer.
- [Task tracking](tasks.md) — the agent's working memory on long work.
- [The coding agent, completed](code.md) — the whole wiring, and what each defense buys and where it stops, with all three legs present.
- [Hosting many conversations](conversations.md) — a chat app's many live conversations: the early cancel, typing mid-turn, one server's slots, and saving.
