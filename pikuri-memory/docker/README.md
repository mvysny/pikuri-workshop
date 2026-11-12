# pikuri-memory docker artifacts

These files back `Pikuri::Memory::Mem0Server`, the self-managed mem0 +
Qdrant sidecar supervisor. They are not run by hand in normal use — the
supervisor clones mem0, applies the patch, and drives compose through
`Pikuri::Subprocess.spawn`.

- **`docker-compose.yml`** — two services, **no Postgres**: a mem0 REST
  server (`pikuri-internal-mem0-server`) built from a pinned mem0
  checkout, and Qdrant (`pikuri-internal-mem0-qdrant`) as the vector
  store, on an explicitly-named `pikuri-mem0` network. Parameterized by
  `PIKURI_*` environment variables the supervisor sets (build-context
  path, host data dir, router URL, model ids, ports, dims). Both
  published ports bind `127.0.0.1` only. The containers are **ephemeral**
  — all state is bind-mounted to the host under `PIKURI_DATA_DIR`
  (`~/.cache/pikuri/mem0/data/{qdrant,history}`), so the corpus survives
  container recreation, same posture as Server::Chroma.

- **`qdrant-default-config.patch`** — applied to the pinned mem0 checkout
  before the image build. It swaps the server's `DEFAULT_CONFIG` vector
  store from **pgvector** to **qdrant** (env-driven host/port/dims). Two
  reasons, both load-bearing:
  1. mem0's pgvector provider has a top-k inversion bug — it returns the
     *farthest* matches (cosine distance ranked as if it were a
     similarity). Qdrant ranks correctly. See
     `../design/architecture.md` §"Root cause: the pgvector top-k inversion".
  2. the pgvector provider connects to Postgres *eagerly at boot*, so
     leaving it as the default would force a Postgres container into the
     stack. Defaulting to Qdrant lets the server boot Postgres-free.

  The patch is pinned to mem0 ref
  `a3154d59e52386d4e1189c1f5f44819868f76514` (library 2.0.4). Bumping
  `Mem0Server::MEM0_REF` requires regenerating the patch if upstream's
  `DEFAULT_CONFIG` moved — `Mem0Server#prepare_checkout!` applies it
  fail-loud, so drift surfaces as a build-time error, never a wrong image.

## Why build from source

mem0's REST server lives in the repo's `server/` directory (a thin
FastAPI wrapper over the `mem0` Python library — it is *not* part of the
`mem0ai` PyPI package), and the only published server image on Docker Hub
is stale (pre-v3). So the supervisor builds the image from a pinned
checkout using mem0's own `server/dev.Dockerfile`.

## Verified

The full stack was run end-to-end against a local llama.cpp router
(non-reasoning `Qwen2.5-7B-Instruct` extractor + `nomic-embed-text-v1.5`
embedder): server boots with no Postgres, and `add` + `search` through
the REST API rank correctly on Qdrant.
