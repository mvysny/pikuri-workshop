# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::Delete do
  let(:list) { Pikuri::Tasks::List.new }
  let(:tool) { described_class.new(list: list) }

  describe 'tool shape' do
    it 'is named task_delete with a required id integer' do
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'task_delete', tool.name
      schema = tool.parameters.to_openai
      assert_equal ['id'], schema[:required]
      assert_equal 'integer', schema[:properties][:id][:type]
    end
  end

  describe 'execution' do
    it 'removes the matching item and returns the rendered list' do
      list.add('keep')
      drop = list.add('drop')
      out = tool.run('id' => drop.id).to_s
      assert_equal %w[keep], list.items.map(&:content)
      assert out.include?('- #1 [pending] keep'), out
      refute out.include?('drop'), out
    end

    it 'returns the empty marker after the last item is removed' do
      only = list.add('only')
      out = tool.run('id' => only.id).to_s
      assert_equal '<tasks>(empty)</tasks>', out
    end

    it 'returns an LLM-actionable Error: string with the current list when no match' do
      list.add('survivor')
      out = tool.run('id' => 9).to_s
      assert out.start_with?('Error: no such task id: 9'), out
      assert out.include?('- #1 [pending] survivor'), out
    end

    it 'reports a stale (already-deleted, never-reused) id as no such task' do
      gone = list.add('gone')
      list.delete(gone.id)
      list.add('newer')
      out = tool.run('id' => gone.id).to_s
      assert out.start_with?("Error: no such task id: #{gone.id}"), out
      assert_equal %w[newer], list.items.map(&:content)
    end
  end
end
