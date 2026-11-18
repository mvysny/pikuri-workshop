# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-vectordb gem: appends the gem's +prompts/+ to
# +Pikuri::PROMPT_DIRS+ and mounts a per-gem Zeitwerk loader at this +lib/+, so
# +lib/pikuri/vector_db/extension.rb+ autoloads as
# +Pikuri::VectorDb::Extension+.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  # Namespace for the local-corpus vector search feature. The host builds one
  # {Corpus} per corpus and wires it onto each agent via {Extension}
  # (+c.add_extension+); the {Corpus} orchestrates sources → text →
  # {Chunker} → {Embedder} → +Backend#upsert+; a swappable +Backend+
  # ({Backend::InMemory} / {Backend::Qdrant}) stores and
  # queries; the optional {Reranker::LlamaServer} is a quality knob. The
  # +Tools/+ directory ({Tools::Search} / {Tools::Read} / {Tools::Reindex}) *is*
  # the gem's LLM-facing surface.
  #
  # Two name conventions: the Ruby namespace is +VectorDb+ (the +Mcp+/+SubAgent+
  # casing precedent), the LLM-visible tool is +vectordb_search+ (snake_case, no
  # underscore between +vector+ and +db+ — matches the other bundled tools).
  module VectorDb
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-vectordb'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(File.expand_path('pikuri-vectordb.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
