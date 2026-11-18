# frozen_string_literal: true

require 'pikuri/testing'

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'

# The trifecta legs the corpus tools inherit from their Extension, plus the
# two flags that decide them. Same shape as pikuri-workspace's
# trifecta_legs_spec: the declaration is the input, the tools derive.
RSpec.describe 'vectordb tool trifecta legs' do
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-vectordb-legs-')).realpath }

  after { FileUtils.remove_entry(root) if root.exist? }

  # No embedder call happens on this path; a stub keeps the real Embedder
  # (and RubyLLM) out of it.
  let(:fake_embedder) do
    obj = Object.new
    def obj.embed(texts) = texts.map { |_t| [1.0, 0.0, 0.0] }
    obj
  end

  def corpus(**flags)
    Pikuri::VectorDb::Corpus.new(backend: Pikuri::VectorDb::Backend::InMemory.new,
                                  source: root.to_s, embedder: fake_embedder, **flags)
  end

  def extension(**flags)
    Pikuri::VectorDb::Extension.new(corpus: corpus(**flags))
  end

  # The real Configurator, so the legs asserted below are the ones the
  # extension actually registers rather than hand-graded copies.
  def tools(**flags)
    c = Pikuri::Testing.configurator
    extension(**flags).configure(c)
    c.tools.to_h { |t| [t.name, t] }
  end

  describe 'CorpusLegs.derive — the one mapping every corpus tool set shares' do
    it 'maps the pessimistic defaults to hard-untrusted, not private, no egress' do
      legs = Pikuri::VectorDb::CorpusLegs.derive(private: false, trusted: false)
      assert_equal :hard, legs.untrusted
      refute legs.private
      assert_equal :no_egress, legs.egress_payload_review
    end

    it 'maps the vouched-for private corpus to private, no untrusted, no egress' do
      legs = Pikuri::VectorDb::CorpusLegs.derive(private: true, trusted: true)
      assert_equal :none, legs.untrusted
      assert legs.private
      assert_equal :no_egress, legs.egress_payload_review
    end
  end

  describe 'Corpus#private? / #trusted?' do
    it 'defaults both off — the framework declares neither for you' do
      refute corpus.private?
      refute corpus.trusted?
    end

    it 'carries the declared flags' do
      declared = corpus(private: true, trusted: true)
      assert declared.private?
      assert declared.trusted?
    end
  end

  describe 'the reading tools' do
    %w[vectordb_search vectordb_read].each do |tool_name|
      describe tool_name do
        it 'defaults to hard untrusted — a corpus is documents pikuri did not write' do
          legs = tools[tool_name].trifecta_legs
          assert_equal :hard, legs.untrusted
          refute legs.private
          assert_equal :no_egress, legs.egress_payload_review
        end

        it 'inherits the declared private leg' do
          assert tools(private: true)[tool_name].trifecta_legs.private
        end

        it 'drops the untrusted leg on a corpus its owner vouched for' do
          assert_equal :none, tools(trusted: true)[tool_name].trifecta_legs.untrusted
        end

        it 'never contributes egress — retrieval never leaves the machine' do
          legs = tools(private: true, trusted: true)[tool_name].trifecta_legs
          assert_equal :no_egress, legs.egress_payload_review
          refute legs.egress?
        end
      end
    end
  end

  describe 'vectordb_reindex' do
    it 'declares no legs, whatever the corpus is — its observation is a count' do
      [{}, { private: true }, { trusted: true }, { private: true, trusted: true }].each do |flags|
        assert_equal Pikuri::Tool::TrifectaLegs::NONE,
                     tools(**flags)['vectordb_reindex'].trifecta_legs,
                     flags.inspect
      end
    end
  end

  describe 'the map the host prints' do
    def report(**flags)
      node = Pikuri::Trifecta::Node.new(
        label: 'corpus-only',
        tool_legs: tools(**flags).transform_values(&:trifecta_legs)
      )
      Pikuri::Trifecta.walk(node)
    end

    it 'reports one untrusted leg for an undeclared corpus' do
      line = report.advisory
      assert_includes line, '1 of 3 legs (untrusted)'
      assert_includes line, 'no private/egress leg found'
    end

    it 'reports one *private* leg once the corpus is declared — the payoff' do
      line = report(private: true, trusted: true).advisory
      assert_includes line, '1 of 3 legs (private)'
      assert_includes line, 'no untrusted/egress leg found'
    end

    it 'stays silent either way — no egress, so no trifecta to complete' do
      assert_equal :silent, report.tree_verdict
      assert_equal :silent, report(private: true, trusted: true).tree_verdict
    end
  end
end
