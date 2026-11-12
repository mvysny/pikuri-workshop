# frozen_string_literal: true

LOCALSEARCH_AVAILABLE = begin
  Pikuri::Subprocess.spawn('localsearch', '--version', chdir: '/').wait.status.success?
rescue Errno::ENOENT
  false
end unless defined?(LOCALSEARCH_AVAILABLE)

RSpec.describe Pikuri::Os::FileindexSearch do
  # Stub the LocalSearch backend so these run without the binary.
  def stub_backend_search(&block)
    original = Pikuri::Os::LocalSearch.method(:search)
    Pikuri::Os::LocalSearch.define_singleton_method(:search, &block)
    original
  end

  def restore_backend_search(original)
    Pikuri::Os::LocalSearch.define_singleton_method(:search, original)
  end

  # The default backend under test; the module methods are stubbed above.
  def backend = Pikuri::Os::LocalSearch

  describe '.search' do
    it 'rejects an empty query without touching the backend' do
      assert_equal 'Error: empty query.', described_class.search(query: '   ', backend: backend).to_s
    end

    it 'renders path + snippet per hit and a one-match-per-file disclaimer' do
      original = stub_backend_search do |query:, limit:|
        [{ path: '/home/u/a.pdf', snippet: 'alpha beta' },
         { path: '/home/u/b.txt', snippet: nil }]
      end
      begin
        out = described_class.search(query: 'beta', limit: 10, backend: backend).to_s
        assert_includes out, "/home/u/a.pdf\n  alpha beta"
        assert_includes out, '/home/u/b.txt'
        assert_includes out, 'one match shown per file'
        assert_includes out, 'Found 2 files'
      ensure
        restore_backend_search(original)
      end
    end

    it 'reports no matches on an empty result' do
      original = stub_backend_search { |**| [] }
      begin
        assert_includes described_class.search(query: 'nonesuch', backend: backend).to_s,
                        "No files found matching 'nonesuch'"
      ensure
        restore_backend_search(original)
      end
    end

    it 'renders a backend CommandError as an Error observation, prefixed with its label' do
      original = stub_backend_search { |**| raise Pikuri::Os::LocalSearch::CommandError, 'bad query' }
      begin
        assert_equal 'Error: localsearch: bad query', described_class.search(query: 'x', backend: backend).to_s
      ensure
        restore_backend_search(original)
      end
    end

    it 'caps an oversized backend CommandError at MAX_BYTES' do
      huge = 'x' * (described_class::MAX_BYTES * 3)
      original = stub_backend_search { |**| raise Pikuri::Os::LocalSearch::CommandError, huge }
      begin
        result = described_class.search(query: 'x', backend: backend).to_s
        assert result.start_with?('Error: localsearch:'), "got #{result[0, 40].inspect}"
        assert_includes result, 'bytes omitted'
        assert result.bytesize <= described_class::MAX_BYTES + 200,
               "error not capped: #{result.bytesize} bytes"
      ensure
        restore_backend_search(original)
      end
    end

    it 'clamps limit to MAX_LIMIT' do
      seen = nil
      original = stub_backend_search do |query:, limit:|
        seen = limit
        []
      end
      begin
        described_class.search(query: 'x', limit: 9999, backend: backend)
        assert_equal described_class::MAX_LIMIT, seen
      ensure
        restore_backend_search(original)
      end
    end
  end

  it 'appends the backend limitations to the tool description' do
    fake = Module.new do
      def self.check_binaries! = nil
      def self.limitations = 'BACKEND BLIND SPOTS HERE'
    end
    tool = described_class.new(backend: fake)
    assert_includes tool.description, 'BACKEND BLIND SPOTS HERE'
  end

  if LOCALSEARCH_AVAILABLE
    it 'constructs as a Pikuri::Tool named fileindex_search' do
      tool = described_class.new(backend: backend)
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'fileindex_search', tool.name
    end
  else
    it 'raises a clear error at construction when the backend binary is missing' do
      err = assert_raises(RuntimeError) { described_class.new(backend: backend) }
      assert_includes err.message, 'localsearch'
    end
  end
end
