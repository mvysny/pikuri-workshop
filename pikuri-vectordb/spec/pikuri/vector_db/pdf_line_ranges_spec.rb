# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'pathname'

# pikuri-vectordb's line_ranges_spec over a registered PDF extractor: a
# PDF's lines are the extractor's output, +"--- Page N ---"+ markers
# included, so the chunk ranges the Corpus stores must number that output
# exactly as vectordb_read pages it. pikuri-pdf is a test-only dependency,
# resolved through the monorepo's top-level Gemfile.
require 'pikuri-pdf'
require_relative '../../support/build_pdf'

RSpec.describe 'Chunk line ranges over a registered PDF extractor' do
  include BuildPdf

  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-pdf-line-ranges-')).realpath }
  let(:backend) { Pikuri::VectorDb::Backend::InMemory.new }

  before { Pikuri::Extractors::PDF.register }

  after do
    Pikuri::Extractor.registry.delete(Pikuri::Extractors::PDF)
    FileUtils.rm_rf(root)
  end

  def index_all!
    tokenizer = Object.new
    def tokenizer.count(text) = text.split.length
    embedder = Object.new
    def embedder.embed(texts) = texts.map { [1.0, 0.0] }
    Pikuri::VectorDb::Corpus.new(
      backend: backend, source: root, embedder: embedder,
      chunker: Pikuri::VectorDb::Chunker::FixedWindow.new(size: 7, overlap: 2, tokenizer: tokenizer)
    ).index_all!
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

  it 'reads every chunk of a multi-page PDF back at its range' do
    File.binwrite(root + 'contract.pdf', build_pdf(
                                           ['Either party may terminate', 'with three months notice', 'in writing.'],
                                           ['Fees are due', 'within thirty days', 'of the invoice date.'],
                                           ['Disputes go to', 'the courts of Helsinki omega']
                                         ))
    index_all!

    stored = backend.query(vector: [1.0, 0.0], top_k: 10_000).map(&:chunk)
    assert_operator stored.length, :>, 4
    stored.each do |chunk|
      first, last = chunk.metadata.values_at(:first_line, :last_line)
      words = chunk.text.split
      found = numbered_words(chunk).each_cons(words.length).any? do |window|
        window.map(&:last) == words && window.first[0] == first && window.last[0] == last
      end
      assert found, "#{chunk.id} (lines #{first}-#{last}) does not read back as #{chunk.text.inspect}"
    end

    # One range pinned by hand: three page markers and eight text lines, so
    # the last text line is line 11.
    assert_equal 11, stored.find { |c| c.text.end_with?('omega') }.metadata[:last_line]
  end
end
