# frozen_string_literal: true

RSpec.describe Pikuri::Code::EnterPlanMode do
  let(:read_only) { Pikuri::Workspace::ReadOnly.new }

  describe '#initialize' do
    it 'builds under the enter_plan_mode name' do
      tool = described_class.new(read_only: read_only)
      assert_equal 'enter_plan_mode', tool.name
    end
  end

  describe '.run' do
    it 'activates the flag and returns a plan-mode observation' do
      result = described_class.run(read_only: read_only).to_s

      assert read_only.active?
      assert_match(/plan mode/i, result)
    end

    it 'is idempotent — entering while already active stays active' do
      read_only.activate!
      described_class.run(read_only: read_only)
      assert read_only.active?
    end
  end

  describe 'execute wiring' do
    it 'flips the flag when the tool is run' do
      tool = described_class.new(read_only: read_only)
      tool.run({})
      assert read_only.active?
    end
  end
end
