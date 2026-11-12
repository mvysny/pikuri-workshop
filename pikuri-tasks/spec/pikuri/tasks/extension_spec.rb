# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::Extension do
  let(:configurator) do
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base',
      id: '',
      streaming: false,
      cancellable: nil,
      interloper: nil
    )
  end

  it 'is an Agent::Extension by composition' do
    assert_kind_of Pikuri::Agent::Extension, described_class.new
  end

  describe '#configure' do
    it 'registers all four task tools, all sharing the same List instance' do
      ext = described_class.new
      ext.configure(configurator)

      tools = configurator.tools
      assert_equal 4, tools.size
      assert_equal %w[task_create task_in_progress task_completed task_delete].sort,
                   tools.map(&:name).sort

      # All four tools must mutate the same list — drive one and observe via the others.
      task_create = tools.find { |t| t.name == 'task_create' }
      task_completed = tools.find { |t| t.name == 'task_completed' }
      task_create.run('items' => ['one item'])
      out = task_completed.run('id' => 1).to_s
      assert out.include?('- #1 [completed] one item'), out
      assert_equal 'completed', ext.list.items.first.status
    end

    it 'contributes the workflow snippet via system_prompt_snippets' do
      ext = described_class.new

      assert_equal 1, ext.system_prompt_snippets.size
      snippet = ext.system_prompt_snippets.first
      assert snippet.include?('<tasks_usage>'), snippet
      assert snippet.include?('task_create'), snippet
      assert snippet.include?('task_in_progress'), snippet
      assert snippet.include?('task_completed'), snippet
      assert snippet.include?('task_delete'), snippet
    end

    it 'raises if any of the four task tools was already registered' do
      pre = Pikuri::Tasks::Create.new(list: Pikuri::Tasks::List.new)
      configurator.add_tool(pre)
      err = assert_raises(RuntimeError) { described_class.new.configure(configurator) }
      assert_match(/Create.*cannot be pre-registered/, err.message)
    end
  end

  describe '#list' do
    it 'exposes a fresh List instance per extension instance' do
      a = described_class.new
      b = described_class.new
      refute_same a.list, b.list
      assert_kind_of Pikuri::Tasks::List, a.list
      assert a.list.empty?
    end
  end

  describe '#bind' do
    # Minimal Agent::ExtensionContext stand-in recording emitted events.
    let(:fake_ctx_class) do
      Class.new do
        attr_reader :emitted

        def initialize
          @emitted = []
        end

        def emit_event(event)
          @emitted << event
        end
      end
    end

    it 'arms List#on_change to emit a ListChanged snapshot per mutation' do
      ext = described_class.new
      ext.configure(configurator)
      ctx = fake_ctx_class.new

      ext.bind(ctx)
      task_create = configurator.tools.find { |t| t.name == 'task_create' }
      task_create.run('items' => %w[one two])

      # One event per added item (batch create mutates item-by-item);
      # the last snapshot is authoritative.
      assert_equal 2, ctx.emitted.size
      assert(ctx.emitted.all? { |e| e.is_a?(Pikuri::Tasks::ListChanged) })
      assert_equal %w[one], ctx.emitted[0].items.map(&:content)
      assert_equal %w[one two], ctx.emitted[1].items.map(&:content)
    end

    it 'emits on status change and delete too, carrying frozen snapshots' do
      ext = described_class.new
      ext.configure(configurator)
      ctx = fake_ctx_class.new
      ext.bind(ctx)

      ext.list.add('one')
      ext.list.set_status(id: 1, status: 'completed')
      ext.list.delete(1)

      assert_equal 3, ctx.emitted.size
      assert_equal 'completed', ctx.emitted[1].items.first.status
      assert_empty ctx.emitted[2].items
      assert(ctx.emitted.all? { |e| e.items.frozen? })
    end

    it 'emits nothing before bind — on_change defaults to nil' do
      ext = described_class.new
      ext.configure(configurator)

      ext.list.add('quiet') # must not raise
      assert_equal 1, ext.list.size
    end
  end

  describe '#on_conversation_reset' do
    let(:fake_ctx_class) do
      Class.new do
        attr_reader :emitted

        def initialize
          @emitted = []
        end

        def emit_event(event)
          @emitted << event
        end
      end
    end

    it 'clears the list and emits a ListChanged with an empty snapshot' do
      ext = described_class.new
      ext.configure(configurator)
      ctx = fake_ctx_class.new
      ext.bind(ctx)
      ext.list.add('one')
      ext.list.add('two')
      ctx.emitted.clear

      ext.on_conversation_reset(ctx)

      assert_equal 0, ext.list.size
      assert_equal 1, ctx.emitted.size
      assert_empty ctx.emitted.first.items
    end
  end
end
