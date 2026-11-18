# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

describe Pikuri::Rag::Extension do
  let(:inner) { Pikuri::VectorDb::Backend::InMemory.new }

  let(:embedder) do
    fake = Object.new
    fake.define_singleton_method(:embed) { |texts| texts.map { [1.0, 0.0] } }
    fake
  end

  # A Configurator stand-in: the extension only ever reads +tools+ and calls
  # +add_tool+, and building a real Agent would need a transport.
  let(:configurator) do
    c = Object.new
    c.instance_variable_set(:@tools, [])
    c.define_singleton_method(:tools) { @tools }
    c.define_singleton_method(:add_tool) { |tool| @tools << tool }
    c
  end

  def corpus(source: Dir.tmpdir, keywords: Pikuri::Rag::Backend::Fts5.new, **flags)
    Pikuri::VectorDb::Corpus.new(
      backend: Pikuri::Rag::Backend::Hybrid.new(vectors: inner, keywords: keywords),
      source: source, embedder: embedder, **flags
    )
  end

  def build(**flags)
    Pikuri::Rag::Extension.new(corpus: flags.delete(:corpus) || corpus(**flags))
  end

  describe '#configure' do
    it 'registers the four rag_* tools and nothing else' do
      build.configure(configurator)
      assert_equal Pikuri::Rag::Extension::TOOL_NAMES, configurator.tools.map(&:name)
    end

    it 'builds rag_read and rag_reindex from the vectordb classes' do
      build.configure(configurator)
      read, reindex = configurator.tools.last(2)
      assert_instance_of Pikuri::VectorDb::Tools::Read, read
      assert_instance_of Pikuri::VectorDb::Tools::Reindex, reindex
      assert_includes read.description, 'rag_search'
    end

    it 'refuses a pre-registered rag_* tool' do
      configurator.add_tool Pikuri::Rag::Tools::SearchKeywords.new(
        backend: inner, root: Pathname.new(Dir.tmpdir),
        legs: Pikuri::Tool::TrifectaLegs::NONE
      )
      error = assert_raises(RuntimeError) { build.configure(configurator) }
      assert_includes error.message, 'rag_search_keywords cannot be pre-registered'
    end

    it 'refuses a pre-registered vectordb_* tool — the two tool sets are exclusive' do
      configurator.add_tool Pikuri::VectorDb::Tools::Search.new(
        embedder: embedder, backend: inner, legs: Pikuri::Tool::TrifectaLegs::NONE
      )
      error = assert_raises(RuntimeError) { build.configure(configurator) }
      assert_includes error.message, 'vectordb_search cannot be pre-registered'
    end
  end

  describe 'the corpus declaration' do
    it 'defaults to the pessimistic reading' do
      ext = build
      refute tool_legs(ext, 'rag_search').private
      assert_equal :hard, tool_legs(ext, 'rag_search').untrusted
    end

    it 'derives the same legs for all three reading tools' do
      ext = build(private: true, trusted: true)
      %w[rag_search rag_search_keywords rag_read].each do |name|
        legs = tool_legs(ext, name)
        assert legs.private, "#{name} should carry the private leg"
        assert_equal :none, legs.untrusted
        assert_equal :no_egress, legs.egress_payload_review
      end
    end

    it 'leaves rag_reindex with no legs at all' do
      legs = tool_legs(build(private: true, trusted: false), 'rag_reindex')
      refute legs.private
      assert_equal :none, legs.untrusted
    end
  end

  describe 'the corpus' do
    it 'refuses a corpus over a bare vector backend: the keyword tools would have no store' do
      bare = Pikuri::VectorDb::Corpus.new(backend: inner, source: Dir.tmpdir, embedder: embedder)
      error = assert_raises(ArgumentError) { build(corpus: bare) }
      assert_includes error.message, 'Pikuri::VectorDb::Backend::InMemory'
    end

    it 'searches what the corpus filled, keyword index included' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'note.md'), 'Acme pricing was agreed.')
        ext = build(corpus: corpus(source: dir))
        ext.corpus.index_all!
        assert_equal [Pikuri::Rag::Backend::DocumentMatch.new(source: 'note.md', first_lines: [1])],
                     ext.corpus.backend.find(terms: ['"acme"'])
        ext.corpus.close
      end
    end

    it 'closes the keyword store when the corpus closes' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'fts.sqlite3')
        keywords = Pikuri::Rag::Backend::Fts5.new(store: path)
        corpus(keywords: keywords).close
        assert_raises(StandardError) { keywords.count }
        assert File.exist?(path)
      end
    end
  end

  # Configures once per extension, so a caller may ask about several tools.
  def tool_legs(ext, name)
    @configured ||= {}
    @configured[ext] ||= begin
      ext.configure(configurator)
      configurator.tools
    end
    @configured[ext].find { |t| t.name == name }.trifecta_legs
  end
end
