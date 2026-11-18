# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'pathname'

describe Pikuri::VectorDb::Watcher do
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-watcher-')).realpath }
  after { FileUtils.rm_rf(root) }

  # A recording stand-in for {Corpus}: exposes #root / #source and
  # records the per-file calls the Watcher makes, per the project's
  # define_singleton_method stubbing convention (no rspec-mocks).
  def fake_corpus(source: root, plan: { reindex: [], remove: [] }, reindex_raises: nil, excluded: [])
    the_root = root # capture as a local; bare `root` would resolve to obj.root and recurse
    calls = []
    prefixes = []
    obj = Object.new
    obj.define_singleton_method(:root)    { Pathname.new(the_root) }
    obj.define_singleton_method(:source)  { Pathname.new(source) }
    obj.define_singleton_method(:reconcile_plan) { plan }
    obj.define_singleton_method(:excluded?) { |p| excluded.any? { |ex| p.to_s.start_with?(ex) } }
    obj.define_singleton_method(:reindex_file!) do |p, progress: nil|
      calls << [:reindex, p.to_s]
      prefixes << progress
      raise reindex_raises if reindex_raises
    end
    obj.define_singleton_method(:prefixes) { prefixes }
    obj.define_singleton_method(:remove_file!) { |p| calls << [:remove, p.to_s] }
    obj.define_singleton_method(:calls) { calls }
    obj
  end

  # A fake listen listener + factory. The factory captures the dir +
  # callback and records start/stop so lifecycle wiring is assertable
  # without a real inotify watch.
  def fake_listen
    listener = Object.new
    events = []
    listener.define_singleton_method(:start) { events << :start }
    listener.define_singleton_method(:stop)  { events << :stop }
    listener.define_singleton_method(:events) { events }
    factory = lambda do |dir, &blk|
      listener.define_singleton_method(:dir) { dir }
      listener.define_singleton_method(:callback) { blk }
      listener
    end
    [factory, listener]
  end

  def under(rel)
    root.join(rel).to_s
  end

  describe '#process_event + #drain!' do
    it 'reindexes modified and added files, removes deleted ones' do
      idx = fake_corpus
      w = described_class.new(corpus: idx)

      w.process_event([under('a.md')], [under('b.md')], [under('c.md')])
      w.drain!

      assert_equal [
        [:reindex, under('a.md')],
        [:reindex, under('b.md')],
        [:remove,  under('c.md')]
      ], idx.calls
    end

    it 'collapses repeated events for one path to the latest intent' do
      idx = fake_corpus
      w = described_class.new(corpus: idx)

      w.process_event([under('a.md')], [], [])   # reindex a.md
      w.process_event([], [], [under('a.md')])   # then a.md deleted
      w.drain!

      assert_equal [[:remove, under('a.md')]], idx.calls
    end

    it 'ignores denylisted dirs, dot-entries, and paths outside the root' do
      idx = fake_corpus
      w = described_class.new(corpus: idx)

      w.process_event(
        [under('node_modules/x.js'), under('.env'), under('sub/.hidden/y.md'), '/tmp/elsewhere/z.md'],
        [], []
      )
      w.drain!

      assert_equal [], idx.calls
    end

    it 'ignores paths the corpus excludes' do
      idx = fake_corpus(excluded: [under('Books')])
      w = described_class.new(corpus: idx)

      w.process_event([under('Books/novel.pdf'), under('notes.md')], [], [])
      w.drain!

      assert_equal [[:reindex, under('notes.md')]], idx.calls
    end

    it 'indexes a nested non-denylisted file' do
      idx = fake_corpus
      w = described_class.new(corpus: idx)

      w.process_event([under('notes/cooking/risotto.md')], [], [])
      w.drain!

      assert_equal [[:reindex, under('notes/cooking/risotto.md')]], idx.calls
    end

    context 'with a single-file source' do
      it 'acts only on that exact file, not siblings in the same dir' do
        file = root.join('notes.md')
        idx = fake_corpus(source: file)
        w = described_class.new(corpus: idx)

        w.process_event([file.to_s, under('other.md')], [], [])
        w.drain!

        assert_equal [[:reindex, file.to_s]], idx.calls
      end
    end

    it 'drops a symlinked file and paths under a symlinked directory' do
      # Targets live outside root so a reachable path proves a link was
      # traversed, not an independent in-tree file.
      outside = Pathname.new(Dir.mktmpdir('pikuri-watcher-outside-')).realpath
      File.write(outside + 'target.md', 'x')
      FileUtils.mkdir_p(outside + 'sub')
      File.write(outside + 'sub' + 'deep.md', 'y')

      File.write(root + 'real.md', 'r')
      File.symlink((outside + 'target.md').to_s, (root + 'link.md').to_s)
      File.symlink(outside.to_s, (root + 'linked_dir').to_s)

      idx = fake_corpus
      w = described_class.new(corpus: idx)

      w.process_event(
        [under('real.md'), under('link.md'), under('linked_dir/sub/deep.md')],
        [], []
      )
      w.drain!

      # Only the real file; the symlinked leaf and the file reached
      # through the symlinked dir are both dropped.
      assert_equal [[:reindex, under('real.md')]], idx.calls
    ensure
      FileUtils.rm_rf(outside) if outside
    end

    context 'with a single-file source that is itself a symlink' do
      it 'drops the reindex event' do
        outside = Pathname.new(Dir.mktmpdir('pikuri-watcher-outside-')).realpath
        File.write(outside + 'target.md', 'x')
        link = root + 'notes.md'
        File.symlink((outside + 'target.md').to_s, link.to_s)

        idx = fake_corpus(source: link)
        w = described_class.new(corpus: idx)

        w.process_event([link.to_s], [], [])
        w.drain!

        assert_equal [], idx.calls
      ensure
        FileUtils.rm_rf(outside) if outside
      end
    end

    it 'swallows a per-file failure and keeps draining' do
      idx = fake_corpus(reindex_raises: RuntimeError.new('embedder 503'))
      w = described_class.new(corpus: idx)

      w.process_event([under('a.md')], [], [under('b.md')])
      w.drain! # must not raise despite reindex_file! blowing up

      assert_equal [[:reindex, under('a.md')], [:remove, under('b.md')]], idx.calls
    end
  end

  describe 'boot reconcile sweep' do
    it 'enqueues the plan returned by Corpus#reconcile_plan' do
      plan = { reindex: [root.join('a.md')], remove: [root.join('gone.md')] }
      idx = fake_corpus(plan: plan)
      w = described_class.new(corpus: idx)

      w.send(:enqueue_plan)
      w.drain!

      assert_equal [
        [:reindex, root.join('a.md').to_s],
        [:remove,  root.join('gone.md').to_s]
      ], idx.calls
    end

    it 'numbers the sweep\'s files and leaves live events unnumbered' do
      plan = { reindex: [root.join('a.md'), root.join('b.md')], remove: [] }
      idx = fake_corpus(plan: plan)
      w = described_class.new(corpus: idx)

      w.send(:enqueue_plan)
      w.drain!
      w.process_event([under('c.md')], [], [])
      w.drain!

      assert_equal ['[1/2] ', '[2/2] ', nil], idx.prefixes
    end

    it 'logs and survives a reconcile sweep that raises' do
      idx = fake_corpus
      idx.define_singleton_method(:reconcile_plan) { raise 'backend down' }
      w = described_class.new(corpus: idx)

      w.send(:enqueue_plan) # must not raise
      w.drain!

      assert_equal [], idx.calls
    end
  end

  describe 'lifecycle (#start / #close)' do
    it 'subscribes the listener and tears it down cleanly' do
      factory, listener = fake_listen
      idx = fake_corpus
      w = described_class.new(corpus: idx, listen_factory: factory)

      w.start
      assert_equal root.to_s, listener.dir          # watches the corpus root
      assert_includes listener.events, :start

      w.close
      assert_includes listener.events, :stop
    end

    it 'is idempotent on close' do
      factory, = fake_listen
      w = described_class.new(corpus: fake_corpus, listen_factory: factory)
      w.start
      w.close
      w.close # no raise, no hang
    end

    it 'rejects a double start' do
      factory, = fake_listen
      w = described_class.new(corpus: fake_corpus, listen_factory: factory)
      w.start
      assert_raises(RuntimeError) { w.start }
      w.close
    end

    it 'routes the real listen callback through process_event' do
      factory, listener = fake_listen
      idx = fake_corpus
      w = described_class.new(corpus: idx, listen_factory: factory)
      w.start
      w.close # stop the worker so we drive draining ourselves

      # Fire the captured callback as listen would, then drain.
      listener.callback.call([under('a.md')], [], [])
      w.drain!

      assert_equal [[:reindex, under('a.md')]], idx.calls
    end
  end

  # End-to-end through a real Corpus + InMemory backend (fakes only
  # for the embedder/chunker, mirroring corpus_spec) — proves the
  # Watcher's events actually mutate the index, not just a stub.
  describe 'integration with a real Corpus + InMemory backend' do
    let(:backend) { Pikuri::VectorDb::Backend::InMemory.new }

    let(:real_corpus) do
      tokenizer = Object.new
      def tokenizer.count(text) = text.split.length
      chunker = Pikuri::VectorDb::Chunker::FixedWindow.new(size: 1, tokenizer: tokenizer)
      embedder = Object.new
      def embedder.embed(texts) = texts.map { |t| [t.length.to_f, 0.5, 0.5] }
      Pikuri::VectorDb::Corpus.new(
        backend: backend, source: root.to_s, embedder: embedder, chunker: chunker
      )
    end

    def write(rel, content)
      path = root.join(rel)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, content)
      path
    end

    it 'indexes a new file and removes a deleted one via events' do
      a = write('a.md', 'one two three')
      w = described_class.new(corpus: real_corpus)

      w.process_event([], [a.to_s], [])
      w.drain!
      assert_equal 3, backend.count

      FileUtils.rm(a)
      w.process_event([], [], [a.to_s])
      w.drain!
      assert_equal 0, backend.count
    end

    it 'replaces a changed file without orphan chunks' do
      a = write('a.md', 'one two three four')
      w = described_class.new(corpus: real_corpus)
      w.process_event([], [a.to_s], [])
      w.drain!
      assert_equal 4, backend.count

      File.write(a, 'just two')
      w.process_event([a.to_s], [], [])
      w.drain!
      assert_equal 2, backend.count # shrunk cleanly, no leftovers
    end

    it 'reconciles pre-existing on-disk files on the boot sweep' do
      write('a.md', 'alpha beta')
      write('b.md', 'gamma')
      w = described_class.new(corpus: real_corpus)

      w.send(:enqueue_plan) # the boot sweep against an empty backend
      w.drain!

      assert_equal 3, backend.count # 2 + 1 chunks
    end
  end
end
