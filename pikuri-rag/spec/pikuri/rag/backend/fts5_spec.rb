# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# No vector backend anywhere in this file — the point of the keyword store
# being its own class is that it answers on its own.
describe Pikuri::Rag::Backend::Fts5 do
  let(:fts) { Pikuri::Rag::Backend::Fts5.new }

  def chunk(id, source, text, hash: 'h1', ordinal: 0, lines: [1, 1])
    Pikuri::VectorDb::Chunk.new(id: id, source: source, text: text,
                                metadata: { ordinal: ordinal, hash: hash,
                                            first_line: lines[0], last_line: lines[1] })
  end

  def match(source, first_lines)
    Pikuri::Rag::Backend::DocumentMatch.new(source: source, first_lines: first_lines)
  end

  def populate
    fts.upsert(chunks: [
                 chunk('acme.md:0', 'acme.md', 'Acme agreed to hold list pricing through Q1.'),
                 chunk('acme.md:1', 'acme.md', 'Their meetings run long; invoice 4471 outstanding.',
                       ordinal: 1, lines: [9, 14]),
                 chunk('initech.md:0', 'initech.md', 'Initech pricing discussion deferred.',
                       hash: 'h2')
               ])
  end

  after { fts.close }

  describe 'the write half of the backend protocol' do
    it 'counts what it stored' do
      populate
      assert_equal 3, fts.count
    end

    it 'replaces by chunk id rather than duplicating the row' do
      populate
      fts.upsert(chunks: [chunk('acme.md:0', 'acme.md', 'Acme pricing frozen.')])
      assert_equal 3, fts.count
      assert_equal [match('acme.md', [1])], fts.find(terms: ['"frozen"'])
    end

    # The keyword leg must hand back the range the vector leg does, so a
    # chunk without one is a caller bug, not a row with a hole in it.
    it 'refuses a chunk with no line range' do
      bare = Pikuri::VectorDb::Chunk.new(id: 'x.md:0', source: 'x.md', text: 'x', metadata: { hash: 'h' })
      assert_raises(KeyError) { fts.upsert(chunks: [bare]) }
    end

    it 'replaces every chunk of one document' do
      populate
      fts.replace_source(source: 'acme.md',
                         chunks: [chunk('acme.md:0', 'acme.md', 'Acme renewed.', hash: 'h9')])
      assert_equal 2, fts.count
      assert_equal [], fts.find(terms: ['"invoice"'])
      assert_equal({ 'acme.md' => 'h9', 'initech.md' => 'h2' }, fts.sources_with_hashes)
    end

    it 'deletes one document, and all of them' do
      populate
      fts.delete_by_source('acme.md')
      assert_equal 1, fts.count
      fts.delete_all
      assert_equal 0, fts.count
    end

    it 'is a no-op deleting a source it never held' do
      populate
      fts.delete_by_source('nope.md')
      assert_equal 3, fts.count
    end
  end

  describe 'the bookkeeping reads' do
    it 'reports one hash per source, for the reconcile sweep' do
      populate
      assert_equal({ 'acme.md' => 'h1', 'initech.md' => 'h2' }, fts.sources_with_hashes)
    end

    it 'answers membership per source' do
      populate
      assert fts.source_indexed?('acme.md')
      refute fts.source_indexed?('nope.md')
    end
  end

  describe '#keyword_query' do
    it 'ranks by bm25, best first' do
      populate
      hits = fts.keyword_query(match: '"pricing"', top_k: 5)
      # initech.md is the shorter document, so bm25's length normalization
      # puts it first for the same single match.
      assert_equal %w[initech.md acme.md], hits.map { |h| h.chunk.source }
      assert hits.first.score >= hits.last.score, 'scores must be descending'
    end

    it 'rebuilds the chunk, so hits fuse with a vector leg by id' do
      populate
      hit = fts.keyword_query(match: '"invoice"', top_k: 1).first
      assert_equal 'acme.md:1', hit.chunk.id
      assert_equal({ hash: 'h1', first_line: 9, last_line: 14 }, hit.chunk.metadata)
      assert_includes hit.chunk.text, '4471'
    end

    it 'honours top_k' do
      populate
      assert_equal 1, fts.keyword_query(match: '"pricing"', top_k: 1).length
    end

    it 'stems English with porter' do
      populate
      assert_equal 1, fts.keyword_query(match: '"meeting"', top_k: 5).length
    end

    it 'does not match a word that only appears in the filename' do
      populate
      assert_equal [], fts.keyword_query(match: '"md"', top_k: 5)
    end

    it 'refuses a non-positive top_k' do
      assert_raises(ArgumentError) { fts.keyword_query(match: '"x"', top_k: 0) }
    end
  end

  describe '#find' do
    it "lists every source holding the term, with its matching chunks' first lines" do
      populate
      assert_equal [match('acme.md', [9])], fts.find(terms: ['"invoice"'])
      assert_equal [match('acme.md', [1]), match('initech.md', [1])], fts.find(terms: ['"pricing"']).sort_by(&:source)
    end

    # The regression: FTS5's own implicit AND is row-scoped, and a row is a
    # chunk — so a juxtaposed MATCH would answer "no such document" about
    # acme.md, whose "Acme" is in chunk 0 and whose "invoice" is in chunk 1.
    it 'ANDs across the whole document, not within one chunk' do
      populate
      assert_equal [match('acme.md', [1, 9])], fts.find(terms: ['"acme"', '"invoice"'])
    end

    it 'lists a chunk once however many terms it holds' do
      populate
      # Both words are in acme.md:0 alone, so the union is that one chunk.
      assert_equal [match('acme.md', [1])], fts.find(terms: ['"agreed"', '"pricing"'])
    end

    it 'keeps two chunks starting on the same line apart, ascending' do
      fts.upsert(chunks: [chunk('long.md:1', 'long.md', 'pricing tail', ordinal: 1, lines: [40, 41]),
                          chunk('long.md:0', 'long.md', 'pricing head', lines: [1, 40]),
                          chunk('long.md:2', 'long.md', 'pricing again', ordinal: 2, lines: [40, 52])])
      assert_equal [match('long.md', [1, 40, 40])], fts.find(terms: ['"pricing"'])
    end

    it 'excludes a source missing any one term' do
      populate
      assert_equal [], fts.find(terms: ['"acme"', '"kubernetes"'])
      assert_equal [], fts.find(terms: ['"initech"', '"invoice"'])
    end

    it 'is empty when nothing matches' do
      populate
      assert_equal [], fts.find(terms: ['"kubernetes"'])
    end

    it 'refuses an empty term list rather than matching everything' do
      populate
      assert_raises(ArgumentError) { fts.find(terms: []) }
    end
  end

  describe 'stemming' do
    # Index side splits the compound, query side does not — the shape a
    # compound-splitting stemmer answers.
    let(:stemmer) do
      Object.new.tap do |s|
        s.define_singleton_method(:id) { 'test' }
        s.define_singleton_method(:close) { nil }
        s.define_singleton_method(:stems) { |w| { 'kadulla' => ['katu'] }.fetch(w, [w]) }
        s.define_singleton_method(:index_stems) do |w|
          { 'kadulla' => ['katu'], 'tietokoneella' => %w[tietokone tieto kone] }.fetch(w, [w])
        end
      end
    end
    let(:fts) { Pikuri::Rag::Backend::Fts5.new(stemmer: stemmer) }

    before do
      fts.upsert(chunks: [chunk('fi.md:0', 'fi.md', 'Tietokoneella kadulla.')])
    end

    it 'indexes the index stems, and only them' do
      assert_equal [match('fi.md', [1])], fts.find(terms: ['"katu"'])
      assert_equal [match('fi.md', [1])], fts.find(terms: ['"kone"'])
      assert_equal [], fts.find(terms: ['"kadulla"'])
    end

    it 'still answers the original text' do
      assert_equal 'Tietokoneella kadulla.', fts.keyword_query(match: '"katu"', top_k: 1).first.chunk.text
    end

    it 'exposes the stemmer queries must use' do
      assert_same stemmer, fts.stemmer
    end
  end

  describe 'the store' do
    it 'defaults to an in-process index' do
      assert_equal ':memory:', fts.store
    end

    describe 'built with another stemmer or schema' do
      def stemmer(id)
        Object.new.tap do |s|
          s.define_singleton_method(:id) { id }
          s.define_singleton_method(:close) { nil }
          s.define_singleton_method(:index_stems) { |w| [w] }
        end
      end

      around do |example|
        Dir.mktmpdir do |dir|
          @path = File.join(dir, 'fts.sqlite3')
          @log = StringIO.new
          original_io = Pikuri.log_io
          Pikuri.log_io = @log
          example.run
        ensure
          Pikuri.log_io = original_io
        end
      end

      def reopen(id)
        fts = Pikuri::Rag::Backend::Fts5.new(store: @path, stemmer: stemmer(id))
        yield fts
      ensure
        fts&.close
      end

      it 'keeps an index opened with the same stemmer' do
        reopen('a') { |f| f.upsert(chunks: [chunk('acme.md:0', 'acme.md', 'Acme pricing.')]) }
        reopen('a') { |f| assert_equal 1, f.count }
        assert_empty @log.string
      end

      # Empty is Hybrid's cue to refill both stores; a stale index would
      # instead quietly answer nothing for every stemmed query.
      it 'empties an index built with another stemmer, and says so' do
        reopen('a') { |f| f.upsert(chunks: [chunk('acme.md:0', 'acme.md', 'Acme pricing.')]) }
        reopen('b') do |f|
          assert_equal 0, f.count
          f.upsert(chunks: [chunk('acme.md:0', 'acme.md', 'Acme pricing.')])
        end
        reopen('b') { |f| assert_equal 1, f.count }
        assert_includes @log.string, 'stemmer a, opened with schema 3, stemmer b'
      end

      it 'empties an index from before the schema was versioned' do
        db = SQLite3::Database.new(@path)
        db.execute(<<~SQL)
          CREATE VIRTUAL TABLE chunks USING fts5(
            id UNINDEXED, source UNINDEXED, hash UNINDEXED, text, tokenize='porter unicode61')
        SQL
        db.execute("INSERT INTO chunks VALUES ('acme.md:0', 'acme.md', 'h1', 'Acme pricing.')")
        db.close

        reopen('a') { |f| assert_equal 0, f.count }
        assert_includes @log.string, 'built with an unversioned schema'
      end

      it 'logs nothing for a brand-new index' do
        reopen('a') { |f| assert_equal 0, f.count }
        assert_empty @log.string
      end
    end

    it 'reloads a file-backed index without re-indexing' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'fts.sqlite3')
        first = Pikuri::Rag::Backend::Fts5.new(store: path)
        first.upsert(chunks: [chunk('acme.md:0', 'acme.md', 'Acme pricing.')])
        first.close

        second = Pikuri::Rag::Backend::Fts5.new(store: path)
        assert_equal path, second.store
        assert_equal [match('acme.md', [1])], second.find(terms: ['"pricing"'])
        second.close
      end
    end

    it 'waits for another connection holding the write lock instead of raising' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'fts.sqlite3')
        fts = Pikuri::Rag::Backend::Fts5.new(store: path)
        other = SQLite3::Database.new(path)
        other.execute('BEGIN IMMEDIATE')
        releaser = Thread.new do
          sleep 0.2
          other.execute('COMMIT')
        end

        fts.upsert(chunks: [chunk('acme.md:0', 'acme.md', 'Acme pricing.')])
        assert_equal 1, fts.count
      ensure
        releaser&.join
        other&.close
        fts&.close
      end
    end
  end
end
