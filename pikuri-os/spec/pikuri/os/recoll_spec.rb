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

  # One recollq -F 'url abstract' data line: two base64 tokens.
  def field_line(url, abstract)
    "#{Base64.strict_encode64(url)} #{Base64.strict_encode64(abstract)}\n"
  end

  describe '.parse_search_output' do
    it 'decodes base64 url + abstract, keeps spaces, de-dupes by path' do
      raw = +"Recoll query: Query(brown)\n2 results\n"
      raw << field_line('file:///home/u/My Notes/todo.txt', 'a brown fox...')
      raw << field_line('file:///home/u/report.pdf', '')
      raw << field_line('file:///home/u/My Notes/todo.txt', 'dup')
      hits = described_class.parse_search_output(raw)
      assert_equal ['/home/u/My Notes/todo.txt', '/home/u/report.pdf'], hits.map { |h| h[:path] }
      assert_equal 'a brown fox...', hits[0][:snippet]
      assert_nil hits[1][:snippet]
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

  describe '.available?' do
    # available? requires BOTH a built index and the binary; drive it with a
    # confdir tmpdir that does/doesn't contain an xapiandb.
    def with_confdir(indexed:)
      Dir.mktmpdir do |confdir|
        Dir.mkdir(File.join(confdir, 'xapiandb')) if indexed
        original_env = ENV['RECOLL_CONFDIR']
        ENV['RECOLL_CONFDIR'] = confdir
        begin
          yield
        ensure
          ENV['RECOLL_CONFDIR'] = original_env
        end
      end
    end

    it 'is true when the index exists and recollq runs (ignoring its non-zero -h exit)' do
      with_confdir(indexed: true) do
        original = stub_spawn(success: false, output: 'Usage: recollq')
        begin
          assert described_class.available?
        ensure
          restore_spawn(original)
        end
      end
    end

    it 'is false when there is no built index, even though recollq is present' do
      with_confdir(indexed: false) do
        original = stub_spawn(success: false, output: 'Usage: recollq')
        begin
          refute described_class.available?
        ensure
          restore_spawn(original)
        end
      end
    end

    it 'is false (no raise) when the binary is missing' do
      with_confdir(indexed: true) do
        original = Pikuri::Subprocess.method(:spawn)
        Pikuri::Subprocess.define_singleton_method(:spawn) { |*_a, **_k| raise Errno::ENOENT, 'recollq' }
        begin
          refute described_class.available?
        ensure
          Pikuri::Subprocess.define_singleton_method(:spawn, original)
        end
      end
    end
  end
end
