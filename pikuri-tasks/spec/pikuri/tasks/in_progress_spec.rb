# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::InProgress do
  let(:list) { Pikuri::Tasks::List.new }
  let(:tool) { described_class.new(list: list) }

  describe 'tool shape' do
    it 'is named task_in_progress with a required id integer' do
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'task_in_progress', tool.name
      schema = tool.parameters.to_openai
      assert_equal ['id'], schema[:required]
      assert_equal 'integer', schema[:properties][:id][:type]
    end
  end

  describe 'execution' do
    it 'sets the matching item to in_progress and returns the rendered list' do
      item = list.add('task')
      out = tool.run('id' => item.id).to_s
      assert_equal 'in_progress', list.items.first.status
      assert out.include?("- ##{item.id} [in_progress] task"), out
    end

    it 'returns an LLM-actionable Error: string with the current list when no match' do
      list.add('something else')
      out = tool.run('id' => 42).to_s
      assert out.start_with?('Error: no such task id: 42'), out
      assert out.include?('- #1 [pending] something else'), out
      # Nothing changed
      assert_equal 'pending', list.items.first.status
    end
  end
end
