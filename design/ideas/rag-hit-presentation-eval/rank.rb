# frozen_string_literal: true

# Retrieval ranks, no model: where the first gold hit sits in rag_search's fused list against the
# same list with the vector leg's #1 pinned first. Top-5 recall and MRR over the whole list.
#
#   BUNDLE_GEMFILE=/home/mavi/work/my/courts/Gemfile bundle exec ruby rank.rb

LIBRARY_ONLY = true
require_relative 'agent-eval'

def first_gold(results, gold)
  results.each_with_index do |r, i|
    m = r.chunk.metadata
    return i + 1 if gold.any? { |g| g['file'] == r.chunk.source && m[:first_line] <= g['last'] && m[:last_line] >= g['first'] }
  end
  nil
end

lists = { 'vector' => [], 'fused' => [], 'vfirst' => [] }
QUESTIONS.each do |entry|
  vector = EMBEDDER.embed([entry['q']]).first
  vec = RAG_CORPUS.backend.query(vector: vector, top_k: Search::LEG_K)
  match = Pikuri::Rag::Query.any(entry['q'], stemmer: RAG_CORPUS.backend.stemmer)
  kw = match ? RAG_CORPUS.backend.keyword_query(match: match, top_k: Search::LEG_K) : []
  gold = gold_of(entry)
  lists['vector'] << first_gold(vec, gold)
  lists['fused'] << first_gold(Search.fuse(vec, kw), gold)
  lists['vfirst'] << first_gold(vector_first(vec, kw), gold)
end
lists.each do |name, ranks|
  top5 = ranks.count { |r| r && r <= 5 }
  mrr = ranks.sum { |r| r ? 1.0 / r : 0 } / ranks.size
  at1 = ranks.count(1)
  puts format('%-7s top-5 %2d/41   gold at #1 %2d/41   MRR %.2f', name, top5, at1, mrr)
end
