# pikuri-extractors — design & threat model

Audience: someone extending pikuri-extractors or auditing the posture it
converts untrusted documents under. The per-class contracts — the
`matches?` / `extract` / `extract_lines` / `register` signatures, the
exact converter argv, the `@raise` conditions — live in the
{Pikuri::Extractors::Documents} YARD header. There is no dedicated book
chapter: the guide wires `pikuri-pdf` (the vector-DB chapter, the OS-assistant chapter), and the vector-DB chapter
shows when an agent that browses the web swaps in this extractor. What this file carries is the
cross-cutting *why* the class header would otherwise swell with — the
sandbox threat model, the PDF-arm trade-off against a whole other gem,
the deliberately-unsupported formats, and why paging re-converts.

AGENTS.md's gem inventory holds the one-liner this file resolves:
"Pick one PDF arm per host (this or pikuri-extractors')."

## Container first, host CLI second

The preferred converter is a one-shot, locally-built docker container
({Pikuri::Extractors::Documents::IMAGE}): `docker run --rm -i
--network=none --read-only --cap-drop=ALL`, bytes in via stdin, Markdown
out via stdout, **no volume mounts**. Two reasons over a host-installed
converter:

- **Security.** These documents typically arrive via `fetch` /
  `web_scrape` (untrusted bytes), and complex format parsers — poppler,
  the OOXML/ODF zip readers — are a classic native-code exploitation
  surface. In the container a malicious document sees no network and no
  host filesystem; worst case is garbage Markdown.
- **Reproducibility.** The Dockerfile pins pandoc + markitdown; a host
  install is whatever version the machine happens to have.

When docker is unavailable it falls back to host `pandoc` / `markitdown`
/ `pdftotext` CLIs — the same stdin→stdout contract, one code path with
two argv builders. The fallback trades the sandbox away for whatever the
host provides, so a host that cares about the untrusted-bytes surface
keeps docker available and lets the container win.

## PDF: this gem or pikuri-pdf — pick one per wiring

The PDF arm (pdftotext, with `"--- Page N ---"` markers restored from
pdftotext's `\f` separators) makes this extractor a *superset* of
pikuri-pdf's formats, so a host registering `DOCUMENTS` does **not** also
register `Extractors::PDF` — one extractor per format keeps the
registry's first-match-wins legible. The trade:

- **This gem** — PDF parsing inside the sandbox (poppler is native code
  running on attacker bytes), one gem for every document format. Costs:
  docker (or the host CLIs), no lazy paging (each paged read re-converts
  the whole PDF — see below), and the generic `:document` kind, so the
  Read tools say "End of file" not "End of PDF" and a scanned PDF reads
  as "(Empty file)" rather than a scanned-image hint.
- **pikuri-pdf** — in-process pure Ruby (no infra), lazy paging (a
  windowed read of a 500-page PDF parses only its window), PDF-specific
  Read wording. Costs: pdf-reader's five-gem dependency tail, and parsing
  untrusted bytes in-process (pure Ruby, so DoS at worst).

pikuri-pdf's own header carries only its local dependency-isolation
reason and points here for the full contrast.

## Deliberately out of scope

- **ODS / ODP** — neither pandoc nor markitdown reads them; the only
  converter that does, LibreOffice headless, costs a 2 GB+ image.
- **Image OCR / audio transcription** — markitdown's optional arms need
  model downloads, against the "networkless and small" image. A
  multi-modal main LLM is the pikuri answer to images.

## Paging economics

A subprocess converter needs the whole document up front, so there is no
lazy parse: every `Extractor.extract_paged` call re-runs the full
conversion (accepted — no result cache in v1). This is the deliberate
contrast that makes the PDF trade-off above legible — pikuri-pdf pages
lazily, a subprocess converter structurally cannot. Both legs still
*stream* rather than buffering: the document is copied into the
converter's stdin and the Markdown lands in a Tempfile yielded from
disk, so neither the input nor the full output is ever resident during
paging. Those streaming mechanics are per-symbol truth on
{Pikuri::Extractors::Documents#extract_lines} and `#convert`.
