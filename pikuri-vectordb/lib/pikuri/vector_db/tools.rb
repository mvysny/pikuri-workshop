# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for this gem's LLM-facing tools — the
    # {Pikuri::Tool} subclasses {Extension} registers onto an
    # agent: {Tools::Search} (+vectordb_search+), {Tools::Read}
    # (+vectordb_read+), {Tools::Reindex} (+vectordb_reindex+).
    #
    # Grouping them under +tools/+ makes the gem's LLM-facing
    # surface visible in the file tree: everything the model can
    # *do* is in this directory; everything else in the gem is
    # host-facing plumbing (indexing pipeline, backends,
    # supervisors). Named +Tools+ (plural) so it can't be confused
    # with the {Pikuri::Tool} base class the members subclass.
    module Tools
    end
  end
end
