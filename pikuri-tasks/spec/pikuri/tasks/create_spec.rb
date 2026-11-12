# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::Create do
  let(:list) { Pikuri::Tasks::List.new }
  let(:tool) { described_class.new(list: list) }

  describe 'tool shape' do
    it 'is a Pikuri::Tool named task_create with a required items array-of-strings parameter' do
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'task_create', tool.name
      schema = tool.parameters.to_openai
      assert_equal ['items'], schema[:required]
      assert_equal 'array', schema[:properties][:items][:type]
      assert_equal({ type: 'string' }, schema[:properties][:items][:items])
    end
  end

  describe 'display line' do
    it 'reports the batch size rather than dumping the array' do
      assert_equal '2 items', tool.describe_call('items' => %w[one two])
      assert_equal 'TaskCreate', tool.display_name
    end
  end

  describe 'execution' do
    it 'adds each element as a pending item and returns the rendered list with ids' do
      out = tool.run('items' => %w[first second third]).to_s
      assert_equal 3, list.size
      assert_equal %w[first second third], list.items.map(&:content)
      assert list.items.all? { |i| i.status == 'pending' }
      assert out.include?('- #1 [pending] first'), out
      assert out.include?('- #2 [pending] second'), out
    end

    it 'accepts numeric elements, auto-converted to strings by the validation layer' do
      out = tool.run('items' => ['Fix issue', 42]).to_s
      assert_equal ['Fix issue', '42'], list.items.map(&:content)
      assert out.include?('- #2 [pending] 42'), out
    end

    it 'strips whitespace on each element' do
      tool.run('items' => ['  first  ', "second\n"])
      assert_equal %w[first second], list.items.map(&:content)
    end

    it 'rejects an empty array and adds nothing' do
      out = tool.run('items' => []).to_s
      assert out.start_with?('Error: task_create requires at least one item'), out
      assert list.empty?
    end

    it 'rejects a blank element, naming its index, and adds nothing (atomic)' do
      out = tool.run('items' => ['first', '   ', 'third']).to_s
      assert out.start_with?('Error: blank item at index 1'), out
      assert list.empty?
    end

    it 'rejects a JSON-encoded array String at the validation layer' do
      out = tool.run('items' => '["first", "second"]').to_s
      assert out.start_with?('Error:'), out
      assert_match(/must be an array of strings/, out)
      assert list.empty?
    end

    it 'rejects a duplicate within the batch and adds nothing (atomic)' do
      out = tool.run('items' => %w[a b a]).to_s
      assert out.start_with?('Error: duplicate item in batch:'), out
      assert out.include?("'a'"), out
      assert list.empty?
    end

    it 'rejects when an item already exists in the list and adds nothing (atomic)' do
      list.add('existing')
      out = tool.run('items' => %w[fresh existing also-fresh]).to_s
      assert out.start_with?("Error: task already exists: 'existing'"), out
      assert_equal %w[existing], list.items.map(&:content)
    end
  end
end
