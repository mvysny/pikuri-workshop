# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::Rag::Query do
  def terms(text, stemmer: Pikuri::Rag::Stemmer::Identity) = Pikuri::Rag::Query.terms(text, stemmer:)
  def any(text, stemmer: Pikuri::Rag::Stemmer::Identity) = Pikuri::Rag::Query.any(text, stemmer:)

  # +stems+ per word from +table+, the word itself otherwise.
  def stemmer_of(table)
    Object.new.tap do |stemmer|
      stemmer.define_singleton_method(:stems) { |word| table.fetch(word, [word]) }
    end
  end

  describe '.tokenize' do
    it 'splits on letter/digit runs and lower-cases' do
      assert_equal %w[acme s q3 pricing v2 1],
                   Pikuri::Rag::Query.tokenize("Acme's Q3 pricing — v2.1")
    end

    it 'keeps non-Latin letters' do
      assert_equal %w[schrödinger ужин], Pikuri::Rag::Query.tokenize('Schrödinger, ужин')
    end

    # \p{L} does not match a combining mark, so unnormalized NFD would cut
    # "schrödinger" at the diaeresis.
    it 'composes decomposed letters before splitting' do
      assert_equal ['schrödinger'], Pikuri::Rag::Query.tokenize("Schrödinger")
    end

    it 'returns empty for punctuation-only and nil input' do
      assert_equal [], Pikuri::Rag::Query.tokenize('--- ?! ***')
      assert_equal [], Pikuri::Rag::Query.tokenize(nil)
    end
  end

  describe '.terms' do
    it 'returns one quoted phrase term per word' do
      assert_equal ['"acme"', '"pricing"'], terms('Acme pricing')
    end

    # Not the juxtaposed '"acme" "pricing"' FTS5 reads as an implicit AND:
    # that AND is row-scoped, and a row is a chunk. The caller ANDs across
    # the document instead.
    it 'never joins the terms into one expression' do
      assert_equal 2, terms('Acme pricing').length
      refute Pikuri::Rag::Query.respond_to?(:all), 'the chunk-scoped AND form must not come back'
    end

    it 'is empty when nothing is searchable' do
      assert_equal [], terms('   ')
      assert_equal [], terms('%%%')
    end
  end

  describe '.any' do
    it 'ORs quoted phrase terms' do
      assert_equal '"what" OR "did" OR "we" OR "discuss"',
                   any('What did we discuss?')
    end

    it 'is nil when nothing is searchable' do
      assert_nil any('!!!')
    end
  end

  describe 'FTS5 operators are never exposed' do
    it 'quotes OR as a literal term rather than an operator' do
      assert_equal ['"acme"', '"or"', '"initech"'], terms('acme OR initech')
    end

    it 'neutralizes prefix stars, column filters and grouping' do
      assert_equal ['"acme"', '"near"', '"text"', '"pricing"'],
                   terms('acme NEAR* {text}: pricing')
    end

    it 'strips a leading hyphen rather than emitting a syntax error' do
      assert_equal ['"acme"'], terms('-acme')
    end

    # The one input that could survive tokenizing as syntax: a quote. It
    # cannot, because a term is emitted as a phrase with internal quotes
    # doubled — but tokenizing already dropped it, which is the belt to
    # that braces.
    it 'never emits an unbalanced quote' do
      out = terms('say "hello" AND 1=1')
      out.each { |t| assert_equal 0, t.count('"') % 2 }
      assert_equal ['"say"', '"hello"', '"and"', '"1"', '"1"'], out
    end

    # A stemmer's output reaches MATCH too, so it is quoted like model text.
    it 'quotes a stem as it quotes a word' do
      stemmer = stemmer_of('x' => ['or', 'a"b'])
      assert_equal ['("or" OR "a""b")'], terms('x', stemmer: stemmer)
    end
  end

  describe 'stemming' do
    let(:stemmer) { stemmer_of('kadun' => %w[katu katua], 'hinnat' => ['hinta']) }

    it 'turns a word with several stems into one OR group, so the per-document AND holds' do
      assert_equal ['("katu" OR "katua")', '"hinta"'], terms('kadun hinnat', stemmer: stemmer)
    end

    it 'ORs every stem of every word for ranking, each once' do
      assert_equal '"katu" OR "katua" OR "hinta"', any('kadun hinnat kadun', stemmer: stemmer)
    end
  end
end
