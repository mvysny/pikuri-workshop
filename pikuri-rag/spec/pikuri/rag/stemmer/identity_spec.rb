# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::Rag::Stemmer::Identity do
  it 'answers each word itself, on both sides' do
    assert_equal ['meetings'], described_class.stems('meetings')
    assert_equal ['meetings'], described_class.index_stems('meetings')
  end

  it 'has a stable id' do
    assert_equal 'identity', described_class.id
  end
end
