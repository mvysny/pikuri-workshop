# frozen_string_literal: true

require 'json'
require 'tmpdir'

# Exercises the on-disk layout against a real temp directory, including the
# co-habitation with HistoryFile that the format rests on.
RSpec.describe Pikuri::Conversations::Store do
  around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) / 'conversations' and example.run } }

  let(:store) { described_class.new(root: @root, shell: 'pikuri-webui-chat') }
  let(:at) { Time.utc(2026, 8, 27, 12, 3, 51) }
  let(:empty) { Pikuri::Agent::History.new }
  let(:hello) do
    Pikuri::Agent::History.new(messages: [Pikuri::Agent::History::Message.new(id: Pikuri::Agent::History.mint_id, role: 'user', content: 'hello')])
  end

  # The connection an example that is not about connections saves on. #save
  # takes it per call — the store holds no model of its own.
  connection = { model: 'qwen3.6', server: 'http://localhost:8080/v1' }.freeze

  def save(entry, history = empty, **overrides)
    store.save(entry, history, model: 'qwen3.6', server: 'http://localhost:8080/v1', **overrides)
  end

  def meta_of(entry)
    JSON.parse((entry.dir / 'meta.json').read)
  end

  # Stands in for HistoryFile.save: records how the directory looked when it
  # was called — every ordering guarantee #save makes is "before the history"
  # — and writes nothing. Pass a block to fail the way a full disk would.
  def spy_on_history_save(&fail_with)
    seen = {}
    original = Pikuri::Conversations::HistoryFile.method(:save)
    Pikuri::Conversations::HistoryFile.define_singleton_method(:save) do |_history, dir|
      seen[:dir] = dir
      seen[:mode] = (dir.stat.mode & 0o777).to_s(8)
      seen[:envelope_existed] = (dir / 'meta.json').exist?
      fail_with&.call
      dir
    end
    @restore_history_save = original
    seen
  end

  after do
    next unless @restore_history_save

    original = @restore_history_save
    Pikuri::Conversations::HistoryFile.define_singleton_method(:save) { |*args| original.call(*args) }
  end

  context 'construction' do
    it 'creates the root 0700, so it is there from boot' do
      store
      assert @root.directory?
      assert_equal '700', (@root.stat.mode & 0o777).to_s(8)
      assert_empty @root.children
    end
  end

  context '#create' do
    it 'mints a lexically sortable UTC id with a random suffix' do
      entry = store.create(at: at)
      assert_match(/\A2026-08-27T12-03-51Z-[0-9a-f]{4}\z/, entry.id)
      assert_equal @root / entry.id, entry.dir
    end

    it 'titles the conversation by local start time' do
      assert_equal at.localtime.strftime('%Y-%m-%d %H:%M'), store.create(at: at).title
    end

    it 'keeps two conversations minted in the same second apart' do
      refute_equal store.create(at: at).id, store.create(at: at).id
    end

    it 'creates no directory — that waits for something to put in it' do
      refute store.create(at: at).dir.exist?
    end

    it "leaves the caller its own Time, unconverted" do
      given = Time.utc(2026, 8, 27, 12, 3, 51)
      store.create(at: given)
      assert given.utc?, "create converted the caller's Time in place"
    end

    it 'starts on no connection at all unless one is given' do
      entry = store.create(at: at)
      assert_nil entry.model
      assert_nil entry.server
      assert_equal({}, entry.extra)
    end

    it 'carries a given connection' do
      entry = store.create(at: at, **connection)
      assert_equal 'qwen3.6', entry.model
      assert_equal 'http://localhost:8080/v1', entry.server
    end
  end

  context '#save' do
    it 'hands the history the conversation directory, already created 0700' do
      entry = store.create(at: at)
      seen = spy_on_history_save
      save(entry)

      assert_equal entry.dir, seen[:dir]
      assert_equal '700', seen[:mode], 'the history was written into a wider-mode directory'
      assert_equal '700', (entry.dir.stat.mode & 0o777).to_s(8)
    end

    it 'tightens a directory an earlier write left with the default mode' do
      entry = store.create(at: at)
      FileUtils.mkdir_p(entry.dir.to_path, mode: 0o755)
      save(entry)
      assert_equal '700', (entry.dir.stat.mode & 0o777).to_s(8)
    end

    it 'writes the history beside the envelope, loadable back' do
      entry = store.create(at: at)
      save(entry, hello)

      assert_equal %w[history.json meta.json], entry.dir.children.map { |c| c.basename.to_s }.sort
      assert_equal hello, store.history(store.find(entry.id))
    end

    it 'writes the envelope' do
      entry = store.create(at: at)
      save(entry, updated_at: Time.utc(2026, 8, 27, 12, 41, 2))

      assert_equal(
        {
          'schema' => 1,
          'id' => entry.id,
          'title' => entry.title,
          'created_at' => '2026-08-27T12:03:51Z',
          'updated_at' => '2026-08-27T12:41:02Z',
          'shell' => 'pikuri-webui-chat',
          'model' => 'qwen3.6',
          'server' => 'http://localhost:8080/v1'
        },
        meta_of(entry)
      )
    end

    it 'writes extra keys beside its own, and lists them back' do
      entry = store.create(at: at)
      save(entry, extra: { 'last_question' => 'avocado?', asked_at: '2026-08-27T12:04:00Z' })

      assert_equal 'avocado?', meta_of(entry)['last_question']
      assert_equal({ 'last_question' => 'avocado?', 'asked_at' => '2026-08-27T12:04:00Z' }, store.list.first.extra)
    end

    it "refuses an extra key that would overwrite one of the store's own" do
      entry = store.create(at: at)
      e = assert_raises(ArgumentError) { save(entry, extra: { title: 'sneaky' }) }
      assert_match(/title/, e.message)
      refute entry.dir.exist?
    end

    it 'commits the envelope only after the history has landed' do
      entry = store.create(at: at)
      seen = spy_on_history_save
      save(entry)

      refute seen[:envelope_existed], 'meta.json was written before the history'
      assert (entry.dir / 'meta.json').file?
    end

    it 'leaves a failed history write unlisted rather than half-committed' do
      entry = store.create(at: at)
      spy_on_history_save { raise Errno::ENOSPC }
      assert_raises(Errno::ENOSPC) { save(entry) }

      refute (entry.dir / 'meta.json').exist?
      assert_empty store.list
    end

    it 'rewrites in place on the next save, leaving no temp file behind' do
      entry = store.create(at: at)
      save(entry, updated_at: Time.utc(2026, 8, 27, 12, 10, 0))
      save(entry, updated_at: Time.utc(2026, 8, 27, 13, 20, 0))

      assert_equal '2026-08-27T13:20:00Z', meta_of(entry).fetch('updated_at')
      assert_equal %w[history.json meta.json], entry.dir.children.map { |c| c.basename.to_s }.sort
    end
  end

  context '#list' do
    # Commits a conversation, then optionally rewrites keys of its envelope.
    def commit(at, **overrides)
      entry = store.create(at: at)
      save(entry)
      unless overrides.empty?
        meta = meta_of(entry).merge(overrides.transform_keys(&:to_s))
        (entry.dir / 'meta.json').write(JSON.generate(meta))
      end
      entry
    end

    it 'is empty on a fresh root' do
      assert_empty store.list
    end

    it 'orders by start time, newest first' do
      older = commit(Time.utc(2026, 8, 26, 9, 14, 2))
      newer = commit(Time.utc(2026, 8, 27, 12, 3, 51))
      assert_equal [newer.id, older.id], store.list.map(&:id)
    end

    it 'keeps a conversation in place however late it is written to' do
      first = commit(Time.utc(2026, 8, 26, 9, 14, 2))
      second = commit(Time.utc(2026, 8, 27, 12, 3, 51))
      save(first, updated_at: Time.utc(2026, 8, 28, 18, 0, 0))
      assert_equal [second.id, first.id], store.list.map(&:id)
    end

    it 'reads the title from meta.json' do
      commit(at, 'title' => 'Debugging the SSE drain')
      row = store.list.first
      assert_equal 'Debugging the SSE drain', row.title
      assert row.supported
    end

    it 'dates a conversation by its id, not by its envelope' do
      commit(at, 'created_at' => '1999-01-01T00:00:00Z')
      assert_equal at, store.list.first.created_at
    end

    it 'skips a directory with no meta.json — a save interrupted mid-commit' do
      FileUtils.mkdir_p((@root / store.create(at: at).id).to_path)
      assert_empty store.list
    end

    it 'skips directories that are not ours' do
      FileUtils.mkdir_p((@root / 'attachments').to_path)
      (@root / 'attachments' / 'meta.json').write('{"schema":1}')
      assert_empty store.list
    end

    it 'skips a directory shaped like an id but not a date' do
      store
      FileUtils.mkdir_p((@root / '2026-99-99T99-99-99Z-abcd').to_path)
      (@root / '2026-99-99T99-99-99Z-abcd' / 'meta.json').write('{"schema":1}')
      assert_empty store.list
    end

    it 'skips plain files sitting in the root' do
      store
      (@root / 'notes.txt').write('scratch')
      assert_empty store.list
    end

    it 'lists a conversation from a newer schema as unsupported' do
      entry = commit(at, 'schema' => 99, 'title' => 'from the future', 'last_question' => 'x')
      row = store.list.first
      refute row.supported
      assert_equal entry.title, row.title, 'trusted a title from a schema it cannot read'
      assert_equal({}, row.extra, 'trusted an extra key from a schema it cannot read')
    end

    it 'lists a conversation with a corrupt envelope as unsupported' do
      entry = commit(at)
      (entry.dir / 'meta.json').write('{"schema": 1, "title": ')
      refute store.list.first.supported
    end

    it 'falls back to the stamp title when meta.json has none' do
      entry = commit(at, 'title' => nil)
      row = store.list.first
      assert row.supported
      assert_equal entry.title, row.title
    end

    it 'reads the saved connection back out of the envelope' do
      commit(at)
      row = store.list.first
      assert_equal 'qwen3.6', row.model
      assert_equal 'http://localhost:8080/v1', row.server
    end

    # Half a pair is worse than none: an envelope written before its writer
    # recorded a server holds the *boot* model, which matching on alone is the
    # conflation the pair exists to prevent.
    it 'takes half a connection, or a non-string one, as no connection' do
      commit(at, 'server' => nil)
      assert_nil store.list.first.model

      commit(Time.utc(2026, 8, 28, 9, 0, 0), 'model' => 42)
      assert store.list.first.supported
      assert_nil store.list.first.model
      assert_nil store.list.first.server
    end

    it 'points each row at its directory' do
      entry = commit(at)
      assert_equal entry.dir, store.list.first.dir
    end
  end

  context '#find' do
    it 'resolves a listed conversation' do
      entry = store.create(at: at)
      save(entry)
      assert_equal entry.id, store.find(entry.id).id
    end

    it 'answers nil for anything not in the listing, path-shaped ids included' do
      save(store.create(at: at))
      assert_nil store.find('2026-08-27T12-03-51Z-ffff')
      assert_nil store.find('../../etc')
      assert_nil store.find('')
    end
  end

  context '#history' do
    it 'answers nil for a conversation minted and never saved' do
      assert_nil store.history(store.create(at: at))
    end

    it 'answers nil for a save interrupted before its envelope, as #list skips it' do
      entry = store.create(at: at)
      entry.dir.mkpath
      Pikuri::Conversations::HistoryFile.save(hello, entry.dir)

      assert_nil store.history(entry)
    end

    it 'refuses a committed conversation that lost its history.json' do
      entry = store.create(at: at)
      save(entry, hello)
      (entry.dir / 'history.json').delete

      assert_raises(Pikuri::Conversations::HistoryFile::Error) { store.history(store.find(entry.id)) }
    end

    it 'refuses a broken history.json loudly' do
      entry = store.create(at: at)
      save(entry, hello)
      (entry.dir / 'history.json').write('{ not json')

      assert_raises(Pikuri::Conversations::HistoryFile::Error) { store.history(store.find(entry.id)) }
    end
  end

  context '#stamp_titled?' do
    it 'is true for a conversation nothing has named' do
      assert store.stamp_titled?(store.create(at: at))
    end

    it 'is false once something has' do
      refute store.stamp_titled?(store.retitle(store.create(at: at), 'Named Thing'))
    end
  end

  context '#retitle' do
    it 'rewrites the envelope in place, keeping every other key' do
      entry = store.create(at: at)
      save(entry, extra: { 'last_question' => 'avocado?' })
      before = meta_of(entry)

      renamed = store.retitle(entry, 'Sinatra Versus Roda For SSE')

      assert_equal 'Sinatra Versus Roda For SSE', meta_of(entry)['title']
      assert_equal 'Sinatra Versus Roda For SSE', renamed.title
      assert_equal before.except('title'), meta_of(entry).except('title')
    end

    it 'leaves the directory where it is — a title is never part of a path' do
      entry = store.create(at: at)
      save(entry)
      assert_equal entry.dir, store.retitle(entry, 'Named Thing').dir
      assert entry.dir.directory?
    end

    # A conversation minted but not yet saved: the rename lives in the returned
    # value, and the save that first writes the envelope carries it.
    it 'writes nothing when there is no envelope yet' do
      entry = store.create(at: at)
      renamed = store.retitle(entry, 'Named Thing')

      assert_equal 'Named Thing', renamed.title
      refute entry.dir.exist?
      save(renamed)
      assert_equal 'Named Thing', meta_of(renamed)['title']
    end

    it 'writes nothing over an envelope this reader cannot stand behind' do
      entry = store.create(at: at)
      save(entry)
      (entry.dir / 'meta.json').write('{ this is not json')

      assert_equal 'Named Thing', store.retitle(entry, 'Named Thing').title
      assert_equal '{ this is not json', (entry.dir / 'meta.json').read
    end

    it 'survives a round trip through the listing' do
      entry = store.create(at: at)
      save(entry)
      store.retitle(entry, 'Named Thing')

      assert_equal ['Named Thing'], store.list.map(&:title)
    end
  end

  context '#delete' do
    let(:png) { "\x89PNG\r\n\x1A\n#{'pixels' * 10}".b }

    # A committed conversation with an attachment beside the history, which
    # delete has to take with it.
    def saved(at: self.at)
      entry = store.create(at: at)
      image = Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: png)
      save(entry, Pikuri::Agent::History.new(messages: [
                                      Pikuri::Agent::History::Message.new(id: Pikuri::Agent::History.mint_id, role: 'user',
                                                                 content: '', attachments: [image])
                                    ]))
      entry
    end

    it 'removes the folder, the history and the attachments with it' do
      entry = saved
      assert (entry.dir / 'attachments').directory?
      assert store.delete(entry)
      refute entry.dir.exist?
    end

    it 'drops the conversation from the listing' do
      kept = saved(at: at - 3600)
      store.delete(saved)
      assert_equal [kept.id], store.list.map(&:id)
    end

    it 'deletes a conversation it could not read, which is how a broken one gets pruned' do
      entry = saved
      (entry.dir / 'meta.json').write('{ not json')
      refute store.find(entry.id).supported
      assert store.delete(store.find(entry.id))
      assert_empty store.list
    end

    it 'reports nothing removed for a conversation minted but never saved' do
      refute store.delete(store.create(at: at))
    end

    it 'refuses an entry from outside the root rather than removing it' do
      outside = described_class::Entry.new(id: 'elsewhere', dir: @root.parent / 'elsewhere', title: 'x',
                                           created_at: at, supported: true)
      (@root.parent / 'elsewhere').mkpath
      assert_raises(ArgumentError) { store.delete(outside) }
      assert (@root.parent / 'elsewhere').directory?, 'delete escaped the root'
    end
  end

  context '#stash and #attachment' do
    let(:png) { "\x89PNG\r\n\x1A\n#{'pixels' * 10}".b }
    let(:image) { Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: png) }
    let(:name) { Pikuri::Conversations::HistoryFile.stored_name(image) }

    it 'writes each image under the name it is served by, in a private folder' do
      entry = store.create(at: at)

      store.stash(entry, [image])

      assert_equal png, store.attachment(entry, name).binread
      assert_equal 0o700, entry.dir.stat.mode & 0o777
      # A folder holding only images is not a committed conversation yet.
      assert_empty store.list
    end

    # What lets the stash replace the save's own write rather than double it:
    # the turn-end save finds the file under the name it would have chosen.
    it 'agrees with HistoryFile.save on the name' do
      entry = store.create(at: at)
      store.stash(entry, [image])
      history = Pikuri::Agent::History.new(messages: [
                                    Pikuri::Agent::History::Message.new(id: Pikuri::Agent::History.mint_id, role: 'user',
                                                               content: '', attachments: [image])
                                  ])

      save(entry, history)

      assert_equal([name], (entry.dir / 'attachments').children.map { |c| c.basename.to_s })
      assert_equal [image], store.history(entry).messages.first.attachments
    end

    it 'finds nothing for a name that is not in the folder' do
      entry = store.create(at: at)
      store.stash(entry, [image])

      assert_nil store.attachment(entry, 'other.png')
      assert_nil store.attachment(entry, "../#{name}")
      assert_nil store.attachment(store.create(at: at), name)
    end
  end
end
