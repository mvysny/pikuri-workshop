# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::Rag::Tools::Search do
  let(:vectors) { Pikuri::VectorDb::Backend::InMemory.new }
  let(:hybrid) do
    Pikuri::Rag::Backend::Hybrid.new(vectors: vectors,
                                     keywords: Pikuri::Rag::Backend::Fts5.new)
  end

  # Deterministic embedder: every query embeds to the same vector, which is
  # +acme.md:0+'s, so the vector leg's rank-1 hit is known.
  let(:embedder) do
    fake = Object.new
    fake.define_singleton_method(:embed) { |texts| texts.map { [1.0, 0.0] } }
    fake
  end

  def chunk(id, source, text, lines: [1, 1])
    Pikuri::VectorDb::Chunk.new(id: id, source: source, text: text,
                                metadata: { ordinal: 0, hash: 'h', first_line: lines[0], last_line: lines[1] })
  end

  def populate
    hybrid.upsert(
      chunks: [
        chunk('acme.md:0', 'acme.md', 'Acme agreed to hold list pricing through Q1.'),
        chunk('notes.md:0', 'notes.md', 'Invoice 4471 is still outstanding.', lines: [7, 9]),
        chunk('other.md:0', 'other.md', 'Unrelated risotto technique.')
      ],
      vectors: [[1.0, 0.0], [0.0, 1.0], [-1.0, 0.0]]
    )
  end

  # +.to_s+ because the observation is a Pikuri::Tool::Result; the display line
  # has its own test below.
  def execute(query: 'what did we agree about pricing?', reranker: nil)
    result(query: query, reranker: reranker).to_s
  end

  def result(query: 'what did we agree about pricing?', reranker: nil)
    Pikuri::Rag::Tools::Search.execute(
      embedder: embedder, backend: hybrid, reranker: reranker, query: query
    )
  end

  after { hybrid.close }

  describe 'as a Pikuri::Tool' do
    let(:tool) do
      Pikuri::Rag::Tools::Search.new(embedder: embedder, backend: hybrid,
                                     legs: Pikuri::Tool::TrifectaLegs::NONE)
    end

    it 'is named rag_search' do
      assert_equal 'rag_search', tool.name
    end

    it 'takes only a query' do
      assert_equal ['query'], tool.parameters.to_openai[:properties].keys.map(&:to_s)
    end

    it 'points the model at rag_search_keywords for the completeness question' do
      assert_includes tool.description, 'rag_search_keywords'
    end

    it 'carries the corpus legs it was handed' do
      legs = Pikuri::VectorDb::CorpusLegs.derive(private: true, trusted: false)
      built = Pikuri::Rag::Tools::Search.new(embedder: embedder, backend: hybrid, legs: legs)
      assert built.trifecta_legs.private
      assert_equal :hard, built.trifecta_legs.untrusted
      assert_equal :no_egress, built.trifecta_legs.egress_payload_review
    end
  end

  describe '.fuse' do
    def result(id, score)
      Pikuri::VectorDb::Backend::Result.new(chunk: chunk(id, id, id), score: score)
    end

    it 'ranks a chunk both legs found above either leg\'s exclusive rank-1' do
      a = result('a', 0.99)
      b = result('b', 0.10)
      c = result('c', 0.50)
      fused = Pikuri::Rag::Tools::Search.fuse([a, b], [b, c])
      assert_equal %w[b a c], fused.map { |r| r.chunk.id }
    end

    it 'replaces each score with the fused one' do
      a = result('a', 0.99)
      fused = Pikuri::Rag::Tools::Search.fuse([a], [a])
      assert_in_delta 2.0 / (Pikuri::Rag::Tools::Search::RRF_K + 1), fused.first.score, 1e-9
    end

    # The D_rrf_tuning regression: with RRF_K 60, a chunk both legs list
    # last outscored one leg's rank-1, and a strong leg's #1 sank.
    it 'ranks one leg\'s rank-1 above a chunk both legs list last' do
      depth = Pikuri::Rag::Tools::Search::LEG_K
      top = result('top', 0.99)
      deep = result('deep', 0.1)
      vector_leg = [top, *(2...depth).map { |i| result("v#{i}", 0.5) }, deep]
      keyword_leg = [*(1...depth).map { |i| result("k#{i}", 0.5) }, deep]
      ids = Pikuri::Rag::Tools::Search.fuse(vector_leg, keyword_leg).map { |r| r.chunk.id }
      assert_operator ids.index('top'), :<, ids.index('deep')
    end

    it 'tolerates an empty leg' do
      a = result('a', 0.99)
      assert_equal ['a'], Pikuri::Rag::Tools::Search.fuse([a], []).map { |r| r.chunk.id }
    end

    it 'is empty when both legs are' do
      assert_equal [], Pikuri::Rag::Tools::Search.fuse([], [])
    end
  end

  describe 'the hybrid pipeline' do
    it 'surfaces a keyword-only hit the vector leg ranked last' do
      populate
      out = execute(query: 'invoice 4471')
      assert_includes out, 'notes.md'
    end

    it 'formats as vectordb_search does — numbered source + line range + snippet, no score' do
      populate
      out = execute(query: 'invoice 4471')
      assert_match(/\AFound \d+ match/, out)
      assert_match(/^\[1\] notes\.md lines 7-9$/, out)
      refute_includes out, 'score'
    end

    it 'says so when the corpus has nothing' do
      assert_equal 'No matches found in the indexed corpus.', execute
    end

    it 'refuses an empty query without touching the backend' do
      assert_equal 'Error: query is empty', execute(query: '   ')
    end

    it 'runs the vector leg alone when the query has no searchable tokens' do
      populate
      out = execute(query: '???')
      assert_includes out, 'acme.md'
    end

    it 'asks each leg for LEG_K results' do
      populate
      asked = []
      hybrid.define_singleton_method(:query) do |vector:, top_k:|
        asked << [:vector, top_k]
        super(vector: vector, top_k: top_k)
      end
      hybrid.define_singleton_method(:keyword_query) do |match:, top_k:|
        asked << [:keyword, top_k]
        super(match: match, top_k: top_k)
      end
      execute(query: 'invoice 4471')
      depth = Pikuri::Rag::Tools::Search::LEG_K
      assert_equal [[:vector, depth], [:keyword, depth]], asked
    end

    it 'caps the observation at FINAL_K results' do
      chunks = (1..12).map { |i| chunk("d#{i}.md:0", "d#{i}.md", "Pricing note number #{i}.") }
      hybrid.upsert(chunks: chunks, vectors: chunks.map { |_c| [1.0, 0.0] })
      out = execute(query: 'pricing')
      assert_equal Pikuri::Rag::Tools::Search::FINAL_K, out.scan(/^\[\d+\] /).length
    end
  end

  describe 'the display line' do
    it 'counts the fused matches, and carries no corpus text' do
      populate

      display = result.summary

      assert_match(/\AFound \d+ match(es)?\z/, display)
    end
  end

  describe 'the optional reranker' do
    it 'reorders the fused candidates' do
      populate
      reranker = Object.new
      reranker.define_singleton_method(:rerank) do |query:, documents:|
        # Reverse the fused order, so the assertion cannot pass by accident.
        documents.each_index.reverse_each.map.with_index do |source_index, rank|
          Pikuri::VectorDb::Reranker::Hit.new(index: source_index, score: 10.0 - rank)
        end
      end
      out = execute(reranker: reranker)
      # Fused, acme.md leads (the vector leg's #1) and other.md trails.
      assert_match(/\A\[1\] other\.md /, out.split("\n\n")[1])
    end

    it 'falls back to the fused ordering on a reranker outage' do
      populate
      reranker = Object.new
      reranker.define_singleton_method(:rerank) { |**| raise RuntimeError, 'reranker down' }
      out = execute(reranker: reranker)
      assert_match(/\AFound \d+ match/, out)
    end
  end
end
