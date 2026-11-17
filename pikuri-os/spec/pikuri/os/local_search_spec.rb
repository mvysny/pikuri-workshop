# frozen_string_literal: true

# Parsing and argv, with Subprocess.spawn stubbed (CI has no localsearch).
# The real index is exercised by local_search_index_spec.rb.
RSpec.describe Pikuri::Os::LocalSearch do
  # Stubs spawn to answer +output+ and records each argv in +calls+.
  def stub_spawn(success:, output:, calls: [])
    original = Pikuri::Subprocess.method(:spawn)
    result_struct = Struct.new(:status, :output) do
      def wait; self; end
    end
    status_struct = Struct.new(:success?, :exitstatus)
    Pikuri::Subprocess.define_singleton_method(:spawn) do |*args, **_kwargs|
      calls << args
      result_struct.new(status_struct.new(success, success ? 0 : 1), output)
    end
    original
  end

  def restore_spawn(original)
    Pikuri::Subprocess.define_singleton_method(:spawn, original)
  end

  def with_spawn(**kwargs)
    original = stub_spawn(**kwargs)
    yield
  ensure
    restore_spawn(original)
  end

  # The +--arg name:type:value+ pairs of one recorded argv.
  def args_of(argv)
    argv.each_cons(2).select { |flag, _| flag == '--arg' }.to_h { |_, arg| arg.split(':', 2) }
  end

  describe '.file_uri' do
    it 'escapes the way GLib does: reserved sub-delims stay, the rest is %XX per byte' do
      assert_equal "file:///a/b%20c/%C3%BC%23%3B%3F%25,&=+$!'()*~@:/x.txt",
                   described_class.file_uri("/a/b c/ü#;?%,&=+$!'()*~@:/x.txt")
    end
  end

  describe '.parse_rows' do
    it 'decodes the marked cells of each row, commas and newlines included' do
      raw = "Results:\n  v:file%3A%2F%2F%2Fa%2Fb%2520c.txt, v:one%2C%20two%0Athree\n\n"
      assert_equal [['file:///a/b%20c.txt', "one, two\nthree"]], described_class.parse_rows(raw)
    end

    it 'turns an unbound cell into nil' do
      assert_equal [['x', nil]], described_class.parse_rows("Results:\n  v:x, (null)\n")
    end

    it 'skips the unmarked header and empty-result lines, whatever their language' do
      assert_empty described_class.parse_rows("Výsledky:\n  Žádné\n")
    end
  end

  describe '.search' do
    it 'maps rows to paths and one-line snippets' do
      out = "Results:\n  v:file%3A%2F%2F%2Fa%2Fb%2520c.txt, v:alpha%0A%20beta\n  v:file%3A%2F%2F%2Fd.txt, v:\n"
      with_spawn(success: true, output: out) do
        assert_equal [{ path: '/a/b c.txt', snippet: 'alpha beta' }, { path: '/d.txt', snippet: nil }],
                     described_class.search(query: 'beta', limit: 5)
      end
    end

    it 'scopes to a folder by its escaped URI, with a trailing slash' do
      calls = []
      with_spawn(success: true, output: "Results:\n  None\n", calls: calls) do
        described_class.search(query: 'tax', limit: 7, folder: '/home/u/My Docs')
      end
      args = args_of(calls.first)
      assert_equal 's:file:///home/u/My%20Docs/', args['prefix']
      assert_equal 's:tax', args['query']
      assert_equal 'i:7', args['limit']
      assert_equal %w[tinysparql query -b org.freedesktop.LocalSearch3], calls.first.first(4)
    end

    it 'searches every local file without a folder' do
      calls = []
      with_spawn(success: true, output: '', calls: calls) { described_class.search(query: 'x', limit: 1) }
      assert_equal 's:file:///', args_of(calls.first)['prefix']
    end

    it 'raises CommandError with the CLI message on a non-zero exit' do
      with_spawn(success: false, output: 'Could not run query') do
        err = assert_raises(Pikuri::Os::LocalSearch::CommandError) { described_class.search(query: 'x', limit: 5) }
        assert_equal 'Could not run query', err.message
      end
    end
  end

  describe '.read_text' do
    it 'returns the decoded stored text, asking by escaped URI' do
      calls = []
      with_spawn(success: true, output: "Results:\n  v:doc%0Abody\n", calls: calls) do
        assert_equal "doc\nbody", described_class.read_text('/a/b c.pdf')
      end
      assert_equal 's:file:///a/b%20c.pdf', args_of(calls.first)['url']
    end

    it 'returns nil when the index holds no text' do
      with_spawn(success: true, output: "Results:\n  None\n") { assert_nil described_class.read_text('/x') }
    end

    it 'returns nil on a non-zero exit' do
      with_spawn(success: false, output: 'boom') { assert_nil described_class.read_text('/x') }
    end
  end

  describe '.available?' do
    it 'is true when the index answers' do
      with_spawn(success: true, output: "Results:\n  true\n") { assert described_class.available? }
    end

    it 'is false (no raise) when the index does not answer' do
      with_spawn(success: false, output: 'not provided by any .service files') { refute described_class.available? }
    end

    it 'is false (no raise) when tinysparql is missing' do
      original = Pikuri::Subprocess.method(:spawn)
      Pikuri::Subprocess.define_singleton_method(:spawn) { |*_a, **_k| raise Errno::ENOENT, 'tinysparql' }
      begin
        refute described_class.available?
      ensure
        restore_spawn(original)
      end
    end
  end

  describe '.check_binaries!' do
    it 'names both packages and what the probe saw' do
      with_spawn(success: false, output: 'not provided by any .service files') do
        err = assert_raises(RuntimeError) { described_class.check_binaries! }
        assert_includes err.message, "'localsearch'"
        assert_includes err.message, "'tinysparql'"
        assert_includes err.message, 'not provided by any .service files'
      end
    end
  end
end
