# frozen_string_literal: true

RSpec.describe Pikuri::Code::Extension do
  let(:filesystem) do
    Pikuri::Workspace::Filesystem.new(project_root: Dir.pwd)
  end
  let(:confirmer) { Pikuri::Workspace::Confirmer::AutoApprove.new }

  def build_configurator
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base',
      id: '',
      streaming: false,
      cancellable: nil,
      interloper: nil
    )
  end

  # Minimal ExtensionContext stand-in that records emitted events.
  def build_ctx
    ctx = Object.new
    events = []
    ctx.define_singleton_method(:emit_event) { |e| events << e }
    ctx.define_singleton_method(:events) { events }
    ctx
  end

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

      assert_nil ext.on_user_message(nil, 'hello', [])

      read_only.activate!
      reminder = ext.on_user_message(nil, 'hello', [])
      assert_match(/plan mode/i, reminder)
    end

    it 'injects nothing when no read-only flag is wired' do
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
      ext.configure(build_configurator)

      assert_nil ext.on_user_message(nil, 'hello', [])
    end
  end

  describe '#bind event bridge' do
    let(:read_only) { Pikuri::Workspace::ReadOnly.new }

    it 'emits Code::PlanModeChanged on every transition' do
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer, read_only: read_only)
      ext.configure(build_configurator)
      ctx = build_ctx
      ext.bind(ctx)

      read_only.activate!
      read_only.deactivate!

      assert_equal [true, false], ctx.events.map(&:active)
      assert ctx.events.all? { |e| e.is_a?(Pikuri::Code::PlanModeChanged) }
    end

    it 'is a no-op when no read-only flag is wired' do
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
      ext.configure(build_configurator)
      ctx = build_ctx

      ext.bind(ctx) # must not raise
      assert_empty ctx.events
    end
  end
end
