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

  describe '#configure with a read-only flag' do
    let(:read_only) { Pikuri::Workspace::ReadOnly.new }

    it 'registers Bash, the plan-mode pair, and GitClone as a sub-agent tool' do
      c = build_configurator
      described_class.new(filesystem: filesystem, confirmer: confirmer, read_only: read_only).configure(c)

      names = c.tools.map(&:name)
      assert_includes names, 'bash'
      assert_includes names, 'enter_plan_mode'
      assert_includes names, 'exit_plan_mode'

      assert_includes c.sub_agent_tools.map(&:name), 'git_clone'
    end

    it 'contributes the plan-mode explainer via system_prompt_snippets' do
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer, read_only: read_only)

      assert(ext.system_prompt_snippets.any? { |s| s.match?(/plan mode/i) })
    end

    it 'raises if any of its tools was already registered' do
      c = build_configurator
      c.add_tool(Pikuri::Code::EnterPlanMode.new(read_only: read_only))

      err = assert_raises(RuntimeError) do
        described_class.new(filesystem: filesystem, confirmer: confirmer, read_only: read_only).configure(c)
      end
      assert_match(/EnterPlanMode.*cannot be pre-registered/, err.message)
    end
  end

  describe '#configure without a read-only flag' do
    it 'still wires Bash + GitClone but no plan-mode tools' do
      c = build_configurator
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
      ext.configure(c)

      names = c.tools.map(&:name)
      assert_includes names, 'bash'
      refute_includes names, 'enter_plan_mode'
      refute_includes names, 'exit_plan_mode'
      assert_includes c.sub_agent_tools.map(&:name), 'git_clone'
      assert_empty ext.system_prompt_snippets
    end
  end

  describe '#on_user_message' do
    let(:read_only) { Pikuri::Workspace::ReadOnly.new }

    it 'injects the read-only reminder while plan mode is active' do
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer, read_only: read_only)
      ext.configure(build_configurator)

      assert_nil ext.on_user_message('hello', [])

      read_only.activate!
      reminder = ext.on_user_message('hello', [])
      assert_match(/plan mode/i, reminder)
    end

    it 'injects nothing when no read-only flag is wired' do
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
      ext.configure(build_configurator)

      assert_nil ext.on_user_message('hello', [])
    end
  end

  describe 'the plan-mode event bridge' do
    let(:read_only) { Pikuri::Workspace::ReadOnly.new }
    let(:recorder) { Pikuri::Agent::Listener::InMemoryEventList.new }

    def configured(ext)
      c = build_configurator
      c.add_listener(recorder)
      ext.configure(c)
      c
    end

    it 'emits Code::PlanModeChanged on every transition' do
      configured(described_class.new(filesystem: filesystem, confirmer: confirmer, read_only: read_only))

      read_only.activate!
      read_only.deactivate!

      assert_equal [true, false], recorder.events.map(&:active)
      assert recorder.events.all? { |e| e.is_a?(Pikuri::Code::PlanModeChanged) }
    end

    # The flag outlives the agent: a "/clear" builds the next agent on it.
    it 'goes quiet once its agent closes' do
      c = configured(described_class.new(filesystem: filesystem, confirmer: confirmer, read_only: read_only))

      c.agent.close
      read_only.activate!

      assert_empty recorder.events
    end
  end
end
