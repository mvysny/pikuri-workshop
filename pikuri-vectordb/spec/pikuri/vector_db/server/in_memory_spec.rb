# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Server::InMemory do
  def build_chunk(id)
    Pikuri::VectorDb::Chunk.new(id: id, source: "#{id}.md", text: "text #{id}", metadata: {})
  end

  describe '.ensure_running' do
    it 'returns a server without booting anything (null supervisor)' do
      server = Pikuri::VectorDb::Server::InMemory.ensure_running
      assert_kind_of Pikuri::VectorDb::Server::InMemory, server
    end

    it 'accepts and ignores the docker supervisors-shaped kwargs' do
      # Uniform call sites may pass engine-agnostic options; the null
      # supervisor must not choke on them.
      server = Pikuri::VectorDb::Server::InMemory.ensure_running(data_dir: '/tmp/x', port: 1234)
      assert_kind_of Pikuri::VectorDb::Server::InMemory, server
    end
  end

  describe '#ensure_running!' do
    it 'is a no-op returning self, so the ensure_running.client chain works' do
      server = Pikuri::VectorDb::Server::InMemory.new
      assert_equal server, server.ensure_running!
    end
  end

  describe '#client' do
    it 'returns a Backend::InMemory' do
      client = Pikuri::VectorDb::Server::InMemory.new.client(collection: 'guide')
      assert_kind_of Pikuri::VectorDb::Backend::InMemory, client
    end

    it 'memoizes per collection name — same name, same store' do
      server = Pikuri::VectorDb::Server::InMemory.new
      a = server.client(collection: 'guide')
      b = server.client(collection: 'guide')
      assert_equal a.object_id, b.object_id
    end

    it 'returns independent stores for different collection names' do
      server = Pikuri::VectorDb::Server::InMemory.new
      guide = server.client(collection: 'guide')
      notes = server.client(collection: 'notes')

      guide.upsert(chunks: [build_chunk('a')], vectors: [[1.0, 0.0]])

      assert_equal 1, guide.count
      assert_equal 0, notes.count
    end

    it 'rejects an empty collection name (same contract as the docker servers)' do
      server = Pikuri::VectorDb::Server::InMemory.new
      assert_raises(ArgumentError) { server.client(collection: '') }
      assert_raises(ArgumentError) { server.client(collection: nil) }
    end
  end

  describe '#close' do
    it 'empties every store — outstanding clients go empty, not stale' do
      server = Pikuri::VectorDb::Server::InMemory.new
      guide = server.client(collection: 'guide')
      notes = server.client(collection: 'notes')
      guide.upsert(chunks: [build_chunk('a')], vectors: [[1.0, 0.0]])
      notes.upsert(chunks: [build_chunk('b')], vectors: [[0.0, 1.0]])

      server.close

      assert_equal 0, guide.count
      assert_equal 0, notes.count
    end

    it 'clears the registry — a post-close client is a fresh store' do
      server = Pikuri::VectorDb::Server::InMemory.new
      before = server.client(collection: 'guide')
      server.close

      after = server.client(collection: 'guide')

      refute_equal before.object_id, after.object_id
    end

    it 'is idempotent' do
      server = Pikuri::VectorDb::Server::InMemory.new
      server.client(collection: 'guide')
      server.close
      server.close # no raise
    end
  end
end
