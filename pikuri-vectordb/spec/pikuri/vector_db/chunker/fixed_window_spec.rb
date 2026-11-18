# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Chunker::FixedWindow do
  # Deterministic fake tokenizer: 1 token per whitespace-split
  # word. Lets specs assert exact chunk boundaries without depending
  # on CharHeuristic's approximation drift.
  let(:fake_tokenizer) do
    fake = Object.new
    def fake.count(text)
      text.split.length
    end
    fake
  end

  describe '#initialize' do
    it 'requires positive size' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Chunker::FixedWindow.new(size: 0, tokenizer: fake_tokenizer)
      end
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Chunker::FixedWindow.new(size: -1, tokenizer: fake_tokenizer)
      end
    end

    it 'requires non-negative overlap' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Chunker::FixedWindow.new(size: 5, overlap: -1, tokenizer: fake_tokenizer)
      end
    end

    it 'requires overlap < size (forward-progress guard)' do
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Chunker::FixedWindow.new(size: 3, overlap: 3, tokenizer: fake_tokenizer)
      end
      assert_raises(ArgumentError) do
        Pikuri::VectorDb::Chunker::FixedWindow.new(size: 3, overlap: 5, tokenizer: fake_tokenizer)
      end
    end

    it 'defaults overlap to 0 and tokenizer to CharHeuristic' do
      c = Pikuri::VectorDb::Chunker::FixedWindow.new(size: 100)
      assert_equal 100, c.size
      assert_equal 0, c.overlap
    end
  end

  describe '#chunk on degenerate inputs' do
    let(:chunker) { Pikuri::VectorDb::Chunker::FixedWindow.new(size: 3, overlap: 1, tokenizer: fake_tokenizer) }

    it 'returns [] for empty text' do
      assert_equal [], chunker.chunk('').map(&:text)
    end

    it 'returns [] for whitespace-only text' do
      assert_equal [], chunker.chunk("   \n\t  ").map(&:text)
    end

    it 'returns a single chunk for one word' do
      assert_equal ['hello'], chunker.chunk('hello').map(&:text)
    end

    it 'returns a single chunk when the whole text fits in one window' do
      assert_equal ['a b c'], chunker.chunk('a b c').map(&:text)
    end
  end

  describe '#chunk with overlap' do
    let(:chunker) { Pikuri::VectorDb::Chunker::FixedWindow.new(size: 3, overlap: 1, tokenizer: fake_tokenizer) }

    it 'produces sliding windows with the requested overlap' do
      # 10 words, size 3, overlap 1: chunks of 3 words each
      # sharing 1 word at the boundary. The tail "i j" only
      # has 2 words because the source runs out.
      assert_equal(
        ['a b c', 'c d e', 'e f g', 'g h i', 'i j'],
        chunker.chunk('a b c d e f g h i j').map(&:text)
      )
    end

    it 'normalizes runs of whitespace (split joins on single space)' do
      assert_equal(
        ['a b c', 'c d e'],
        chunker.chunk("a   b\nc\td  e").map(&:text)
      )
    end
  end

  describe '#chunk with overlap 0' do
    let(:chunker) { Pikuri::VectorDb::Chunker::FixedWindow.new(size: 3, overlap: 0, tokenizer: fake_tokenizer) }

    it 'produces adjacent non-overlapping chunks' do
      assert_equal(
        ['a b c', 'd e f', 'g h i', 'j'],
        chunker.chunk('a b c d e f g h i j').map(&:text)
      )
    end
  end

  describe '#chunk when a single word exceeds size' do
    # Pathological case: imagine a 1000-character word against
    # size=3. Chunker should emit the oversized word rather than
    # silently dropping it; the embedder will truncate downstream.
    let(:oversize_tokenizer) do
      fake = Object.new
      # Each word counts as 10 tokens regardless of content.
      def fake.count(text)
        text.split.length * 10
      end
      fake
    end

    it 'emits the oversized word as its own chunk and keeps advancing' do
      chunker = Pikuri::VectorDb::Chunker::FixedWindow.new(
        size: 3, overlap: 0, tokenizer: oversize_tokenizer
      )
      result = chunker.chunk('huge another final').map(&:text)
      assert_equal %w[huge another final], result
    end
  end

  describe '#chunk line ranges' do
    let(:chunker) { Pikuri::VectorDb::Chunker::FixedWindow.new(size: 3, overlap: 1, tokenizer: fake_tokenizer) }

    def ranges(text)
      chunker.chunk(text).map { |p| [p.text, p.first_line, p.last_line] }
    end

    it 'reports each piece by the lines of its first and last word, overlap included' do
      assert_equal [['a b c', 1, 2], ['c d e', 2, 4]], ranges("a b\nc d\n\ne")
    end

    it 'counts CRLF like LF' do
      assert_equal [['a b c', 1, 3]], ranges("a\r\nb\r\nc\r\n")
    end

    it 'does not break a line on a lone CR' do
      assert_equal [['a b c', 1, 2]], ranges("a\rb\nc")
    end

    it 'numbers lines after leading blank lines' do
      assert_equal [['a', 3, 3]], ranges("\n  \na")
    end
  end

  describe '#chunk with the real CharHeuristic tokenizer' do
    it 'produces chunks roughly matching the size target' do
      # CharHeuristic at 4 chars/token. A 1024-char paragraph at
      # size=64 → roughly 1024/(64*4) ≈ 4 chunks before overlap
      # padding adds a couple more. Just sanity-check that the
      # plumbing is wired through correctly and produces > 1 chunk.
      paragraph = 'word ' * 200 # 1000 chars
      chunker = Pikuri::VectorDb::Chunker::FixedWindow.new(size: 32, overlap: 4)
      chunks = chunker.chunk(paragraph)
      refute chunks.empty?
      assert_operator chunks.length, :>, 1
      # Every chunk should be non-empty.
      chunks.each { |c| refute c.text.empty? }
    end
  end
end
