# frozen_string_literal: true

RSpec.describe Pikuri::Skill::Trigger do
  describe '.strip_suffix' do
    it 'cuts the connective and everything after it' do
      assert_equal 'Weekly work log from git history',
                   described_class.strip_suffix(
                     'Weekly work log from git history. Use when the user asks for a work log.'
                   )
    end

    it 'strips one trailing period off the kept half' do
      assert_equal 'Renders charts',
                   described_class.strip_suffix('Renders charts. Triggers on "plot", "graph".')
    end

    it 'cuts at the earliest connective, not the first one listed' do
      assert_equal 'Does X',
                   described_class.strip_suffix('Does X. Triggers on a chart. Use when plotting.')
    end

    it 'matches case-insensitively' do
      assert_equal 'Does X', described_class.strip_suffix('Does X. USE WHEN plotting.')
    end

    it 'recognizes every connective' do
      [
        'Use this skill when', 'Use when', 'Auto-invoke when', 'Invoke when',
        'Triggers on', 'Trigger on', 'Called when', 'Must trigger when',
        'Must invoke when', 'Must be invoked when'
      ].each do |connective|
        assert_equal 'Does X', described_class.strip_suffix("Does X. #{connective} plotting."),
                     "expected #{connective.inspect} to be recognized"
      end
    end

    it 'leaves a description that opens with a connective whole' do
      description = 'Use when the user asks for a work log.'
      assert_equal description, described_class.strip_suffix(description)
    end

    it 'leaves a description carrying no connective whole' do
      description = 'Weekly work log from git history.'
      assert_equal description, described_class.strip_suffix(description)
    end

    it 'has no word-boundary guard, unlike .strip_prefix' do
      assert_equal 'Does X', described_class.strip_suffix('Does X. Use whenever you like.')
    end

    it 'does not match across a newline inside the connective' do
      description = "Does X. Use\nwhen plotting."
      assert_equal description, described_class.strip_suffix(description)
    end
  end

  describe '.strip_prefix' do
    it 'eats a leading connective and the punctuation behind it' do
      assert_equal 'the user asks for a weekly summary.',
                   described_class.strip_prefix('Use when: the user asks for a weekly summary.')
    end

    it 'eats a leading connective followed by nothing but a space' do
      assert_equal 'plotting', described_class.strip_prefix('Use when plotting')
    end

    it 'prefers the more specific connective' do
      assert_equal 'plotting', described_class.strip_prefix('Use this skill when plotting')
    end

    it 'is word-boundary guarded' do
      value = 'Use whenever you touch the loop'
      assert_equal value, described_class.strip_prefix(value)
    end

    it 'is anchored at the start, so a mid-value connective survives' do
      value = 'Editing a chart, or when the user says plot'
      assert_equal value, described_class.strip_prefix(value)
    end

    it 'returns a value that is nothing but a connective unchanged' do
      assert_equal 'Use when:', described_class.strip_prefix('Use when:')
    end

    it 'ignores leading whitespace when matching' do
      assert_equal 'plotting', described_class.strip_prefix('   Use when plotting')
    end
  end
end
