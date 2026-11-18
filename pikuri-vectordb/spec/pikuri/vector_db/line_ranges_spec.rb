# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'

# The promise a search hit's +lines a-b+ makes, end to end: for every chunk
# the Corpus stores, vectordb_read at +offset: first_line+ shows the
# chunk's words, starting on +first_line+ and ending on +last_line+. The
# chunker, the Corpus and the reader each have their own specs; this one
# fails when they stop agreeing — a misnumbering raises nothing, the agent
# just reads the wrong passage and answers from it.
describe 'Chunk line ranges, indexed and read back' do
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-line-ranges-')).realpath }
  let(:backend) { Pikuri::VectorDb::Backend::InMemory.new }

  # Seven words a chunk, two of overlap: windows start and end mid-line,
  # and consecutive ranges share lines.
  let(:corpus) do
    tokenizer = Object.new
    def tokenizer.count(text) = text.split.length
    embedder = Object.new
    def embedder.embed(texts) = texts.map { [1.0, 0.0] }
    Pikuri::VectorDb::Corpus.new(
      backend: backend, source: root, embedder: embedder,
      chunker: Pikuri::VectorDb::Chunker::FixedWindow.new(size: 7, overlap: 2, tokenizer: tokenizer)
    )
  end

  after { FileUtils.rm_rf(root) }

  # @return [Array<Pikuri::VectorDb::Chunk>] every stored chunk.
  def chunks
    backend.query(vector: [1.0, 0.0], top_k: 10_000).map(&:chunk)
  end

  # @return [Array<Array(Integer, String)>] [line number, word] for every word
  #   on the numbered page vectordb_read answers for the chunk's range.
  def numbered_words(chunk)
    first, last = chunk.metadata.values_at(:first_line, :last_line)
    page = Pikuri::VectorDb::Tools::Read.read(backend: backend, root: root, source: chunk.source,
                                              offset: first, limit: last - first + 1).content
    page.split("\n").flat_map do |line|
      next [] unless (m = line.match(/\A *(\d+)\t(.*)\z/m))

      m[2].split.map { |word| [m[1].to_i, word] }
    end
  end

  def assert_read_back(chunk)
    first, last = chunk.metadata.values_at(:first_line, :last_line)
    words = chunk.text.split
    found = numbered_words(chunk).each_cons(words.length).any? do |window|
      window.map(&:last) == words && window.first[0] == first && window.last[0] == last
    end
    assert found, "#{chunk.id} (lines #{first}-#{last}) does not read back as #{chunk.text.inspect}"
  end

  it 'reads every chunk back at its range' do
    root.join('policy.md').write(
      "\n\n# Pricing policy\r\n\r\n" \
      "List prices hold through Q1\r\nunless the customer renews early.\rA lone CR stays on this line.\n\n\n" \
      "#{(1..60).map { |i| "word#{i}" }.join(' ')}\n" \
      "\tTabbed\tline   with  runs of   spaces\n" \
      "żluťoučký kůň úpěl ďábelské ódy\n" \
      "\n" \
      'final line without a newline'
    )
    root.join('short.txt').write("one\ntwo three\n")
    corpus.index_all!

    stored = chunks
    assert_operator stored.length, :>, 10
    stored.each { |chunk| assert_read_back(chunk) }

    # Reader and chunker could agree on the same wrong count, so pin one
    # range by hand: CRLF and LF lines count, the lone CR does not, and the
    # unterminated last line is line 13 — what grep -n says.
    last = stored.find { |c| c.source == 'policy.md' && c.text.end_with?('newline') }
    assert_equal 13, last.metadata[:last_line]
  end
end
