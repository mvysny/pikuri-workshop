# frozen_string_literal: true

require 'spec_helper'

# What is left to test once the SQL lives in Fts5: that writes reach both
# stores, that reads come from the right one, and the two cross-store rules.
describe Pikuri::Rag::Backend::Hybrid do
  # Both halves real — each is covered in its own spec, trusted here.
  let(:vectors) { Pikuri::VectorDb::Backend::InMemory.new }
  let(:keywords) { Pikuri::Rag::Backend::Fts5.new }
  let(:hybrid) { Pikuri::Rag::Backend::Hybrid.new(vectors: vectors, keywords: keywords) }

  def chunk(id, source, text, hash: 'h1', ordinal: 0, lines: [1, 1])
    Pikuri::VectorDb::Chunk.new(id: id, source: source, text: text,
                                metadata: { ordinal: ordinal, hash: hash,
                                            first_line: lines[0], last_line: lines[1] })
  end

  def match(source, first_lines)
    Pikuri::Rag::Backend::DocumentMatch.new(source: source, first_lines: first_lines)
  end

  def populate
    hybrid.upsert(
      chunks: [
        chunk('acme.md:0', 'acme.md', 'Acme agreed to hold list pricing through Q1.'),
        chunk('acme.md:1', 'acme.md', 'Their meetings run long; invoice 4471 outstanding.',
              ordinal: 1, lines: [5, 8]),
        chunk('initech.md:0', 'initech.md', 'Initech pricing discussion deferred.', hash: 'h2')
      ],
      vectors: [[1.0, 0.0], [0.0, 1.0], [0.7, 0.7]]
    )
  end

  after { hybrid.close }

  describe 'writes fan out to both stores' do
    it 'upserts into each' do
      populate
      assert_equal 3, vectors.count
      assert_equal 3, keywords.count
    end

    it 'replaces a source in each' do
      populate
      hybrid.replace_source(
        source: 'acme.md',
        chunks: [chunk('acme.md:0', 'acme.md', 'Acme renewed at list pricing.', hash: 'h9')],
        vectors: [[1.0, 0.0]]
      )
      assert_equal 2, vectors.count
      assert_equal [match('acme.md', [1])], keywords.find(terms: ['"renewed"'])
      assert_equal [], keywords.find(terms: ['"meetings"'])
    end

    it 'deletes a source from each' do
      populate
      hybrid.delete_by_source('acme.md')
      assert_equal 1, vectors.count
      assert_equal 1, keywords.count
    end

    it 'empties each' do
      populate
      hybrid.delete_all
      assert_equal 0, vectors.count
      assert_equal 0, keywords.count
    end

    it 'passes vectors only to the store that has vectors' do
      # Fts5#upsert takes no vectors: at parameter, so a fan-out that forwarded
      # them blindly would raise here rather than silently ignore them.
      populate
      assert_equal 3, keywords.count
    end

    it 'propagates the vector store refusal of empty input' do
      assert_raises(ArgumentError) { hybrid.upsert(chunks: [], vectors: []) }
    end
  end

  describe 'reads come from the right store' do
    it 'takes the vector leg from the vector store' do
      populate
      assert_equal 'acme.md', hybrid.query(vector: [1.0, 0.0], top_k: 1).first.chunk.source
    end

    it 'takes both keyword reads from the keyword store' do
      populate
      assert_equal 'acme.md', hybrid.keyword_query(match: '"invoice"', top_k: 1).first.chunk.source
      assert_equal [match('acme.md', [1, 5])], hybrid.find(terms: ['"acme"', '"invoice"'])
    end

    it 'gates membership on the vector store alone' do
      populate
      # A keyword-only source must NOT read as indexed: the gate answers "did
      # the corpus produce this citation?", and a lagging keyword store would
      # otherwise make a correctly indexed document unreadable.
      keywords.upsert(chunks: [chunk('kw.md:0', 'kw.md', 'Keyword store only.')])
      refute hybrid.source_indexed?('kw.md')
      assert hybrid.source_indexed?('acme.md')
    end
  end

  describe 'indexed means both stores hold it' do
    it 'reports 0 chunks when the keyword store is empty but the vectors are not' do
      vectors.upsert(chunks: [chunk('acme.md:0', 'acme.md', 'Acme.')], vectors: [[1.0, 0.0]])
      assert_equal 1, vectors.count
      assert_equal 0, hybrid.count
    end

    it 'reports 0 chunks when the vector store is empty but the keywords are not' do
      keywords.upsert(chunks: [chunk('acme.md:0', 'acme.md', 'Acme.')])
      assert_equal 0, hybrid.count
    end

    it 'reports the real count once both hold it' do
      populate
      assert_equal 3, hybrid.count
    end

    it 'hides a vector-only source from the manifest, so the sweep reindexes it' do
      populate
      # A persisted vector store beside a fresh keyword index.
      vectors.upsert(chunks: [chunk('stale.md:0', 'stale.md', 'Only in the vectors.', hash: 'h3')],
                     vectors: [[0.1, 0.9]])
      refute_includes hybrid.sources_with_hashes.keys, 'stale.md'
      assert_includes vectors.sources_with_hashes.keys, 'stale.md'
    end

    it 'hides a keyword-only source from the manifest too' do
      populate
      keywords.upsert(chunks: [chunk('kw.md:0', 'kw.md', 'Only in the keywords.', hash: 'h4')])
      refute_includes hybrid.sources_with_hashes.keys, 'kw.md'
    end

    it 'reports the vector store hashes for the sources both hold' do
      populate
      assert_equal({ 'acme.md' => 'h1', 'initech.md' => 'h2' }, hybrid.sources_with_hashes)
    end
  end

  describe '#close' do
    it 'closes both stores' do
      closed = false
      vectors.define_singleton_method(:close) { closed = true }
      hybrid.close
      assert closed, 'the vector store must be closed too'
      assert_raises(StandardError) { keywords.count }
    end
  end
end
