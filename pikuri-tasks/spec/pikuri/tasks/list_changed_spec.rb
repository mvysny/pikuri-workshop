# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::ListChanged do
  let(:item) { ->(id, content, status) { Pikuri::Tasks::Item.new(id: id, content: content, status: status) } }

  describe '#to_s' do
    it 'says none for an empty list, as after a clear' do
      assert_equal 'tasks: none', described_class.new(items: []).to_s
    end

    it 'counts the done tasks and names the one in progress' do
      event = described_class.new(items: [item.(1, 'read the code', 'completed'),
                                          item.(2, 'write the spec', 'in_progress'),
                                          item.(3, 'run it', 'pending')])
      assert_equal 'tasks: 1/3 done, now: write the spec', event.to_s
    end

    it 'leaves out "now" when nothing is in progress' do
      event = described_class.new(items: [item.(1, 'run it', 'pending')])
      assert_equal 'tasks: 0/1 done', event.to_s
    end
  end
end
