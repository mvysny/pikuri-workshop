# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Reranker::Hit do
  it 'exposes index and score' do
    h = Pikuri::VectorDb::Reranker::Hit.new(index: 2, score: 0.87)
    assert_equal 2, h.index
    assert_in_delta 0.87, h.score, 0.0001
  end

  it 'is value-equal on identical fields' do
    a = Pikuri::VectorDb::Reranker::Hit.new(index: 0, score: 0.5)
    b = Pikuri::VectorDb::Reranker::Hit.new(index: 0, score: 0.5)
    assert_equal a, b
  end
end
