# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for the vector-database supervisors — one per {Backend} engine,
    # named to pair ({Backend::Qdrant} ↔ {Server::Qdrant}, etc.). The backend
    # owns the store protocol; the server owns its *lifetime*. Both
    # implement the same duck-typed protocol (+.ensure_running+ /
    # +#ensure_running!+ / +#client(collection:)+ / +#close+), so a host chains
    # +ensure_running.client(...)+ and closes at teardown without branching per
    # engine.
    #
    # For {Qdrant} the lifetime is a podman/docker container, run by the composed
    # {Container} helper so the supervisor is just the engine's identity.
    # {InMemory} is the null supervisor (no process, just the in-process store
    # registry). Hosts already running an engine construct the
    # backend directly and never touch this namespace.
    #
    # Only *supervisors* (and {Container}) live here. A class with "server"
    # in its name that is actually an HTTP *client*, like
    # {Reranker::LlamaServer}, stays in its feature namespace.
    module Server
    end
  end
end
