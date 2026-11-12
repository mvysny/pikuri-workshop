# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::Memory::Recall do
  def record(text, created_at: nil, score: nil)
    Pikuri::Memory::Record.new(
      id: 't', text: text, score: score, created_at: created_at, metadata: {}, event: nil
    )
  end

  # Minimal fake client: records the search args and returns canned rows.
  let(:fake_client_class) do
    Class.new do
      attr_reader :searched

      def initialize(rows: [], error: nil)
        @rows = rows
        @error = error
        @searched = nil
      end

      def search(query:, user_id:, top_k:)
        @searched = { query: query, user_id: user_id, top_k: top_k }
        raise @error if @error

        @rows
      end
    end
  end

  it 'is a Pikuri::Tool named recall with a single topic param' do
    tool = described_class.new(client: fake_client_class.new, user_id: 'u')

    assert_equal 'recall', tool.name
    assert_kind_of Pikuri::Tool, tool
    assert_equal ['topic'], tool.parameters.to_openai[:required].map(&:to_s)
  end

  it 'searches the fixed namespace and formats results with timestamps' do
    client = fake_client_class.new(rows: [
                                     record('lives in Brno', created_at: '2026-05-01T17:04:11.884889+00:00'),
                                     record('writes Ruby', created_at: '2026-05-02T09:30:00+00:00')
                                   ])
    result = described_class.execute(client: client, user_id: 'martin', topic: 'where?')
    out = result.to_s

    assert_equal({ query: 'where?', user_id: 'martin', top_k: Pikuri::Memory::Recall::TOP_K }, client.searched)
    assert_match(/Recalled 2 memories/, out)
    # The display line counts and stops: a memory's text is attacker-authorable.
    assert_equal 'Recalled 2 memories', result.summary
    refute_includes result.summary, 'Brno'
    # created_at is trimmed to whole-second wall-clock — no sub-second / offset noise.
    assert_match(/\(2026-05-01 17:04:11\) lives in Brno/, out)
    assert_match(/\(2026-05-02 09:30:00\) writes Ruby/, out)
  end

  it 'reports no-match cleanly' do
    result = described_class.execute(client: fake_client_class.new(rows: []), user_id: 'u', topic: 'x')
    assert_equal 'No relevant memories found.', result.to_s
    assert_equal 'Recalled 0 memories', result.summary
  end

  it 'returns an Error: observation (not a raise) when the client fails' do
    client = fake_client_class.new(error: RuntimeError.new('mem0 down'))
    out = described_class.execute(client: client, user_id: 'u', topic: 'x')

    assert_match(/\AError: memory recall failed: mem0 down/, out.content)
  end

  it 'rejects a blank topic' do
    out = described_class.execute(client: fake_client_class.new, user_id: 'u', topic: '  ')
    assert_equal 'Error: topic is empty', out.content
  end
end
