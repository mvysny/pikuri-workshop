# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Tools::Reindex do
  # Stub corpus: configurable return value, optional raise.
  # The Reindex tool is a thin wrapper, so the unit boundary
  # is "what we send to corpus.reindex! and what we do with
  # what comes back."
  def stub_corpus(return_value: 5, raise_with: nil)
    obj = Object.new
    obj.instance_variable_set(:@return_value, return_value)
    obj.instance_variable_set(:@raise_with, raise_with)
    obj.instance_variable_set(:@call_count, 0)
    obj.singleton_class.send(:attr_reader, :call_count)
    obj.singleton_class.send(:define_method, :reindex!) do
      @call_count += 1
      raise @raise_with if @raise_with

      @return_value
    end
    obj
  end

  describe 'as a Pikuri::Tool' do
    it 'is named vectordb_reindex' do
      tool = Pikuri::VectorDb::Tools::Reindex.new(corpus: stub_corpus)
      assert_equal 'vectordb_reindex', tool.name
    end

    it 'takes another family prefix, renaming itself and the search tool it mentions' do
      tool = Pikuri::VectorDb::Tools::Reindex.new(corpus: stub_corpus, family: 'rag')
      assert_equal 'rag_reindex', tool.name
      assert_includes tool.description, 'rag_search'
      refute_includes tool.description, 'vectordb'
    end

    it 'declares no parameters' do
      tool = Pikuri::VectorDb::Tools::Reindex.new(corpus: stub_corpus)
      schema = tool.parameters.to_openai
      assert_equal({}, schema[:properties])
      assert_equal [], schema[:required]
    end

    it 'description states not-auto-indexed, asks-only, and slowness' do
      tool = Pikuri::VectorDb::Tools::Reindex.new(corpus: stub_corpus)
      assert_match(/NOT indexed automatically/i, tool.description)
      assert_match(/asks to index, reindex, or refresh/i, tool.description)
      assert_match(/SLOW/, tool.description)
    end
  end

  describe '#execute happy paths' do
    it 'returns a one-line summary including the chunk count' do
      corpus = stub_corpus(return_value: 247)
      observation = Pikuri::VectorDb::Tools::Reindex.execute(corpus: corpus).to_s

      assert_equal 'Reindexed: 247 chunk(s) now in the index.', observation
    end

    it 'calls corpus.reindex! exactly once per invocation' do
      corpus = stub_corpus(return_value: 5)
      Pikuri::VectorDb::Tools::Reindex.execute(corpus: corpus)
      assert_equal 1, corpus.call_count
    end

    it 'returns a helpful empty-corpus message when reindex returns 0' do
      corpus = stub_corpus(return_value: 0)
      observation = Pikuri::VectorDb::Tools::Reindex.execute(corpus: corpus).to_s

      assert_includes observation, 'Reindexed: 0 chunks'
      assert_includes observation, 'No indexable files'
    end
  end

  describe '#execute error path' do
    it 'returns "Error: ..." when the corpus raises a RuntimeError' do
      corpus = stub_corpus(raise_with: 'Backend::Qdrant: HTTP 503 ...')
      observation = Pikuri::VectorDb::Tools::Reindex.execute(corpus: corpus).to_s

      assert_match(/^Error: reindex failed:/, observation)
      assert_match(/HTTP 503/, observation)
    end

    it 'does not catch non-RuntimeError exceptions (those are bugs, not LLM-recoverable)' do
      corpus = stub_corpus(raise_with: ArgumentError.new('logic bug'))
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Tools::Reindex.execute(corpus: corpus)
      end
    end
  end
end
