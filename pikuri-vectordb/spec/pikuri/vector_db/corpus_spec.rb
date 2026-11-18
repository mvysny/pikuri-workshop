# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'

describe Pikuri::VectorDb::Corpus do
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-vectordb-corpus-')).realpath }
  let(:backend) { Pikuri::VectorDb::Backend::InMemory.new }

  # Deterministic fakes. The chunker is a one-word FixedWindow (one
  # chunk per word); the embedder returns a 3-dim vector whose first
  # component is the text length, second/third are constants —
  # ensures vectors are distinct per chunk while staying easy
  # to read in failure messages.
  let(:fake_chunker) do
    tokenizer = Object.new
    def tokenizer.count(text) = text.split.length
    Pikuri::VectorDb::Chunker::FixedWindow.new(size: 1, tokenizer: tokenizer)
  end

  let(:fake_embedder) do
    obj = Object.new
    def obj.embed(texts)
      texts.map { |t| [t.length.to_f, 0.5, 0.5] }
    end
    obj
  end

  def write(rel, content)
    path = root + rel
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
    path
  end

  def build_corpus(source: root.to_s, exclude: [])
    Pikuri::VectorDb::Corpus.new(
      backend: backend, source: source,
      embedder: fake_embedder, chunker: fake_chunker, exclude: exclude
    )
  end

  after { FileUtils.rm_rf(root) }

  describe '#index_all!' do
    it 'walks a directory, indexes files, returns total chunks' do
      write('a.md', 'one two three')
      write('b.md', 'four five')

      total = build_corpus.index_all!

      assert_equal 5, total
      assert_equal 5, backend.count
    end

    it 'sets Chunk.source to the path relative to the source root' do
      write('notes/cooking/risotto.md', 'rice butter wine')

      build_corpus.index_all!

      hits = backend.query(vector: [3.0, 0.5, 0.5], top_k: 5)
      sources = hits.map { |r| r.chunk.source }.uniq
      assert_equal ['notes/cooking/risotto.md'], sources
    end

    it 'formats Chunk.id as "source:index"' do
      write('doc.md', 'alpha beta gamma')

      build_corpus.index_all!

      hits = backend.query(vector: [5.0, 0.5, 0.5], top_k: 5).sort_by { |h| h.chunk.id }
      assert_equal %w[doc.md:0 doc.md:1 doc.md:2], hits.map { |h| h.chunk.id }
    end

    it 'stores the chunk ordinal in metadata' do
      write('doc.md', 'alpha beta gamma')

      build_corpus.index_all!

      hits = backend.query(vector: [5.0, 0.5, 0.5], top_k: 5).sort_by { |h| h.chunk.metadata[:ordinal] }
      assert_equal [0, 1, 2], hits.map { |h| h.chunk.metadata[:ordinal] }
    end

    it "stores each chunk's line range in metadata" do
      write('doc.md', "alpha\n\nbeta gamma\r\ndelta")

      build_corpus.index_all!

      hits = backend.query(vector: [5.0, 0.5, 0.5], top_k: 5).sort_by { |h| h.chunk.metadata[:ordinal] }
      assert_equal [['alpha', 1, 1], ['beta', 3, 3], ['gamma', 3, 3], ['delta', 4, 4]],
                   hits.map { |h| [h.chunk.text, h.chunk.metadata[:first_line], h.chunk.metadata[:last_line]] }
    end

    it 'skips dot-files and dot-directories' do
      write('visible.md', 'foo bar')
      write('.env', 'SECRET=hunter2')
      write('.obsidian/config.json', '{}')

      total = build_corpus.index_all!

      assert_equal 2, total
      sources = backend.query(vector: [3.0, 0.5, 0.5], top_k: 10).map { |r| r.chunk.source }.uniq
      assert_equal ['visible.md'], sources
    end

    it 'skips DENYLIST directories (.git, node_modules, target, ...)' do
      write('doc.md', 'kept')
      write('node_modules/foo/bar.js', 'should not')
      write('target/build.log', 'should not')
      write('venv/lib/python3.10/site-packages/foo.py', 'should not')

      total = build_corpus.index_all!

      assert_equal 1, total
    end

    it 'skips excluded folders, matched by whole path components' do
      write('Books/novel.txt', 'should not')
      write('Library/Books/deep.txt', 'should not')
      write('Bookshelf.md', 'kept')

      total = build_corpus(exclude: ['Books', root.join('Library/Books').to_s]).index_all!

      assert_equal 1, total
    end

    it 'refuses an exclude outside the source root' do
      assert_raises(ArgumentError) { build_corpus(exclude: ['../elsewhere']) }
      assert_raises(ArgumentError) { build_corpus(exclude: ['/somewhere/else']) }
    end

    it 'skips a symlinked file and never descends a symlinked directory' do
      write('real.md', 'kept content')
      # Targets live outside root so the walk can only reach them via
      # the links — proving the links themselves are skipped.
      outside = Pathname.new(Dir.mktmpdir('pikuri-vectordb-outside-'))
      File.write(outside + 'target.md', 'off tree file')
      File.write(outside + 'secret.md', 'off tree secret')
      File.symlink((outside + 'target.md').to_s, (root + 'link.md').to_s)
      File.symlink(outside.to_s, (root + 'linked_dir').to_s)

      total = build_corpus.index_all!

      # Only real.md ("kept content" → 2 chunks); the symlinked file
      # and everything under the symlinked dir are skipped.
      assert_equal 2, total
      sources = backend.query(vector: [4.0, 0.5, 0.5], top_k: 10).map { |r| r.chunk.source }.uniq
      assert_equal ['real.md'], sources
    ensure
      FileUtils.rm_rf(outside) if outside
    end

    it 'WARNs and skips images / binary files via FileType refusal' do
      write('readable.md', 'kept content')
      # PNG magic — caught by FileType.read_as_text and surfaced as ArgumentError
      File.binwrite(root + 'photo.png', "\x89PNG\r\n\x1a\n".b + ('x' * 32).b)

      total = build_corpus.index_all!

      assert_equal 2, total # "kept" + "content"
      sources = backend.query(vector: [4.0, 0.5, 0.5], top_k: 10).map { |r| r.chunk.source }.uniq
      assert_equal ['readable.md'], sources
    end

    it 'WARNs and skips files with no extractable text' do
      write('empty.md', '')
      write('present.md', 'real content')

      total = build_corpus.index_all!

      assert_equal 2, total # "real" + "content"
    end

    it 'accepts a source that points at a single file' do
      write('docs/b.md', 'two three')
      corpus = build_corpus(source: (root + 'docs/b.md').to_s)

      total = corpus.index_all!

      assert_equal 2, total # "two" + "three"
      # Single-file source uses the parent dir as the root, so
      # +Chunk.source+ is the file basename.
      sources = backend.query(vector: [3.0, 0.5, 0.5], top_k: 10).map { |r| r.chunk.source }.uniq
      assert_equal ['b.md'], sources
    end

    it 'WARNs when the source path does not exist' do
      corpus = build_corpus(source: (root + 'phantom').to_s)

      total = corpus.index_all!

      assert_equal 0, total
    end

    it 'returns 0 when no indexable files are found' do
      total = build_corpus.index_all!
      assert_equal 0, total
    end

    it 'visits files in deterministic (sorted) order' do
      write('z.md', 'last')
      write('a.md', 'first')
      write('m.md', 'middle')

      build_corpus.index_all!

      ids = backend.query(vector: [4.0, 0.5, 0.5], top_k: 10).map { |h| h.chunk.id }.sort
      # Sources sorted alphabetically: a, m, z. Each has one chunk (one word) so id is "name.md:0".
      assert_equal ['a.md:0', 'm.md:0', 'z.md:0'], ids
    end
  end

  describe '#reindex!' do
    it 'nukes the backend then indexes everything' do
      write('a.md', 'foo bar')
      corpus = build_corpus
      corpus.index_all!
      assert_equal 2, backend.count

      # Add a second file after the first indexing and reindex.
      write('b.md', 'baz')
      corpus.reindex!

      # If reindex weren't nuking first, we'd see 2 (from first) + 3 (from second) = 5.
      assert_equal 3, backend.count
    end
  end

  describe '#index_if_empty!' do
    it 'runs index_all! when the backend is empty' do
      write('a.md', 'word')

      total = build_corpus.index_if_empty!

      assert_equal 1, total
    end

    it 'skips when the backend already has entries' do
      # Pre-populate the backend so its count is positive
      chunk = Pikuri::VectorDb::Chunk.new(id: 'preexisting:0', source: 'preexisting', text: 'old', metadata: {})
      backend.upsert(chunks: [chunk], vectors: [[1.0, 0.0, 0.0]])
      write('a.md', 'new content')

      total = build_corpus.index_if_empty!

      assert_equal 0, total
      assert_equal 1, backend.count # unchanged
    end
  end

  # Sources currently stored, for orphan/replacement assertions.
  def stored_sources
    backend.query(vector: [1.0, 0.5, 0.5], top_k: 100).map { |r| r.chunk.source }.uniq.sort
  end

  describe '#index_file (hash metadata)' do
    it 'stores the SHA-256 of the file bytes on every chunk' do
      path = write('doc.md', 'alpha beta gamma')
      expected = Digest::SHA256.hexdigest(File.binread(path))

      build_corpus.index_all!

      hashes = backend.query(vector: [5.0, 0.5, 0.5], top_k: 5).map { |r| r.chunk.metadata[:hash] }.uniq
      assert_equal [expected], hashes
    end
  end

  describe '#reindex_file!' do
    it 'indexes a single file and returns its chunk count' do
      path = write('a.md', 'one two three')

      total = build_corpus.reindex_file!(path)

      assert_equal 3, total
      assert_equal 3, backend.count
    end

    it 'replaces a shrunk file without leaving orphan chunks' do
      path = write('a.md', 'one two three four')
      corpus = build_corpus
      corpus.index_all!
      assert_equal 4, backend.count

      File.write(path, 'one two') # 4 chunks -> 2
      corpus.reindex_file!(path)

      assert_equal 2, backend.count # :2 and :3 are gone, not orphaned
      assert_equal ['a.md'], stored_sources
    end

    it 'treats a file emptied of text as a removal' do
      path = write('a.md', 'content here')
      corpus = build_corpus
      corpus.index_all!
      assert_equal 2, backend.count

      File.write(path, '')
      total = corpus.reindex_file!(path)

      assert_equal 0, total
      assert_equal 0, backend.count
    end

    it 'treats a file that became unreadable (binary) as a removal' do
      path = write('a.md', 'readable text')
      corpus = build_corpus
      corpus.index_all!
      assert_equal 2, backend.count

      File.binwrite(path, "\x89PNG\r\n\x1a\n".b + ('x' * 32).b)
      total = corpus.reindex_file!(path)

      assert_equal 0, total
      assert_equal 0, backend.count
    end

    it 'leaves prior chunks intact when the embedder fails (embed-before-delete)' do
      path = write('a.md', 'one two three')
      corpus = build_corpus
      corpus.index_all!
      assert_equal 3, backend.count

      # Swap in an embedder that raises, then change the file and reindex.
      boom = Object.new
      def boom.embed(_texts) = raise(RuntimeError, 'embedder 503')
      corpus.instance_variable_set(:@embedder, boom)
      File.write(path, 'changed content here now')

      assert_raises(RuntimeError) { corpus.reindex_file!(path) }
      assert_equal 3, backend.count # untouched — old chunks survive
    end
  end

  describe '#remove_file!' do
    it 'drops a file\'s chunks from the index' do
      a = write('a.md', 'one two')
      write('b.md', 'three')
      corpus = build_corpus
      corpus.index_all!
      assert_equal 3, backend.count

      corpus.remove_file!(a)

      assert_equal 1, backend.count
      assert_equal ['b.md'], stored_sources
    end

    it 'is a no-op for a source that is not indexed' do
      write('a.md', 'one')
      corpus = build_corpus
      corpus.index_all!

      corpus.remove_file!(root + 'never-indexed.md')

      assert_equal 1, backend.count
    end
  end

  describe '#reconcile_plan' do
    def plan_sources(plan)
      {
        reindex: plan[:reindex].map { |p| p.relative_path_from(root).to_s }.sort,
        remove:  plan[:remove].map  { |p| p.relative_path_from(root).to_s }.sort
      }
    end

    it 'reports every file as reindex against an empty backend' do
      write('a.md', 'one')
      write('b.md', 'two')

      plan = plan_sources(build_corpus.reconcile_plan)

      assert_equal %w[a.md b.md], plan[:reindex]
      assert_equal [], plan[:remove]
    end

    it 'reports nothing for an unchanged, already-indexed corpus' do
      write('a.md', 'one two')
      write('b.md', 'three')
      corpus = build_corpus
      corpus.index_all!

      plan = plan_sources(corpus.reconcile_plan)

      assert_equal [], plan[:reindex]
      assert_equal [], plan[:remove]
    end

    it 'reports a changed file for reindex (content hash differs)' do
      a = write('a.md', 'original')
      write('b.md', 'stable')
      corpus = build_corpus
      corpus.index_all!

      File.write(a, 'edited content')
      plan = plan_sources(corpus.reconcile_plan)

      assert_equal ['a.md'], plan[:reindex]
      assert_equal [], plan[:remove]
    end

    it 'reports a file gone from disk for removal' do
      a = write('a.md', 'one')
      write('b.md', 'two')
      corpus = build_corpus
      corpus.index_all!

      FileUtils.rm(a)
      plan = plan_sources(corpus.reconcile_plan)

      assert_equal [], plan[:reindex]
      assert_equal ['a.md'], plan[:remove]
    end
  end

  describe '#close' do
    it 'closes the backend it owns' do
      closed = false
      backend.define_singleton_method(:close) { closed = true }
      build_corpus.close
      assert closed
    end
  end

  describe '#root' do
    it 'is the directory itself for a directory source' do
      assert_equal root, build_corpus.root
    end

    it 'is the parent for a single-file source' do
      path = write('docs/b.md', 'x')
      corpus = build_corpus(source: path.to_s)
      assert_equal (root + 'docs'), corpus.root
    end
  end
end
