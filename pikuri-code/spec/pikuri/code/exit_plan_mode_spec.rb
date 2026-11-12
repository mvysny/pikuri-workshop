# frozen_string_literal: true

RSpec.describe Pikuri::Code::ExitPlanMode do
  let(:read_only) { Pikuri::Workspace::ReadOnly.new }

  # Inline confirmer double: records every request it sees and returns
  # successive elements of +answers+ — +true+ → Approved, +false+ → Rejected,
  # else the decision itself. Calling +ask+ with no answer queued raises —
  # surfaces "test silently consumed a confirmation".
  def build_confirmer(*answers)
    queue    = answers.dup
    requests = []
    confirmer = Object.new
    confirmer.define_singleton_method(:ask) do |request:|
      requests << request
      raise "unexpected #ask call (request: #{request.inspect})" if queue.empty?

      case (answer = queue.shift)
      when true  then Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: request.detail)
      when false then Pikuri::Workspace::Confirmer::Rejected.new
      else answer
      end
    end
    confirmer.define_singleton_method(:requests) { requests }
    confirmer
  end

  describe '#initialize' do
    it 'builds under the exit_plan_mode name and requires a plan' do
      tool = described_class.new(read_only: read_only, confirmer: build_confirmer)
      assert_equal 'exit_plan_mode', tool.name
      assert_includes tool.parameters.to_openai[:required], 'plan'
    end
  end

  describe '.run while in plan mode' do
    before { read_only.activate! }

    it 'exits plan mode and tells the model to proceed when approved' do
      confirmer = build_confirmer(true)

      result = described_class.run(read_only: read_only, confirmer: confirmer, plan: 'do X').to_s

      refute read_only.active?
      assert_match(/no longer in plan mode/i, result)
    end

    it 'shows the plan to the user as the request detail' do
      confirmer = build_confirmer(true)

      described_class.run(read_only: read_only, confirmer: confirmer, plan: "## Plan\n1. step")

      assert_equal "## Plan\n1. step", confirmer.requests.first.detail
    end

    it 'stays in plan mode and steers a refine when declined' do
      confirmer = build_confirmer(false)

      result = described_class.run(read_only: read_only, confirmer: confirmer, plan: 'do X').to_s

      assert read_only.active?
      assert_match(/still in plan mode/i, result)
    end

    it 'stays in plan mode and quotes the user when redirected' do
      confirmer = build_confirmer(Pikuri::Workspace::Confirmer::Redirected.new(message: 'drop step 3'))

      result = described_class.run(read_only: read_only, confirmer: confirmer, plan: 'do X').to_s

      assert read_only.active?
      assert_includes result, 'did not approve the plan and said: drop step 3'
      assert_match(/still in plan mode/i, result)
    end
  end

  describe '.run when not in plan mode' do
    it 'returns a nothing-to-exit observation without consulting the confirmer' do
      confirmer = build_confirmer # raises if consulted

      result = described_class.run(read_only: read_only, confirmer: confirmer, plan: 'do X').to_s

      assert_match(/nothing to exit/i, result)
      assert_empty confirmer.requests
    end
  end
end
