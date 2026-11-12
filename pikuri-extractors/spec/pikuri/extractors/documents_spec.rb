# frozen_string_literal: true

require 'stringio'

RSpec.describe Pikuri::Extractors::Documents do
  # Fresh instance per example so the memoized environment probes
  # (docker? / image built / host CLIs) can't leak between examples.
  let(:documents) { described_class.new }

  # Stubbing the subprocess seam, docker_stub-shaped but covering both
  # front doors: +spawn_plans+ feeds the probe/build calls
  # (`docker info`, `docker image inspect`, `pandoc --version`, ...),
  # +run_plans+ feeds the conversions. A spawn plan is
  # +[exit_status, output]+ or +:enoent+; a run plan is
  # +[exit_status, stderr, payload]+ — +payload+ is written to the
  # +stdout:+ file, exactly what a real converter would do.
  let(:spawn_calls) { [] }
  let(:spawn_plans) { [] }
  let(:run_calls)   { [] }
  let(:run_plans)   { [] }

  before do
    status_class = Struct.new(:exitstatus) do
      def success?
        exitstatus.zero?
      end
    end
    result_class = Struct.new(:output, :status)

    spawn_calls_ref = spawn_calls
    spawn_plans_ref = spawn_plans
    run_calls_ref   = run_calls
    run_plans_ref   = run_plans

    fake_proc_class = Class.new do
      define_method(:initialize) { |exit_status, output| @exit_status = exit_status; @output = output }
      define_method(:wait) { result_class.new(@output, status_class.new(@exit_status)) }
    end

    Pikuri::Subprocess.singleton_class.send(:alias_method, :__orig_spawn, :spawn)
    Pikuri::Subprocess.define_singleton_method(:spawn) do |*argv, **_kw|
      spawn_calls_ref << argv
      plan = spawn_plans_ref.shift
      raise "unplanned Subprocess.spawn: #{argv.inspect}" if plan.nil?
      raise Errno::ENOENT, argv.first if plan == :enoent

      exit_status, output = plan
      fake_proc_class.new(exit_status, output)
    end

    Pikuri::Subprocess.singleton_class.send(:alias_method, :__orig_run, :run)
    Pikuri::Subprocess.define_singleton_method(:run) do |*argv, stdin_data:, stdout:, chdir:, env: {}| # rubocop:disable Lint/UnusedBlockArgument
      # Mirror production: an IO source is streamed (here: read), a
      # String written as-is. Record both the raw source (for the
      # no-buffering identity assertion) and the bytes.
      run_calls_ref << { argv: argv, stdin_source: stdin_data,
                         stdin: stdin_data.respond_to?(:read) ? stdin_data.read : stdin_data }
      plan = run_plans_ref.shift
      raise "unplanned Subprocess.run: #{argv.inspect}" if plan.nil?

      exit_status, stderr, payload = plan
      stdout.write(payload || '')
      result_class.new(stderr || '', status_class.new(exit_status))
    end
  end

  after do
    Pikuri::Subprocess.singleton_class.send(:alias_method, :spawn, :__orig_spawn)
    Pikuri::Subprocess.singleton_class.send(:remove_method, :__orig_spawn)
    Pikuri::Subprocess.singleton_class.send(:alias_method, :run, :__orig_run)
    Pikuri::Subprocess.singleton_class.send(:remove_method, :__orig_run)
    Pikuri::Extractor.registry.delete(documents)
  end

  # Realistic leading bytes: ODF/EPUB mandate the uncompressed
  # `mimetype` first zip entry (30-byte local file header, then the
  # name, then the stored content); OOXML leads with
  # `[Content_Types].xml` and the entry names follow in cleartext.
  let(:odt_sample)  { "PK\x03\x04#{"\x00" * 26}mimetypeapplication/vnd.oasis.opendocument.textPK\x03\x04rest".b }
  let(:epub_sample) { "PK\x03\x04#{"\x00" * 26}mimetypeapplication/epub+zipPK\x03\x04rest".b }
  let(:docx_sample) { "PK\x03\x04#{"\x00" * 26}[Content_Types].xml#{'x' * 40}word/document.xml".b }
  let(:pptx_sample) { "PK\x03\x04#{"\x00" * 26}[Content_Types].xml#{'x' * 40}ppt/presentation.xml".b }
  let(:xlsx_sample) { "PK\x03\x04#{"\x00" * 26}[Content_Types].xml#{'x' * 40}xl/workbook.xml".b }
  let(:rtf_sample)  { '{\rtf1\ansi Hello.}'.b }
  let(:pdf_sample)  { "%PDF-1.4\nfake pdf body".b }
  let(:ole2_sample) { "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1#{"\x00" * 64}".b }

  # Spawn plans for the happy container arm: `docker info` answers,
  # the image is already built.
  def plan_container!
    spawn_plans.concat([[0, ''], [0, '']])
  end

  # Spawn plans for "no docker at all".
  def plan_no_docker!
    spawn_plans << :enoent
  end

  describe '#matches?' do
    it 'claims every known content-type, sample notwithstanding' do
      described_class::CONTENT_TYPES.each_key do |ct|
        assert documents.matches?(sample: +'', content_type: ct), "expected to claim #{ct}"
      end
    end

    it 'claims ODT / EPUB / OOXML / RTF / PDF by byte sniff with no content-type' do
      [odt_sample, epub_sample, docx_sample, pptx_sample, xlsx_sample, rtf_sample, pdf_sample].each do |sample|
        assert documents.matches?(sample: sample, content_type: nil)
      end
    end

    it 'rejects plain text, plain zips, OLE2, and OOXML zips with no recognisable entry names' do
      refute documents.matches?(sample: "just some text\n", content_type: nil)
      refute documents.matches?(sample: "PK\x03\x04#{"\x00" * 60}".b, content_type: nil)
      refute documents.matches?(sample: ole2_sample, content_type: nil)
      refute documents.matches?(sample: "PK\x03\x04#{"\x00" * 26}[Content_Types].xml#{"\x00" * 40}".b,
                                content_type: nil)
      refute documents.matches?(sample: +'', content_type: 'text/plain')
    end
  end

  describe '#register' do
    it 'inserts before the terminal Passthrough entry' do
      documents.register
      registry = Pikuri::Extractor.registry
      assert_equal Pikuri::Extractor::Passthrough, registry.last
      assert_equal documents, registry[-2]
    end

    it 'is idempotent and returns self' do
      assert_equal documents, documents.register
      before_count = Pikuri::Extractor.registry.length
      documents.register
      assert_equal before_count, Pikuri::Extractor.registry.length
    end
  end

  describe '#extract — container arm' do
    it 'pipes the bytes through the networkless one-shot container and returns its stdout' do
      plan_container!
      run_plans << [0, '', "# Title\n\nbody\n"]

      markdown = documents.extract(StringIO.new(docx_sample))

      assert_equal "# Title\n\nbody\n", markdown
      call = run_calls.fetch(0)
      assert_equal 'timeout', call[:argv].first # bounded, per the Subprocess convention
      assert_includes call[:argv], 'docker'
      assert_includes call[:argv], '--network=none'
      assert_includes call[:argv], '--read-only'
      assert_includes call[:argv], described_class::IMAGE
      assert_equal 'docx', call[:argv].last
      assert_equal docx_sample, call[:stdin]
    end

    it 'streams the source io into the converter rather than buffering it as a String' do
      plan_container!
      run_plans << [0, '', 'md']
      io = StringIO.new(docx_sample)

      documents.extract(io)

      call = run_calls.fetch(0)
      assert_same io, call[:stdin_source] # the io itself, rewound after the sniff
      assert_equal docx_sample, call[:stdin]
    end

    it 'builds the image first when it is missing' do
      spawn_plans.concat([[0, ''], [1, ''], [0, 'built']]) # info ok, inspect missing, build ok
      run_plans << [0, '', 'md']

      documents.extract(StringIO.new(odt_sample))

      build = spawn_calls.find { |argv| argv[1] == 'build' }
      assert_equal ['docker', 'build', '-t', described_class::IMAGE, described_class::DOCKER_DIR], build
    end

    it 'probes docker and the image once across conversions' do
      plan_container!
      run_plans.concat([[0, '', 'one'], [0, '', 'two']])

      documents.extract(StringIO.new(odt_sample))
      documents.extract(StringIO.new(docx_sample))

      assert_equal 2, spawn_calls.length # info + inspect, never re-probed
    end

    it 'falls back to markitdown auto-detection when the sniff is blind (legacy XLS via content-type)' do
      plan_container!
      run_plans << [0, '', '|a|b|']

      documents.extract(StringIO.new(ole2_sample))

      assert_equal described_class::AUTO, run_calls.fetch(0)[:argv].last
    end

    it 'maps a failed conversion to Extractor::Error carrying the stderr tail' do
      plan_container!
      run_plans << [2, "pandoc: Could not read ODT\nmore detail", nil]

      error = assert_raises(Pikuri::Extractor::Error) { documents.extract(StringIO.new(odt_sample)) }
      assert_includes error.message, 'exit 2'
      assert_includes error.message, 'Could not read ODT'
    end

    it 'raises on a failed image build' do
      spawn_plans.concat([[0, ''], [1, ''], [1, 'pip blew up']])

      error = assert_raises(Pikuri::Extractor::Error) { documents.extract(StringIO.new(odt_sample)) }
      assert_includes error.message, 'docker build'
      assert_includes error.message, 'pip blew up'
    end
  end

  describe '#extract — host arm' do
    it 'uses host pandoc when docker is absent' do
      plan_no_docker!
      spawn_plans << [0, 'pandoc 3.x'] # pandoc --version
      run_plans << [0, '', 'converted']

      assert_equal 'converted', documents.extract(StringIO.new(odt_sample))
      argv = run_calls.fetch(0)[:argv]
      assert_includes argv, 'pandoc'
      assert_equal %w[-f odt -t gfm], argv[argv.index('-f'), 4]
    end

    it 'falls through to host markitdown for formats pandoc also serves' do
      plan_no_docker!
      spawn_plans << :enoent      # pandoc --version → absent
      spawn_plans << [0, '0.1.6'] # markitdown --version
      run_plans << [0, '', 'converted']

      documents.extract(StringIO.new(docx_sample))

      argv = run_calls.fetch(0)[:argv]
      assert_includes argv, 'markitdown'
      assert_equal %w[-x docx], argv[argv.index('-x'), 2]
    end

    it 'raises a recoverable error naming the install options when no arm is available' do
      plan_no_docker!
      spawn_plans << :enoent # pandoc --version → absent; odt has no other host converter

      error = assert_raises(Pikuri::Extractor::Error) { documents.extract(StringIO.new(odt_sample)) }
      assert_includes error.message, 'install docker'
      assert_includes error.message, 'pandoc'
    end
  end

  describe '#extract — the PDF arm' do
    it 'dispatches the pdf format tag and rebuilds --- Page N --- markers from \f separators' do
      plan_container!
      # pdftotext-shaped stdout: page 1 (two lines), page 2 blank,
      # page 3 — a \f terminating each page.
      run_plans << [0, '', "Alpha one\nAlpha two\n\f\fGamma text\n\f"]

      markdown = documents.extract(StringIO.new(pdf_sample))

      assert_equal "--- Page 1 ---\nAlpha one\nAlpha two\n--- Page 3 ---\nGamma text", markdown
      call = run_calls.fetch(0)
      assert_equal 'pdf', call[:argv].last
      assert_equal pdf_sample, call[:stdin]
    end

    it 'extracts a text-free (scanned) PDF to the empty String' do
      plan_container!
      run_plans << [0, '', "\f\f"]

      assert_equal '', documents.extract(StringIO.new(pdf_sample))
    end

    it 'streams marker-headed lines through extract_lines' do
      plan_container!
      run_plans << [0, '', "one\ntwo\n\fthree\n\f"]

      lines = documents.extract_lines(StringIO.new(pdf_sample)).to_a

      assert_equal ['--- Page 1 ---', 'one', 'two', '--- Page 2 ---', 'three'], lines
    end

    it 'uses host pdftotext when docker is absent, probing with -v (poppler rejects --version)' do
      plan_no_docker!
      spawn_plans << [0, 'pdftotext version 26.01.0'] # pdftotext -v
      run_plans << [0, '', "text\n\f"]

      assert_equal "--- Page 1 ---\ntext", documents.extract(StringIO.new(pdf_sample))
      assert_includes spawn_calls, %w[pdftotext -v]
      assert_equal %w[pdftotext -q -enc UTF-8 - -], run_calls.fetch(0)[:argv] - ['timeout', '--signal=TERM', '--kill-after=5s', described_class::CONVERT_TIMEOUT]
    end
  end

  describe '#extract_lines' do
    it 'converts once on first consumption and yields chomped lines off the Tempfile' do
      plan_container!
      run_plans << [0, '', "alpha\nbeta\ngamma\n"]

      lines = documents.extract_lines(StringIO.new(odt_sample))
      assert_empty run_calls # lazy: nothing converted yet

      assert_equal %w[alpha beta gamma], lines.to_a
      assert_equal 1, run_calls.length
    end
  end

  describe '#ensure_image!' do
    it 'raises when docker is unavailable' do
      plan_no_docker!
      assert_raises(Pikuri::Extractor::Error) { documents.ensure_image! }
    end

    it 'builds the missing image' do
      spawn_plans.concat([[0, ''], [1, ''], [0, 'built']])
      documents.ensure_image!
      assert(spawn_calls.any? { |argv| argv[1] == 'build' })
    end
  end

  describe 'through the registry' do
    it 'routes Extractor.extract for a local ODT (nil content-type) end to end' do
      documents.register
      plan_container!
      run_plans << [0, '', "# Doc\n\ntext\n"]

      assert_equal "# Doc\n\ntext\n", Pikuri::Extractor.extract(StringIO.new(odt_sample), content_type: nil)
    end

    it 'windows extract_paged through the lazy line stream with the :document kind' do
      documents.register
      plan_container!
      run_plans << [0, '', "one\ntwo\nthree\nfour\n"]

      page = Pikuri::Extractor.extract_paged(StringIO.new(docx_sample), content_type: nil,
                                                                        offset: 2, limit: 2)
      assert_equal %w[two three], page.lines
      assert_equal 2, page.start_line
      assert_equal :document, page.kind
      assert page.more
    end
  end
end
