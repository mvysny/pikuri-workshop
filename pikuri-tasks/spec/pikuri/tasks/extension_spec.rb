# frozen_string_literal: true

require 'pikuri/testing'

RSpec.describe Pikuri::Tasks::Extension do
  let(:configurator) { Pikuri::Testing.configurator }

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

  describe 'the ListChanged bridge' do
    let(:recorder) { Pikuri::Agent::Listener::InMemoryEventList.new }

    before { configurator.add_listener(recorder) }

    it 'emits one ListChanged snapshot per batch create' do
      ext = described_class.new
      ext.configure(configurator)
      task_create = configurator.tools.find { |t| t.name == 'task_create' }
      task_create.run('items' => %w[one two])

      assert_equal 1, recorder.events.size
      assert_kind_of Pikuri::Tasks::ListChanged, recorder.events.first
      assert_equal %w[one two], recorder.events.first.items.map(&:content)
    end

    it 'emits on status change and delete too, carrying frozen snapshots' do
      ext = described_class.new
      ext.configure(configurator)

      ext.list.add('one')
      ext.list.set_status(id: 1, status: 'completed')
      ext.list.delete(1)

      assert_equal 3, recorder.events.size
      assert_equal 'completed', recorder.events[1].items.first.status
      assert_empty recorder.events[2].items
      assert(recorder.events.all? { |e| e.items.frozen? })
    end

    it 'emits nothing from a list no agent configured — on_change defaults to nil' do
      ext = described_class.new

      ext.list.add('quiet') # must not raise
      assert_equal 1, ext.list.size
    end
  end
end
