# pikuri-extractors

Additional document extractors for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit:
office documents and PDFs → Markdown, converted preferably inside a
one-shot **networkless docker container**, so a malicious document
downloaded from the web is parsed somewhere it can't phone home or
read your files.

Provides:
- `Pikuri::Extractors::DOCUMENTS` — an extractor for the
  `Pikuri::Extractor` registry covering **DOCX, ODT, XLSX, legacy
  XLS, PPTX, EPUB, RTF, and PDF**. Once registered, every pikuri
  surface that routes through the registry picks the formats up for
  free: the `read` tool pages through a local `.docx`, `web_scrape`
  / `fetch` convert a downloaded `.odt`, the pikuri-vectordb indexer
  ingests an `.epub` or a paper PDF (with `--- Page N ---` page
  markers preserved for citations).

The actual conversion is done by [pandoc](https://pandoc.org) (ODF,
RTF, EPUB, DOCX — its readers preserve the most structure),
[markitdown](https://github.com/microsoft/markitdown) (the XLSX /
XLS / PPTX arms), and poppler's `pdftotext` (the PDF arm — its `\f`
page separators are rebuilt into `--- Page N ---` markers on the
Ruby side), dispatched per format. One stdin→stdout contract,
two ways to run it:

1. **Container (preferred).** A small, locally-built docker image
   (pinned pandoc + pinned markitdown; built from
   [docker/Dockerfile](docker/Dockerfile) on first use — read it,
   it's short) run as
   `docker run --rm -i --network=none --read-only --cap-drop=ALL`,
   bytes in via stdin, Markdown out via stdout, **no volume
   mounts**. Office-format parsers are large, complex codebases and
   the documents they parse are exactly the bytes an attacker
   controls; in the container, the blast radius of a parser exploit
   is one throwaway process that can see neither your network nor
   your filesystem.
2. **Host CLI (fallback).** When docker is absent or the daemon is
   down, a host-installed `pandoc` / `markitdown` / `pdftotext` is
   used directly — convenient, but unpinned and unsandboxed.

Deliberately **not** covered: ODS / ODP (neither converter reads
them; the only one that does is LibreOffice, a 2 GB+ image), and
image OCR / audio transcription (need model downloads — point a
multi-modal main LLM at images instead).

**PDF: this gem or [pikuri-pdf](https://codeberg.org/mvysny/pikuri/src/branch/master/pikuri-pdf) — pick one per
wiring.** This gem parses PDFs inside the sandbox (poppler is native
code chewing attacker-controlled bytes — exactly what the container
is for) but re-converts the whole document on every paged read;
pikuri-pdf is in-process pure Ruby with lazy page-windowed reads and
no infrastructure to set up. The guide's vector-DB chapter wires
pikuri-pdf and shows when to swap in this gem.

## Install

```ruby
# Gemfile
gem 'pikuri-extractors'
```

Plus *one* of: a working `docker` (recommended; the image builds
itself on first use, network is only needed for that build), or
host `pandoc` / `markitdown` CLIs.

## Usage

Requiring the gem changes nothing — registration is an explicit
opt-in your script makes, same philosophy as `c.add_extension`:

```ruby
require 'pikuri-core'
require 'pikuri-extractors'

Pikuri::Extractors::DOCUMENTS.register

# From here on, the registry handles the new formats everywhere:
text = Pikuri::FileType.read_as_text(Pathname.new('report.docx'))

# Optional: pay the one-time image build (~minutes) at boot instead
# of mid-conversation. Requires docker; skip when relying on host CLIs.
Pikuri::Extractors::DOCUMENTS.ensure_image!
```

## Performance posture

A subprocess converter has no lazy mode: every paged `read` of a
long document re-runs the full conversion (a cold `docker run` plus
the converter itself — roughly a second for pandoc, a few for
markitdown). That's accepted v1 behavior — no result cache — and it
is well inside what an LLM tool call tolerates.

## Format detection

Content-type when the transport provides one (HTTP header), byte
sniff otherwise: RTF by its `{\rtf` prefix; ODT / EPUB by the
uncompressed `mimetype` zip entry their specs mandate first; DOCX /
XLSX / PPTX by `[Content_Types].xml` plus an entry-name scan.
Legacy `.xls` is recognised by content-type only (its OLE2 container
isn't sniffable from the leading bytes), so a *local* `.xls` file —
no content-type — keeps pikuri-core's binary refusal.
