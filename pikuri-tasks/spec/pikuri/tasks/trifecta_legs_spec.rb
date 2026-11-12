# frozen_string_literal: true

RSpec.describe 'task tool trifecta legs' do
  let(:list) { Pikuri::Tasks::List.new }

  it 'gives every task tool no legs — an in-memory list reads and sends nothing' do
    tools = [Pikuri::Tasks::Create.new(list: list),
             Pikuri::Tasks::Delete.new(list: list),
             Pikuri::Tasks::Completed.new(list: list),
             Pikuri::Tasks::InProgress.new(list: list)]
    tools.each { |t| assert_equal Pikuri::Tool::TrifectaLegs::NONE, t.trifecta_legs, t.name }
  end
end
