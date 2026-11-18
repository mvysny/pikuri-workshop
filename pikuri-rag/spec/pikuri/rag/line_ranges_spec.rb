# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'

# A fused rag_search winner can come from either leg, so both must hand back
# the same +lines a-b+ for a chunk. Indexed through the real Corpus into a
# Hybrid, every chunk's keyword-leg range must equal its vector-leg range;
# that the vector leg's range reads back right is pikuri-vectordb's
# line_ranges_spec.
describe 'Chunk line ranges across the two legs' do
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-rag-line-ranges-')).realpath }
  let(:vectors) { Pikuri::VectorDb::Backend::InMemory.new }
  let(:hybrid) do
    Pikuri::Rag::Backend::Hybrid.new(vectors: vectors, keywords: Pikuri::Rag::Backend::Fts5.new)
  end

  after do
    hybrid.close
    FileUtils.rm_rf(root)
  end

  it 'stores the same range in the keyword leg as in the vector leg' do
    root.join('policy.md').write("# Pricing\r\n\r\nList prices hold through Q1\runless renewed.\n\n" \
                                 "#{(1..40).map { |i| "word#{i}" }.join(' ')}\nlast line")
    tokenizer = Object.new
    def tokenizer.count(text) = text.split.length
    embedder = Object.new
    def embedder.embed(texts) = texts.map { [1.0, 0.0] }
    Pikuri::VectorDb::Corpus.new(
      backend: hybrid, source: root, embedder: embedder,
      chunker: Pikuri::VectorDb::Chunker::FixedWindow.new(size: 7, overlap: 2, tokenizer: tokenizer)
    ).index_all!

    stored = vectors.query(vector: [1.0, 0.0], top_k: 10_000).map(&:chunk)
    assert_operator stored.length, :>, 5
    stored.each do |chunk|
      match = Pikuri::Rag::Query.any(chunk.text, stemmer: hybrid.stemmer)
      keyword = hybrid.keyword_query(match: match, top_k: 10_000).find { |r| r.chunk.id == chunk.id }
      assert_equal chunk.metadata.slice(:first_line, :last_line),
                   keyword.chunk.metadata.slice(:first_line, :last_line), chunk.id
    end
  end
end
