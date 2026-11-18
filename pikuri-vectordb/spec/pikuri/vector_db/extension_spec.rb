# frozen_string_literal: true

require 'pikuri/testing'

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'

describe Pikuri::VectorDb::Extension do
  # Real Configurator — same shape pikuri-tasks's
  # extension_spec uses. Easier to spec wiring against the real
  # type than a stub.
  let(:configurator) { Pikuri::Testing.configurator }

  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-vectordb-ext-')).realpath }
  let(:backend) { Pikuri::VectorDb::Backend::InMemory.new }

  # Deterministic fake embedder, fixed 3-dim vector per text.
  let(:fake_embedder) do
    obj = Object.new
    def obj.embed(texts)
      texts.map { |_t| [1.0, 0.0, 0.0] }
    end
    obj
  end

  after { FileUtils.rm_rf(root) }

  let(:corpus) { Pikuri::VectorDb::Corpus.new(backend: backend, source: root.to_s, embedder: fake_embedder) }

  def build_extension
    Pikuri::VectorDb::Extension.new(corpus: corpus)
  end

  it 'is an Agent::Extension by composition' do
    refute_nil build_extension
    assert_kind_of Pikuri::Agent::Extension, build_extension
  end

  describe '#initialize' do
    it 'exposes the corpus it was given' do
      assert_same corpus, build_extension.corpus
    end

    it 'lets two extensions share one corpus, so two agents search one corpus' do
      a = Pikuri::Testing.configurator
      b = Pikuri::Testing.configurator
      build_extension.configure(a)
      build_extension.configure(b)
      File.write(root + 'hi.md', 'hello world')
      corpus.index_all!

      [a, b].each do |c|
        search = c.tools.find { |t| t.name == 'vectordb_search' }
        assert_includes search.run('query' => 'hello').to_s, 'hi.md'
      end
    end
  end

  describe '#configure' do
    it 'registers vectordb_search, vectordb_read and vectordb_reindex tools' do
      build_extension.configure(configurator)

      tool_names = configurator.tools.map(&:name)
      assert_includes tool_names, 'vectordb_search'
      assert_includes tool_names, 'vectordb_read'
      assert_includes tool_names, 'vectordb_reindex'
    end

    it 'does NOT index — population is the host\'s call' do
      File.write(root + 'note.md', 'first second third')

      build_extension.configure(configurator)

      assert_equal 0, backend.count
    end

    it 'contributes no system-prompt snippet' do
      ext = build_extension
      ext.configure(configurator)
      assert_empty ext.system_prompt_snippets
    end

    it 'raises if vectordb_search has been pre-registered' do
      pre = Pikuri::VectorDb::Tools::Search.new(embedder: fake_embedder, backend: backend,
                                                legs: Pikuri::Tool::TrifectaLegs::NONE)
      configurator.add_tool(pre)

      err = assert_raises(RuntimeError) do
        build_extension.configure(configurator)
      end
      assert_match(/vectordb_search cannot be pre-registered/, err.message)
    end

    it 'raises if vectordb_read has been pre-registered' do
      pre = Pikuri::VectorDb::Tools::Read.new(backend: backend, root: root,
                                              legs: Pikuri::Tool::TrifectaLegs::NONE)
      configurator.add_tool(pre)

      err = assert_raises(RuntimeError) do
        build_extension.configure(configurator)
      end
      assert_match(/vectordb_read cannot be pre-registered/, err.message)
    end

    it 'raises if vectordb_reindex has been pre-registered' do
      pre = Pikuri::VectorDb::Tools::Reindex.new(corpus: build_extension.corpus)
      configurator.add_tool(pre)

      err = assert_raises(RuntimeError) do
        build_extension.configure(configurator)
      end
      assert_match(/vectordb_reindex cannot be pre-registered/, err.message)
    end

    it 'raises if a rag_* tool has been pre-registered' do
      # pikuri-rag's tool set replaces this one over the same corpus, so
      # wiring both on one agent must fail whichever goes second. Built here
      # as a bare Pikuri::Tool rather than by requiring pikuri-rag, which
      # would be a dependency in the wrong direction.
      pre = Pikuri::Tool.new(
        name: 'rag_search', description: 'stand-in for pikuri-rag',
        parameters: Pikuri::Tool::Parameters.build { |_p| }, execute: -> { '' }
      )
      configurator.add_tool(pre)

      err = assert_raises(RuntimeError) do
        build_extension.configure(configurator)
      end
      assert_match(/rag_search cannot be pre-registered/, err.message)
      assert_match(/wire one or the other/, err.message)
    end
  end
end
