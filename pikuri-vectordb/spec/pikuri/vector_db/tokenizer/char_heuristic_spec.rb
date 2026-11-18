# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Tokenizer::CharHeuristic do
  describe 'with the default 4 chars/token ratio' do
    let(:tokenizer) { Pikuri::VectorDb::Tokenizer::CharHeuristic.new }

    it 'counts the empty string as 0' do
      assert_equal 0, tokenizer.count('')
    end

    it 'rounds up sub-token strings to 1' do
      assert_equal 1, tokenizer.count('a')
      assert_equal 1, tokenizer.count('hi')
      assert_equal 1, tokenizer.count('abc')
    end

    it 'counts exact multiples of 4 as length / 4' do
      assert_equal 1, tokenizer.count('abcd')
      assert_equal 4, tokenizer.count('abcdefghijklmnop')
    end

    it 'rounds non-multiples up' do
      # 17 chars / 4 = 4.25 → 5
      assert_equal 5, tokenizer.count('abcdefghijklmnopq')
    end
  end
end
