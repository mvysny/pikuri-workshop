# frozen_string_literal: true

require 'json'

RSpec.describe Pikuri::Os::LocalSearch do
  # Stub Subprocess.spawn deterministically (CI has no localsearch).
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

  describe '.parse_search_output' do
    it 'pairs each path with its ANSI-stripped snippet, percent-decoded and de-duped' do
      raw = "file:///home/u/Documents/report.pdf (urn:fileid:x:1)\n" \
            "  …physical or \e[0;1;39menvironmental\e[0m damage…\n" \
            "\n" \
            "file:///home/u/My%20Notes/todo.txt ((null))\n" \
            "  \e[0;1;39mEnvironmentalReverb\e[0m.java\n" \
            "\n" \
            "file:///home/u/Documents/report.pdf (urn:fileid:x:1)\n"
      hits = described_class.parse_search_output(raw)
      assert_equal ['/home/u/Documents/report.pdf', '/home/u/My Notes/todo.txt'],
                   hits.map { |h| h[:path] }
      assert_equal '…physical or environmental damage…', hits[0][:snippet]
      assert_equal 'EnvironmentalReverb.java', hits[1][:snippet]
    end

    it 'returns [] when there are no file:// lines' do
      assert_empty described_class.parse_search_output("no results\n")
    end

    it 'tolerates a hit with no snippet line' do
      hits = described_class.parse_search_output("file:///a/b.txt (urn:x)\n")
      assert_equal '/a/b.txt', hits[0][:path]
      assert_nil hits[0][:snippet]
    end
  end

  describe '.extract_plain_text' do
    it 'walks the nested @graph to find nie:plainTextContent' do
      json = JSON.generate('@graph' => [{ '@graph' => [{ 'nie:plainTextContent' => 'hello world' }] }])
      assert_equal 'hello world', described_class.extract_plain_text(json)
    end

    it 'returns nil when the key is absent' do
      assert_nil described_class.extract_plain_text('{"@graph":[{"a":1}]}')
    end

    it 'returns nil for non-JSON' do
      assert_nil described_class.extract_plain_text('not json at all')
    end

    it 'is lenient: recovers JSON after a stray diagnostic prefix' do
      assert_equal 'x', described_class.extract_plain_text("WARN: foo\n{\"nie:plainTextContent\":\"x\"}")
    end
  end

  describe '.search' do
    it 'returns parsed hits on success' do
      original = stub_spawn(success: true, output: "file:///a/b.txt (urn:x)\n  a \e[1msnip\e[0m b\n")
      begin
        hits = described_class.search(query: 'foo', limit: 5)
        assert_equal '/a/b.txt', hits[0][:path]
        assert_equal 'a snip b', hits[0][:snippet]
      ensure
        restore_spawn(original)
      end
    end

    it 'raises CommandError on non-zero exit' do
      original = stub_spawn(success: false, output: 'boom')
      begin
        assert_raises(Pikuri::Os::LocalSearch::CommandError) { described_class.search(query: 'foo', limit: 5) }
      ensure
        restore_spawn(original)
      end
    end
  end

  describe '.read_text' do
    it 'returns the extracted plain text on success' do
      json = JSON.generate('@graph' => [{ '@graph' => [{ 'nie:plainTextContent' => 'doc body' }] }])
      original = stub_spawn(success: true, output: json)
      begin
        assert_equal 'doc body', described_class.read_text('/x')
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

    it 'returns nil when there is no stored text' do
      original = stub_spawn(success: true, output: '{"@graph":[{"a":1}]}')
      begin
        assert_nil described_class.read_text('/x')
      ensure
        restore_spawn(original)
      end
    end
  end

  describe '.available?' do
    it 'is true when the version probe succeeds' do
      original = stub_spawn(success: true, output: 'LocalSearch 3.11.0')
      begin
        assert described_class.available?
      ensure
        restore_spawn(original)
      end
    end

    it 'is false (no raise) when the version probe fails' do
      original = stub_spawn(success: false, output: '')
      begin
        refute described_class.available?
      ensure
        restore_spawn(original)
      end
    end

    it 'is false (no raise) when the binary is missing' do
      original = Pikuri::Subprocess.method(:spawn)
      Pikuri::Subprocess.define_singleton_method(:spawn) { |*_a, **_k| raise Errno::ENOENT, 'localsearch' }
      begin
        refute described_class.available?
      ensure
        Pikuri::Subprocess.define_singleton_method(:spawn, original)
      end
    end
  end
end
