# pikuri-rag and pikuri-vectordb move here, with their chapters

Status: the workshop's side is done (2026-11-18); waiting on pikuri's commit **Y**. This is the
workshop's half of decision **B** in pikuri's `design/ideas/fileindex-replaces-rag.md`, which
the owner agreed on 2026-11-17. That file says why, and its "Commit Y" section lists pikuri's
half.

## Order across the two repos

1. pikuri: commit **X**, the secretary and briefing on the file index. Done: `43ecf1e`.
2. Here: the gems copied in from X, with their `D_` entries, vectordb's seam clauses, the
   corpus line in `SECURITY.md` and the two idea files. Done.
3. Here: `pikuri-corpus` moved to pikuri-rag with `--hybrid`; `containers.md`, `vectordb.md`
   and `rag.md` written for this book and measured from this checkout, after the OS assistant
   in the running order. Done; their headings are settled.
4. pikuri: commit **Y** deletes its copies and puts `recall.md` (drafted in `9422499`) in its
   ToC.
5. Here: set `PIKURI_REF` to Y, then check the links below.

From 2 on, this copy is the live one; pikuri's stays frozen until Y deletes it. Neither repo
releases either gem until the move settles (owner, 2026-11-18). The first workshop release that
ships them must be numbered above the last version pikuri published.

## At step 5

- **Our links into pikuri's book must survive Y.** By anchor: `chat.md#3-start-llama-server-in-multi-model-mode`
  (`vectordb.md`), `trifecta-detector.md#who-declares-each-leg` (`vectordb.md`),
  `recall.md#whose-parser-reads-a-hostile-file` (`vectordb.md`, `os-assistant.md`). By file:
  `recall.md`, `chat.md`, `security.md`, `secretary.md`. `grep -n 'pikuri/blob/master/book' book/`
  lists them all.
- **pikuri links ours by file only** (`book/README.md`, `vectordb.md`, `rag.md`), so renaming one
  of those files needs a pikuri-side fix; a heading doesn't.
- **If Y drops `chat.md`'s router section**, `vectordb.md`'s "Prerequisites: three models, one
  server" must stand on its own; it already owns the preset file.
