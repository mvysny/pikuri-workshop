# frozen_string_literal: true

require 'spec_helper'
require 'voikko'
require 'pikuri-rag'

describe Pikuri::Stemmers::Voikko do
  # Stands in for a +::Voikko+ handle, so the suite needs no libvoikko, while
  # the readings are the gem's own +Voikko::Analysis+ values: +requiring+ the
  # gem binds no native code, and +#morphemes+ is its real decoding.
  # +readings+ maps a word to libvoikko's attributes, one hash per reading.
  def fake_voikko(readings)
    Object.new.tap do |voikko|
      voikko.define_singleton_method(:language) { 'fi' }
      voikko.define_singleton_method(:close) { @closed = true }
      voikko.define_singleton_method(:closed?) { @closed == true }
      voikko.define_singleton_method(:analyze) do |word|
        readings.fetch(word, []).map { |attributes| ::Voikko::Analysis.new(word, attributes) }
      end
    end
  end

  let(:voikko) do
    fake_voikko(
      'kadun' => [{ 'BASEFORM' => 'katu', 'STRUCTURE' => '=ppppp' },
                  { 'BASEFORM' => 'katua', 'STRUCTURE' => '=ppppp' }],
      'nokia' => [{ 'BASEFORM' => 'noki', 'STRUCTURE' => '=ppppp' },
                  { 'BASEFORM' => 'Nokia', 'STRUCTURE' => '=ipppp' }],
      'tietokoneella' => [{ 'BASEFORM' => 'tietokone', 'STRUCTURE' => '=ppppp=pppppppp' }],
      'tieto' => [{ 'BASEFORM' => 'tieto', 'STRUCTURE' => '=ppppp' }],
      'koneella' => [{ 'BASEFORM' => 'kone', 'STRUCTURE' => '=pppppppp' }],
      'wikipediassa' => [{ 'BASEFORM' => 'Wikipedia', 'STRUCTURE' => '=ippp=pppppppp' }],
      'wiki' => [{ 'BASEFORM' => 'wiki', 'STRUCTURE' => '=pppp' }],
      'katu' => [{ 'BASEFORM' => 'katu' }]
    )
  end
  let(:stemmer) { described_class.new(voikko) }

  describe '#stems' do
    it 'answers every reading, lower-cased and distinct' do
      assert_equal %w[katu katua], stemmer.stems('kadun')
      assert_equal %w[noki nokia], stemmer.stems('nokia')
    end

    it 'answers an unknown word itself' do
      assert_equal ['backend'], stemmer.stems('backend')
    end

    # The query side never splits: "tietokone" searching for "kone" too
    # would make rag_search_keywords tietokone list every note mentioning kone.
    it 'leaves compounds whole' do
      assert_equal ['tietokone'], stemmer.stems('tietokoneella')
    end
  end

  describe '#index_stems' do
    it 'adds each compound part’s dictionary form after the whole' do
      assert_equal %w[tietokone tieto kone], stemmer.index_stems('tietokoneella')
    end

    it 'keeps a part that is no word alone as written' do
      assert_equal %w[wikipedia wiki pediassa], stemmer.index_stems('wikipediassa')
    end

    it 'adds nothing for a one-morpheme word or one with no STRUCTURE' do
      assert_equal %w[katu katua], stemmer.index_stems('kadun')
      assert_equal ['katu'], stemmer.index_stems('katu')
    end

    it 'answers an unknown word itself' do
      assert_equal ['backend'], stemmer.index_stems('backend')
    end
  end

  describe '#id' do
    it 'names the language and the compound split, so changing either rebuilds the index' do
      assert_equal 'voikko-fi+compounds', stemmer.id
    end
  end

  it 'closes its handle, as the Fts5 it is handed does at teardown' do
    Pikuri::Rag::Backend::Fts5.new(stemmer: stemmer).close
    assert voikko.closed?
  end

  # The readings above are hand-written, so check the same shapes against the
  # real libvoikko where one is installed.
  describe 'against libvoikko' do
    let(:stemmer) do
      described_class.new(::Voikko.new(language: 'fi'))
    rescue LoadError, ::Voikko::Error => e
      skip "no libvoikko + voikko-fi here: #{e.message.lines.first}"
    end

    it 'stems an inflected word and a lower-cased proper noun' do
      assert_equal ['katu'], stemmer.stems('kadulla')
      assert_equal ['helsinki'], stemmer.stems('helsingissä')
    end

    it 'splits a compound on the index side only' do
      assert_equal ['versionhallintajärjestelmä'], stemmer.stems('versionhallintajärjestelmää')
      assert_equal %w[versionhallintajärjestelmä versio hallinta järjestelmä],
                   stemmer.index_stems('versionhallintajärjestelmää')
    end

    it 'answers an unknown word itself' do
      assert_equal ['backend'], stemmer.index_stems('backend')
    end

    it 'names the handle’s language in its id' do
      assert_equal 'voikko-fi+compounds', stemmer.id
    end

    it 'finds inflected and compound words through FTS5' do
      fts = Pikuri::Rag::Backend::Fts5.new(stemmer: stemmer)
      fts.upsert(chunks: [Pikuri::VectorDb::Chunk.new(
        id: 'a.md:0', source: 'a.md', text: 'Helsingissä tietokoneella.',
        metadata: { hash: 'h', first_line: 1, last_line: 1 }
      )])
      search = ->(text) { fts.find(terms: Pikuri::Rag::Query.terms(text, stemmer: stemmer)) }
      found = [Pikuri::Rag::Backend::DocumentMatch.new(source: 'a.md', first_lines: [1])]
      assert_equal found, search.('Helsinki')
      assert_equal found, search.('koneen')
      assert_equal found, search.('tietokoneet')
    ensure
      fts&.close
    end
  end
end
