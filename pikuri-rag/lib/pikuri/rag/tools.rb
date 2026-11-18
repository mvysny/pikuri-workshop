# frozen_string_literal: true

module Pikuri
  module Rag
    # Namespace for the two tools this gem adds — {Tools::Search}
    # (+rag_search+) and {Tools::SearchKeywords} (+rag_search_keywords+) — which split along the
    # two questions a corpus gets asked: *relevance*, a ranked sample, and
    # *completeness*, the whole set.
    #
    # The family's other two members are not here, because they are not new
    # code: {Pikuri::Rag::Extension} registers
    # {Pikuri::VectorDb::Tools::Read} and
    # {Pikuri::VectorDb::Tools::Reindex} under +family: 'rag'+, so
    # +rag_read+ and +rag_reindex+ *are* the vectordb classes with a
    # different prefix. Look for them there.
    module Tools
    end
  end
end
