# frozen_string_literal: true

require 'base64'
require 'tmpdir'

RSpec.describe Pikuri::Os::Recoll do
  # Stub Subprocess.spawn deterministically (CI has no recoll).
  def stub_spawn(success:, output:)
    original = Pikuri::Subprocess.method(:spawn)
    result_struct = Struct.new(:status, :output) do
      def wait; self; end
    end
    status_struct = Struct.new(:success?, :exitstatus)
    Pikuri::Subprocess.define_singleton_method(:spawn) do |*_args, **_kwargs|
      result_struct.new(status_struct.new(success, success ? 0 : 1), output)
    end
    original
  end

  def restore_spawn(original)
    Pikuri::Subprocess.define_singleton_method(:spawn, original)
  end

  # One recollq -F 'url abstract dbytes' data line: three base64 tokens,
  # an empty field printing as an empty one.
  def field_line(url, abstract, dbytes = '0')
    "#{[url, abstract, dbytes].map { |field| Base64.strict_encode64(field) }.join(' ')} \n"
  end

  describe '.parse_search_output' do
    it 'decodes base64 url + abstract, keeps spaces, de-dupes by path' do
      raw = +"Recoll query: Query(brown)\n2 results\n"
      raw << field_line('file:///home/u/My Notes/todo.txt', 'a brown fox...', '308')
      raw << field_line('file:///home/u/report.pdf', '')
      raw << field_line('file:///home/u/My Notes/todo.txt', 'dup')
      hits = described_class.parse_search_output(raw)
      assert_equal ['/home/u/My Notes/todo.txt', '/home/u/report.pdf'], hits.map { |h| h[:path] }
      assert_equal 'a brown fox...', hits[0][:snippet]
      assert_equal 308, hits[0][:text_size]
      assert_nil hits[1][:snippet]
      assert_nil hits[1][:text_size]
    end

    it 'skips the recollq banner lines (not valid base64 for a file:// url)' do
      assert_empty described_class.parse_search_output("Recoll query: Query(x)\n0 results\n")
    end
  end

  describe '.parse_topdirs' do
    it 'reads topdirs from the global section, folding backslash continuations and quotes' do
      raw = "topdirs = ~/Documents ~/src \\\n    /data/shared \"~/My Papers\"\n[~/src]\ntopdirs = /ignored\n"
      assert_equal ['~/Documents', '~/src', '/data/shared', '~/My Papers'],
                   described_class.parse_topdirs(raw)
    end

    it 'ignores comments and takes the last global assignment' do
      raw = "# a comment\ntopdirs = /a\ntopdirs = /b\n"
      assert_equal ['/b'], described_class.parse_topdirs(raw)
    end

    it 'returns [] when topdirs is absent' do
      assert_empty described_class.parse_topdirs("indexstemminglanguages = english\n")
    end
  end

  describe '.indexed_dirs' do
    it 'expands ~ and $VARs to absolute paths' do
      Dir.mktmpdir do |confdir|
        File.write(File.join(confdir, 'recoll.conf'), "topdirs = ~/docs $HOME/x\n")
        original = ENV['RECOLL_CONFDIR']
        ENV['RECOLL_CONFDIR'] = confdir
        begin
          assert_equal ["#{Dir.home}/docs", "#{Dir.home}/x"], described_class.indexed_dirs
        ensure
          ENV['RECOLL_CONFDIR'] = original
        end
      end
    end

    it 'defaults to the home dir when the config is absent' do
      original = ENV['RECOLL_CONFDIR']
      ENV['RECOLL_CONFDIR'] = '/no/such/confdir'
      begin
        assert_equal [Dir.home], described_class.indexed_dirs
      ensure
        ENV['RECOLL_CONFDIR'] = original
      end
    end
  end

  describe '.limitations' do
    it 'lists the indexed folders' do
      original = ENV['RECOLL_CONFDIR']
      ENV['RECOLL_CONFDIR'] = '/no/such/confdir'
      begin
        text = described_class.limitations
        assert_includes text, Dir.home
        assert_includes text, 'Only files under these folders are indexed'
      ensure
        ENV['RECOLL_CONFDIR'] = original
      end
    end
  end

  describe '.extract_dumped_text' do
    it 'returns the body of the result whose header url matches' do
      raw = "text/plain\t[file:///a/one.txt]\t[one.txt]\t3\tbytes\t\n" \
            "body of one\n" \
            "text/plain\t[file:///a/two.txt]\t[two.txt]\t3\tbytes\t\n" \
            "body of two\n"
      assert_equal 'body of two', described_class.extract_dumped_text(raw, '/a/two.txt')
    end

    it 'returns nil when no header matches' do
      raw = "text/plain\t[file:///a/one.txt]\t[one.txt]\t3\tbytes\t\nbody\n"
      assert_nil described_class.extract_dumped_text(raw, '/a/other.txt')
    end
  end

  describe '.search' do
    it 'returns parsed hits on success' do
      original = stub_spawn(success: true, output: "0 results\n#{field_line('file:///a/b.txt', 'snip')}")
      begin
        hits = described_class.search(query: 'foo', limit: 5)
        assert_equal '/a/b.txt', hits[0][:path]
        assert_equal 'snip', hits[0][:snippet]
      ensure
        restore_spawn(original)
      end
    end

    it 'scopes to a folder with a quoted dir: clause' do
      seen = nil
      original = Pikuri::Subprocess.method(:spawn)
      Pikuri::Subprocess.define_singleton_method(:spawn) do |*args, **_kwargs|
        seen = args.last
        raise Errno::EPIPE, 'stop here'
      end
      begin
        assert_raises(Errno::EPIPE) { described_class.search(query: 'tax', limit: 5, folder: '/home/u/My Docs') }
        assert_equal 'tax dir:"/home/u/My Docs"', seen
      ensure
        restore_spawn(original)
      end
    end

    it 'refuses a folder with a double quote, which recoll cannot quote' do
      err = assert_raises(Pikuri::Os::Recoll::CommandError) do
        described_class.search(query: 'tax', limit: 5, folder: '/home/u/say "hi"')
      end
      assert_includes err.message, 'double quote'
    end

    it 'raises CommandError on non-zero exit' do
      original = stub_spawn(success: false, output: 'boom')
      begin
        assert_raises(Pikuri::Os::Recoll::CommandError) { described_class.search(query: 'foo', limit: 5) }
      ensure
        restore_spawn(original)
      end
    end
  end

  describe '.read_text' do
    it 'returns the dumped text of the matching file' do
      dump = "text/plain\t[file://#{Dir.home}/x.txt]\t[x.txt]\t3\tbytes\t\ndoc body\n"
      original = stub_spawn(success: true, output: dump)
      begin
        assert_equal 'doc body', described_class.read_text("#{Dir.home}/x.txt")
      ensure
        restore_spawn(original)
      end
    end

    it 'returns nil on non-zero exit' do
      original = stub_spawn(success: false, output: '')
      begin
        assert_nil described_class.read_text('/x')
      ensure
        restore_spawn(original)
      end
    end
  end

  describe '.unavailable_reason' do
    # Spawn is stubbed; the confdir decides whether a never-built index is
    # told apart from a broken one.
    def reason_for(success: true, output: '', indexed: true)
      Dir.mktmpdir do |confdir|
        Dir.mkdir(File.join(confdir, 'xapiandb')) if indexed
        original_env = ENV['RECOLL_CONFDIR']
        ENV['RECOLL_CONFDIR'] = confdir
        original = stub_spawn(success: success, output: output)
        begin
          [described_class.unavailable_reason, confdir]
        ensure
          restore_spawn(original)
          ENV['RECOLL_CONFDIR'] = original_env
        end
      end
    end

    # recollq's -F url output: a banner, then one base64 token per hit.
    def url_output(*urls)
      "Recoll query: Query((<alldocuments> FILTER T*))\n#{urls.size} results (printing  1 max):\n" +
        urls.map { |url| "#{Base64.strict_encode64(url)} \n" }.join
    end

    it 'is nil when the index holds a document' do
      assert_nil reason_for(output: url_output('file:///home/u/docs/a.txt')).first
    end

    it 'says the index is empty, naming the config to fix, when it holds no document' do
      reason, confdir = reason_for(output: "Recoll query: Query((<alldocuments> FILTER T*))\n0 results\n")
      assert_includes reason, "the index in #{confdir} holds no documents"
      assert_includes reason, "#{confdir}/recoll.conf"
    end

    it 'says to run recollindex when no index was ever built' do
      reason, confdir = reason_for(success: false, indexed: false, output: 'Xapian index open error: …')
      assert_equal "no index in #{confdir} yet. Build one with `recollindex`.", reason
    end

    it "quotes recollq's last line when a built index doesn't answer" do
      reason, = reason_for(success: false, output: ":2:../rcldb/rcldb.cpp:241::Db::open: …\nXapian index open error: corrupt\n")
      assert_includes reason, "doesn't answer: Xapian index open error: corrupt"
    end

    it 'names the package when recollq is missing' do
      original = Pikuri::Subprocess.method(:spawn)
      Pikuri::Subprocess.define_singleton_method(:spawn) { |*_a, **_k| raise Errno::ENOENT, 'recollq' }
      begin
        assert_includes described_class.unavailable_reason, "Install the 'recoll' package"
      ensure
        restore_spawn(original)
      end
    end
  end
end
