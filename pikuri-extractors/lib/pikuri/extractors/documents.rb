# frozen_string_literal: true

require 'digest'
require 'tempfile'

module Pikuri
  module Extractors
    # Document extractor for the {Pikuri::Extractor} registry:
    # DOCX / ODT / XLSX / legacy XLS / PPTX / EPUB / RTF / PDF →
    # Markdown, by piping the document bytes through pandoc (ODF, RTF,
    # EPUB, DOCX), markitdown (OOXML spreadsheet / presentation), or
    # pdftotext (PDF), selected per format.
    #
    # Prefers a one-shot, networkless container ({IMAGE}) — bytes in via
    # stdin, Markdown out via stdout, no volume mounts — run by podman or
    # docker ({.runtime}), and falls back to host +pandoc+ / +markitdown+ /
    # +pdftotext+ CLIs on the same stdin→stdout contract when neither
    # answers. Requiring the gem
    # defines this class + the shared {DOCUMENTS} instance but registers
    # nothing; a host opts in with +DOCUMENTS.register+.
    #
    # The cross-cutting *why* — the container's security + reproducibility
    # rationale, the PDF-arm trade-off against pikuri-pdf, the
    # deliberately-unsupported formats (ODS/ODP, OCR/audio), and why
    # paging re-converts each time — lives in
    # +pikuri-extractors/design/architecture.md+.
    #
    # == Format detection
    #
    # {#matches?} claims content by content-type ({CONTENT_TYPES}) or byte
    # sniff (see {#sniff}). {#extract} re-sniffs (the registry duck type
    # doesn't pass +content_type+ to +extract+); when the sniff is blind
    # — legacy XLS, an OLE2 container whose discriminating directory sits
    # past the sample — bytes go to markitdown with no hint and its own
    # detection takes over. Consequence: a *local* +.xls+ (no transport
    # content-type, sniff blind) isn't claimed at all and keeps today's
    # binary refusal. Ordering edge: whichever of this and pikuri-web's
    # +HTML+ registers first sits first, so a PDF served under a lying
    # +text/html+ header may go to HTML (pikuri-pdf front-inserts and wins
    # that) — accepted, rare.
    class Documents
      # @return [Logger] gem-wide diagnostics logger.
      LOGGER = Pikuri.logger_for('Extractors')

      # @return [String] absolute path to the shipped container
      #   build context (Dockerfile + convert.sh).
      DOCKER_DIR = File.expand_path('../../../docker', __dir__)

      # @return [String] converter image tag, named after a digest of the
      #   build context, so a changed Dockerfile or +convert.sh+ rebuilds
      #   and an unchanged one never does. Not a version: +Pikuri::VERSION+
      #   is pikuri-core's, which this gem doesn't release with. The
      #   +pikuri-internal-+ prefix matches the container-naming
      #   convention of the vectordb/memory supervisors.
      IMAGE = begin
        context = Dir[File.join(DOCKER_DIR, '*')].sort.map { |f| File.basename(f) + File.binread(f) }
        "pikuri-internal-extractors:#{Digest::SHA256.hexdigest(context.join)[0, 12]}"
      end

      # @return [String] coreutils-+timeout+ budget for one
      #   conversion. Generous — a huge PPTX through markitdown can
      #   take a while — but bounded, so a wedged converter can't
      #   hang the agent loop.
      CONVERT_TIMEOUT = '300s'

      # @return [String] sentinel format meaning "let markitdown's
      #   magic-byte detection decide" — the fallback when content was
      #   claimed by content-type but the byte sniff is blind.
      AUTO = 'auto'

      # @return [String] the PDF format tag. A constant because PDF is the
      #   one format whose output gets a post-processing pass ({#pdf_page_lines}
      #   restoring +"--- Page N ---"+ markers), so page provenance survives
      #   whichever PDF extractor a host wires.
      PDF = 'pdf'

      # @return [Hash{String => String}] normalized content-type →
      #   format tag (the tag doubles as the container entrypoint's
      #   dispatch argument and pandoc's +-f+ / markitdown's +-x+
      #   value).
      CONTENT_TYPES = {
        'application/vnd.oasis.opendocument.text' => 'odt',
        'application/rtf' => 'rtf',
        'text/rtf' => 'rtf',
        'application/epub+zip' => 'epub',
        'application/pdf' => PDF,
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'docx',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx',
        'application/vnd.ms-excel' => 'xls',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation' => 'pptx'
      }.freeze

      # @return [Hash{String => Array<Symbol>}] format tag → host CLIs
      #   that can convert it, in preference order. Mirrors the
      #   container entrypoint's dispatch (+docker/convert.sh+) — keep
      #   the two in sync. pandoc leads where both could serve (DOCX,
      #   EPUB): its readers preserve more structure.
      HOST_CONVERTERS = {
        'odt'  => %i[pandoc],
        'rtf'  => %i[pandoc],
        'epub' => %i[pandoc markitdown],
        'docx' => %i[pandoc markitdown],
        'xlsx' => %i[markitdown],
        'xls'  => %i[markitdown],
        'pptx' => %i[markitdown],
        PDF    => %i[pdftotext],
        AUTO   => %i[markitdown]
      }.freeze

      # @return [String] zip local-file-header magic, shared by every
      #   OOXML / ODF / EPUB document.
      ZIP_MAGIC = "PK\x03\x04".b

      # @return [Hash{String => String}] host-CLI name → the flag that
      #   makes it print a version and exit 0, where +--version+ (the
      #   default probe, see {#cli?}) doesn't work: poppler's
      #   +pdftotext+ parses +--version+ as a *filename* and exits 1,
      #   but accepts +-v+.
      VERSION_PROBE_FLAGS = { 'pdftotext' => '-v' }.freeze

      # The container CLI a new instance drives: +podman+ if on +PATH+, else
      # +docker+ (which may be missing too — the probe then falls back to
      # the host CLIs). The same rule as +Pikuri::Memory::Mem0Server.runtime+
      # and +Pikuri::VectorDb::Server::Container.runtime+, by convention.
      #
      # @return [String] +"podman"+ or +"docker"+
      def self.runtime
        %w[podman docker].find { |bin| on_path?(bin) } || 'docker'
      end

      # @param bin [String]
      # @return [Boolean]
      def self.on_path?(bin)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
          File.executable?(File.join(dir, bin))
        end
      end

      # @param runtime [String, nil] +"podman"+ or +"docker"+; +nil+ picks
      #   by {.runtime}.
      def initialize(runtime: nil)
        @runtime = runtime || self.class.runtime
      end

      # @return [String] the container CLI this instance drives,
      #   +"podman"+ or +"docker"+.
      attr_reader :runtime

      # @return [Symbol] kind tag carried on +Extractor::Page#kind+.
      def kind
        :document
      end

      # Claim content this extractor can convert: a recognised
      # content-type, or a positive byte sniff (see "Format detection"
      # in the class docs).
      #
      # @param sample [String] leading bytes of the content.
      # @param content_type [String, nil] normalized content-type, or
      #   +nil+ when the transport carries none (local files).
      # @return [Boolean]
      def matches?(sample:, content_type:)
        CONTENT_TYPES.key?(content_type) || !sniff(sample).nil?
      end

      # Convert the whole document behind +io+ to one Markdown String.
      # PDFs come back as one +"--- Page N ---"+-headed block per
      # text-carrying page (see {PDF}); a fully scanned PDF extracts
      # to the empty String — same contract as pikuri-pdf's extractor.
      #
      # @param io [IO, StringIO] seekable IO positioned at the start.
      # @return [String] Markdown-flavoured UTF-8 text.
      # @raise [Pikuri::Extractor::Error] when no converter is
      #   available, the conversion exits non-zero, or it times out.
      def extract(io)
        with_converted(io) do |file, format|
          format == PDF ? pdf_page_lines(file).to_a.join("\n") : file.read
        end
      end

      # Same content as {#extract}, as a stream of +chomp+ed lines off the
      # converter's stdout Tempfile. The full conversion still runs up
      # front (fired on first consumption), but neither the document nor
      # the Markdown ever materialises as one String. The enumerator owns
      # the Tempfile and deletes it when iteration ends.
      #
      # @param io [IO, StringIO] seekable IO positioned at the start; must
      #   remain open until the enumerator is consumed.
      # @return [Enumerator<String>]
      # @raise [Pikuri::Extractor::Error] as for {#extract}, raised on
      #   first consumption.
      def extract_lines(io)
        Enumerator.new do |yielder|
          with_converted(io) do |file, format|
            if format == PDF
              pdf_page_lines(file).each { |line| yielder << line }
            else
              file.each_line { |line| yielder << line.chomp }
            end
          end
        end
      end

      # Plug this extractor into {Pikuri::Extractor.registry}, before the
      # terminal +Passthrough+ entry and after pikuri-pdf's front-inserted
      # +PDF+ (which keeps winning PDFs). Idempotent — a second call is a
      # no-op.
      #
      # @return [Documents] self, for chaining.
      def register
        registry = Pikuri::Extractor.registry
        registry.insert(-2, self) unless registry.include?(self)
        self
      end

      # Build the converter image now if it isn't present — for host
      # scripts that prefer paying the one-time build (pip install +
      # apt, minutes) at boot rather than mid-conversation. Entirely
      # optional: {#extract} builds lazily on first use otherwise.
      #
      # @return [void]
      # @raise [Pikuri::Extractor::Error] when {#runtime} is unavailable
      #   or the build fails.
      def ensure_image!
        raise Pikuri::Extractor::Error, "`#{@runtime}` is unavailable; cannot build the converter image" unless container?

        image_ready!
        nil
      end

      private

      # Byte-sniff +sample+ to a format tag, or +nil+ when nothing
      # recognisable. ODF / EPUB ride their mandated uncompressed
      # +mimetype+ first zip entry; OOXML rides +[Content_Types].xml+
      # plus an entry-name scan (the distinctive +word/+ / +ppt/+ /
      # +xl/+ names almost always appear within the sample, the first
      # entries being small).
      #
      # @param sample [String]
      # @return [String, nil]
      def sniff(sample)
        s = sample.b
        return PDF   if s.start_with?(FileType::PDF_MAGIC)
        return 'rtf' if s.start_with?('{\rtf')
        return nil unless s.start_with?(ZIP_MAGIC)
        return 'odt'  if s.include?('mimetypeapplication/vnd.oasis.opendocument.text')
        return 'epub' if s.include?('mimetypeapplication/epub+zip')
        return nil unless s.include?('[Content_Types].xml')
        return 'docx' if s.include?('word/')
        return 'pptx' if s.include?('ppt/')
        return 'xlsx' if s.include?('xl/')

        nil
      end

      # Convert the document behind +io+, yield the rewound stdout
      # Tempfile along with the resolved format tag (so callers know
      # whether the PDF post-processing pass applies), delete the
      # Tempfile. Sniffs the leading sample and rewinds before
      # streaming — the same read-then-rewind pattern as
      # +Extractor.extractor_for+.
      #
      # @param io [IO, StringIO] seekable IO positioned at the start.
      # @yieldparam file [Tempfile] converter stdout, rewound.
      # @yieldparam format [String] resolved format tag (or {AUTO}).
      # @return [Object] the block's value.
      def with_converted(io)
        sample = io.read(FileType::SAMPLE_BYTES) || +''
        io.rewind
        format = sniff(sample) || AUTO
        file = convert(io, format)
        begin
          yield file, format
        ensure
          file.close!
        end
      end

      # Run one conversion of +format+: build the argv for the
      # resolved arm, stream +io+ through it with stdout landing in
      # a Tempfile.
      #
      # @param io [IO, StringIO] the whole document, positioned at the
      #   start.
      # @param format [String] format tag (or {AUTO}).
      # @return [Tempfile] rewound, holding the Markdown.
      # @raise [Pikuri::Extractor::Error] on conversion failure.
      def convert(io, format)
        argv = converter_argv(format)
        out = Tempfile.new(['pikuri-extractors', '.md'])
        begin
          result = Pikuri::Subprocess.run(
            'timeout', '--signal=TERM', '--kill-after=5s', CONVERT_TIMEOUT, *argv,
            stdin_data: io, stdout: out, chdir: '/'
          )
          unless result.status.success?
            raise Pikuri::Extractor::Error,
                  "document conversion (#{format}) failed " \
                  "(exit #{result.status.exitstatus}): #{stderr_tail(result.output)}"
          end
          out.rewind
          out
        rescue StandardError
          out.close!
          raise
        end
      end

      # Turn pdftotext's +\f+-separated page stream into the
      # +"--- Page N ---"+ marker shape pikuri-pdf's extractor emits:
      # one marker line per page that carries text, then that page's
      # stripped lines, textless pages silently skipped (keeping their
      # number, so citations stay correct). Buffers one page at a
      # time — bounded memory even for huge documents.
      #
      # @param file [Tempfile] pdftotext stdout, rewound.
      # @return [Enumerator<String>] chomped lines, marker-headed per
      #   page.
      def pdf_page_lines(file)
        Enumerator.new do |lines|
          page_no = 1
          buffer = +''
          flush = lambda do
            text = buffer.strip
            unless text.empty?
              lines << "--- Page #{page_no} ---"
              text.split("\n").each { |line| lines << line }
            end
            page_no += 1
            buffer = +''
          end
          file.each_line do |raw|
            segments = raw.split("\f", -1)
            segments[0...-1].each do |segment|
              buffer << segment
              flush.call
            end
            buffer << segments.last
          end
          flush.call
        end
      end

      # The argv for one conversion of +format+ — the container when
      # {#runtime} answers (building the image first if needed), else the
      # first present host CLI for the format.
      #
      # @param format [String] format tag (or {AUTO}).
      # @return [Array<String>]
      # @raise [Pikuri::Extractor::Error] when no arm is available.
      def converter_argv(format)
        if container?
          return [@runtime, 'run', '--rm', '-i', '--network=none', '--read-only',
                  '--cap-drop=ALL', '--security-opt', 'no-new-privileges',
                  '--tmpfs', '/tmp', image_ready!, format]
        end

        backend = HOST_CONVERTERS.fetch(format).find { |cli| cli?(cli.to_s) }
        unless backend
          raise Pikuri::Extractor::Error,
                "no converter available for #{format}: install podman or docker (recommended — " \
                "sandboxed, pinned versions) or a host #{HOST_CONVERTERS.fetch(format).join(' / ')} CLI"
        end
        host_argv(backend, format)
      end

      # @param backend [Symbol] +:pandoc+ or +:markitdown+.
      # @param format [String] format tag (or {AUTO}).
      # @return [Array<String>] host-CLI argv, same stdin→stdout
      #   contract as the container.
      def host_argv(backend, format)
        case backend
        when :pandoc then ['pandoc', '-f', format, '-t', 'gfm', '--wrap=none']
        when :markitdown then format == AUTO ? ['markitdown'] : ['markitdown', '-x', format]
        when :pdftotext then ['pdftotext', '-q', '-enc', 'UTF-8', '-', '-']
        else raise "unknown converter backend #{backend.inspect}" # pikuri bug
        end
      end

      # Does {#runtime} answer +info+ — the binary on PATH and, for
      # docker, its daemon up? Probed once, memoized, choice logged.
      #
      # @return [Boolean]
      def container?
        unless defined?(@container)
          @container = begin
            runtime_cmd('info').status.success?
          rescue Errno::ENOENT
            false
          end
          LOGGER.info(@container ? "#{@runtime} available — converting in the sandboxed container" \
                                 : "#{@runtime} unavailable — falling back to host pandoc/markitdown")
        end
        @container
      end

      # Make sure {IMAGE} exists locally, building from {DOCKER_DIR}
      # on first need. Memoized after one successful check.
      #
      # @return [String] {IMAGE}, for inlining into the run argv.
      # @raise [Pikuri::Extractor::Error] when the build fails.
      def image_ready!
        return IMAGE if @image_ready

        unless runtime_cmd('image', 'inspect', IMAGE).status.success?
          LOGGER.info("building #{IMAGE} from #{DOCKER_DIR} (one-time, may take minutes)")
          build = runtime_cmd('build', '-t', IMAGE, DOCKER_DIR)
          unless build.status.success?
            raise Pikuri::Extractor::Error,
                  "#{@runtime} build of #{IMAGE} failed: #{stderr_tail(build.output)}"
          end
        end
        @image_ready = true
        IMAGE
      end

      # @param argv [Array<String>] {#runtime} subcommand + args.
      # @return [Pikuri::Subprocess::Result]
      def runtime_cmd(*argv)
        Pikuri::Subprocess.spawn(@runtime, *argv, chdir: '/').wait
      end

      # Is +name+'s version probe (+--version+, or the CLI's
      # {VERSION_PROBE_FLAGS} override) runnable on the host? Probed
      # once per name, memoized.
      #
      # @param name [String] CLI binary name.
      # @return [Boolean]
      def cli?(name)
        @clis ||= {}
        return @clis[name] if @clis.key?(name)

        @clis[name] = begin
          flag = VERSION_PROBE_FLAGS.fetch(name, '--version')
          Pikuri::Subprocess.spawn(name, flag, chdir: '/').wait.status.success?
        rescue Errno::ENOENT
          false
        end
      end

      # Last ~500 chars of converter diagnostics, for an
      # LLM-presentable error message.
      #
      # @param text [String, nil]
      # @return [String]
      def stderr_tail(text)
        t = text.to_s.strip
        return '(no diagnostics)' if t.empty?

        t.length > 500 ? "...#{t[-500..]}" : t
      end
    end

    # The shared, host-script-facing instance: call
    # +Pikuri::Extractors::DOCUMENTS.register+ to plug it into the
    # registry. One instance is right — its only state is memoized
    # environment probes (container runtime / image built / host CLIs),
    # true process-wide.
    DOCUMENTS = Documents.new
  end
end
