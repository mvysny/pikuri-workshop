# frozen_string_literal: true

LOCALSEARCH_AVAILABLE = begin
  Pikuri::Subprocess.spawn('localsearch', '--version', chdir: '/').wait.status.success?
rescue Errno::ENOENT
  false
end unless defined?(LOCALSEARCH_AVAILABLE)

RSpec.describe Pikuri::Os::FileindexRead do
  def stub_backend_read(&block)
    original = Pikuri::Os::LocalSearch.method(:read_text)
    Pikuri::Os::LocalSearch.define_singleton_method(:read_text, &block)
    original
  end

  def restore_backend_read(original)
    Pikuri::Os::LocalSearch.define_singleton_method(:read_text, original)
  end

  # The default backend under test; the module methods are stubbed above.
  def backend = Pikuri::Os::LocalSearch

  describe '.read' do
    it 'rejects offset < 1 and limit < 1' do
      assert_includes described_class.read(path: '/x', offset: 0, limit: 10, backend: backend).to_s, 'offset must be >= 1'
      assert_includes described_class.read(path: '/x', offset: 1, limit: 0, backend: backend).to_s, 'limit must be >= 1'
    end

    it 'returns a not-in-index error when the backend has no text' do
      original = stub_backend_read { |_path| nil }
      begin
        out = described_class.read(path: '/home/u/missing.pdf', offset: 1, limit: 10, backend: backend).to_s
        assert_includes out, 'is not in the index'
        assert_includes out, 'use the read tool'
      ensure
        restore_backend_read(original)
      end
    end

    it 'renders cat-n with a paging trailer for a windowed read' do
      text = (1..30).map { |i| "line #{i}" }.join("\n")
      original = stub_backend_read { |_path| text }
      begin
        out = described_class.read(path: '/x', offset: 1, limit: 10, backend: backend).to_s
        assert_includes out, "     1\tline 1"
        assert_includes out, "    10\tline 10"
        refute_includes out, 'line 11'
        assert_includes out, 'Use offset=11 to continue'
      ensure
        restore_backend_read(original)
      end
    end

    it 'pages from an offset and reports end of file' do
      text = (1..5).map { |i| "line #{i}" }.join("\n")
      original = stub_backend_read { |_path| text }
      begin
        out = described_class.read(path: '/x', offset: 3, limit: 100, backend: backend).to_s
        assert_includes out, "     3\tline 3"
        assert_includes out, "     5\tline 5"
        refute_includes out, 'line 2'
        assert_includes out, 'End of file - total 5 lines'
      ensure
        restore_backend_read(original)
      end
    end

    it 'reports the byte cap on indexed text larger than one window' do
      original = stub_backend_read { |_path| "#{'x' * 1000}\n" * 200 }
      begin
        out = described_class.read(path: '/x', backend: backend).to_s
        assert_includes out, 'Output capped at 50 KB.'
        assert_match(/Use offset=\d+ to continue\./, out)
      ensure
        restore_backend_read(original)
      end
    end
  end

  if LOCALSEARCH_AVAILABLE
    it 'constructs as a Pikuri::Tool named fileindex_read' do
      tool = described_class.new(backend: backend)
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'fileindex_read', tool.name
    end
  else
    it 'raises a clear error at construction when the backend binary is missing' do
      err = assert_raises(RuntimeError) { described_class.new(backend: backend) }
      assert_includes err.message, 'localsearch'
    end
  end
end
