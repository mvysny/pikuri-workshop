# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Chunk do
  it 'exposes id, source, text, and metadata' do
    c = Pikuri::VectorDb::Chunk.new(
      id: 'notes/cooking.md:0',
      source: 'notes/cooking.md',
      text: 'hello world',
      metadata: { ordinal: 0 }
    )
    assert_equal 'notes/cooking.md:0', c.id
    assert_equal 'notes/cooking.md', c.source
    assert_equal 'hello world', c.text
    assert_equal({ ordinal: 0 }, c.metadata)
  end

  it 'is value-equal on identical fields' do
    a = Pikuri::VectorDb::Chunk.new(id: 'x', source: 'doc.md', text: 'y', metadata: { k: 1 })
    b = Pikuri::VectorDb::Chunk.new(id: 'x', source: 'doc.md', text: 'y', metadata: { k: 1 })
    assert_equal a, b
    assert_equal a.hash, b.hash
  end

  it 'is value-distinct on different id' do
    a = Pikuri::VectorDb::Chunk.new(id: 'x', source: 'doc.md', text: 'same', metadata: {})
    b = Pikuri::VectorDb::Chunk.new(id: 'y', source: 'doc.md', text: 'same', metadata: {})
    refute_equal a, b
  end

  it 'allows multiple chunks to share the same source via distinct ids' do
    # Documents the (id, source) split: one file produces many
    # chunks; +source+ is shared, +id+ disambiguates.
    a = Pikuri::VectorDb::Chunk.new(
      id: 'notes/cooking.md:0', source: 'notes/cooking.md',
      text: 'first half', metadata: { ordinal: 0 }
    )
    b = Pikuri::VectorDb::Chunk.new(
      id: 'notes/cooking.md:462', source: 'notes/cooking.md',
      text: 'second half', metadata: { ordinal: 462 }
    )
    assert_equal a.source, b.source
    refute_equal a, b
  end
end
