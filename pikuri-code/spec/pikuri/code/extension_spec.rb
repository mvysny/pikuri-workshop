# frozen_string_literal: true

require 'pikuri/testing'

RSpec.describe Pikuri::Code::Extension do
  let(:filesystem) do
    Pikuri::Workspace::Filesystem.new(project_root: Dir.pwd)
  end
  let(:confirmer) { Pikuri::Workspace::Confirmer::AutoApprove.new }

  def build_configurator = Pikuri::Testing.configurator

  it 'is an Agent::Extension by composition' do
    ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
    assert_kind_of Pikuri::Agent::Extension, ext
  end

  describe '#configure with plan mode' do
    let(:plan_mode) { Pikuri::Code::PlanMode.new }

    it 'registers Bash and the plan-mode pair' do
      c = build_configurator
      described_class.new(filesystem: filesystem, confirmer: confirmer, plan_mode: plan_mode).configure(c)

      names = c.tools.map(&:name)
      assert_includes names, 'bash'
      assert_includes names, 'enter_plan_mode'
      assert_includes names, 'exit_plan_mode'
    end

    it 'contributes the plan-mode explainer via system_prompt_snippets' do
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer, plan_mode: plan_mode)

      assert(ext.system_prompt_snippets.any? { |s| s.match?(/plan mode/i) })
    end

    it 'raises if any of its tools was already registered' do
      c = build_configurator
      c.add_tool(Pikuri::Code::EnterPlanMode.new(plan_mode: plan_mode))

      err = assert_raises(RuntimeError) do
        described_class.new(filesystem: filesystem, confirmer: confirmer, plan_mode: plan_mode).configure(c)
      end
      assert_match(/EnterPlanMode.*cannot be pre-registered/, err.message)
    end
  end

  describe '#configure without plan mode' do
    it 'still wires Bash but no plan-mode tools' do
      c = build_configurator
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
      ext.configure(c)

      names = c.tools.map(&:name)
      assert_includes names, 'bash'
      refute_includes names, 'enter_plan_mode'
      refute_includes names, 'exit_plan_mode'
      assert_empty ext.system_prompt_snippets
    end
  end

  describe '#on_user_message' do
    let(:plan_mode) { Pikuri::Code::PlanMode.new }

    it 'injects the read-only reminder while plan mode is active' do
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer, plan_mode: plan_mode)
      ext.configure(build_configurator)

      assert_nil ext.on_user_message('hello', [])

      plan_mode.activate!
      reminder = ext.on_user_message('hello', [])
      assert_match(/plan mode/i, reminder)
    end

    it 'injects nothing when plan mode is not wired' do
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
      ext.configure(build_configurator)

      assert_nil ext.on_user_message('hello', [])
    end
  end

  describe 'the plan-mode event bridge' do
    let(:plan_mode) { Pikuri::Code::PlanMode.new }
    let(:recorder) { Pikuri::Agent::Listener::InMemoryEventList.new }

    def configured(ext)
      c = build_configurator
      c.add_listener(recorder)
      ext.configure(c)
      c
    end

    it 'emits Code::PlanModeChanged on every transition' do
      configured(described_class.new(filesystem: filesystem, confirmer: confirmer, plan_mode: plan_mode))

      plan_mode.activate!
      plan_mode.deactivate!

      assert_equal [true, false], recorder.events.map(&:active)
      assert recorder.events.all? { |e| e.is_a?(Pikuri::Code::PlanModeChanged) }
    end

    # The flag outlives the agent: a "/clear" builds the next agent on it.
    it 'goes quiet once its agent closes' do
      c = configured(described_class.new(filesystem: filesystem, confirmer: confirmer, plan_mode: plan_mode))

      c.agent.close
      plan_mode.activate!

      assert_empty recorder.events
    end
  end
end
