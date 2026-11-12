# Converter image for Pikuri::Extractors::DOCUMENTS — a one-shot,
# networkless stdin→stdout document converter. Built locally by the
# extractor on first use (`docker build -t pikuri-internal-extractors:<version> .`);
# never pulled from a registry, so what runs is exactly what you can
# read here.
#
# Runtime contract (enforced by the extractor's `docker run` flags,
# not by this image): --network=none --read-only --cap-drop=ALL
# --tmpfs /tmp, no volume mounts. Document bytes arrive on stdin,
# Markdown leaves on stdout, diagnostics on stderr. Network exists
# only at *build* time (apt + pip below).
#
# All converters are version-pinned: pandoc and poppler (pdftotext)
# via the pinned Debian release of the base image, markitdown via the
# exact pip version. Bump deliberately, with a conversion smoke-test.
FROM python:3.13-slim-trixie

# poppler-utils ships pdftotext — the PDF arm. Its C++ parser is
# exactly the kind of attack surface this networkless container
# exists to contain.
RUN apt-get update \
    && apt-get install -y --no-install-recommends pandoc poppler-utils \
    && rm -rf /var/lib/apt/lists/*

# Extras pull the per-format converter deps (mammoth, openpyxl,
# python-pptx, ...). No `all` — the OCR / transcription / cloud arms
# would bloat the image and want network or models at runtime.
RUN pip install --no-cache-dir 'markitdown[docx,xlsx,xls,pptx]==0.1.6'

COPY convert.sh /usr/local/bin/pikuri-convert
RUN chmod 0755 /usr/local/bin/pikuri-convert

# Drop root; HOME on the tmpfs so anything insisting on a writable
# home (cache dirs etc.) lands somewhere ephemeral under --read-only.
ENV HOME=/tmp
USER 65534:65534

ENTRYPOINT ["pikuri-convert"]
