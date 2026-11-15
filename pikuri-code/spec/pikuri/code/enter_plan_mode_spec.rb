# frozen_string_literal: true

RSpec.describe Pikuri::Code::EnterPlanMode do
  let(:plan_mode) { Pikuri::Code::PlanMode.new }

  describe '#initialize' do
    it 'builds under the enter_plan_mode name' do
      tool = described_class.new(plan_mode: plan_mode)
      assert_equal 'enter_plan_mode', tool.name
    end
  end

  describe '.run' do
    it 'activates the flag and returns a plan-mode observation' do
      result = described_class.run(plan_mode: plan_mode).to_s

      assert plan_mode.active?
      assert_match(/plan mode/i, result)
    end

    it 'is idempotent — entering while already active stays active' do
      plan_mode.activate!
      described_class.run(plan_mode: plan_mode)
      assert plan_mode.active?
    end
  end

  describe 'execute wiring' do
    it 'flips the flag when the tool is run' do
      tool = described_class.new(plan_mode: plan_mode)
      tool.run({})
      assert plan_mode.active?
    end
  end
end
