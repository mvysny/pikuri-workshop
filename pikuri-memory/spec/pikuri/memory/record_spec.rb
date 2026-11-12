# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::Memory::Record do
  def record(created_at)
    described_class.new(id: 'r', text: 'fact', score: nil, created_at: created_at, metadata: {}, event: nil)
  end

  describe '#created_label' do
    it 'trims an ISO-8601 timestamp to whole-second wall-clock (no sub-second / offset)' do
      assert_equal '2026-05-01 17:04:11', record('2026-05-01T17:04:11.884889+00:00').created_label
    end

    it 'keeps the wall-clock of a date-only value' do
      assert_equal '2026-05-01 00:00:00', record('2026-05-01').created_label
    end

    it 'returns nil when created_at is absent' do
      assert_nil record(nil).created_label
    end

    it 'falls back to the raw String when the value is unparseable' do
      assert_equal 'not-a-date', record('not-a-date').created_label
    end
  end
end
