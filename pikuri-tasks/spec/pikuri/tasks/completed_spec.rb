# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::Completed do
  let(:list) { Pikuri::Tasks::List.new }
  let(:tool) { described_class.new(list: list) }

  describe 'tool shape' do
    it 'is named task_completed with a required id integer' do
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'task_completed', tool.name
      schema = tool.parameters.to_openai
      assert_equal ['id'], schema[:required]
      assert_equal 'integer', schema[:properties][:id][:type]
    end
  end

  describe 'display line' do
    it 'names the task by title, since the model addresses it by integer id' do
      item = list.add('Write the specs')

      assert_equal 'Write the specs', tool.describe_call('id' => item.id)
      assert_equal 'TaskCompleted', tool.display_name
    end

    it 'falls back to #id for an id the list does not hold' do
      assert_equal '#7', tool.describe_call('id' => 7)
    end

    it 'summarizes the list rather than echoing it' do
      list.add('a')
      item = list.add('b')

      assert_equal '2 tasks, 1 done', tool.run('id' => item.id).summary
    end
  end

  describe 'execution' do
    it 'sets the matching item to completed and returns the rendered list' do
      item = list.add('task')
      list.set_status(id: item.id, status: 'in_progress')
      out = tool.run('id' => item.id).to_s
      assert_equal 'completed', list.items.first.status
      assert out.include?("- ##{item.id} [completed] task"), out
    end

    it 'returns an LLM-actionable Error: string with the current list when no match' do
      list.add('real task')
      out = tool.run('id' => 7).to_s
      assert out.start_with?('Error: no such task id: 7'), out
      assert out.include?('- #1 [pending] real task'), out
    end
  end
end
