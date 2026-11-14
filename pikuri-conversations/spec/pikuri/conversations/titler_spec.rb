# frozen_string_literal: true

require 'pikuri/testing'

RSpec.describe Pikuri::Conversations::Titler do
  def title(reply)
    transport = Pikuri::Testing.fake_transport { |llm| llm.reply(reply) }
    described_class.new(transport:).title_for('how do I keep an avocado?')
  end

  it 'answers the model’s line' do
    assert_equal 'Keeping An Avocado Fresh', title('Keeping An Avocado Fresh')
  end

  it 'drops leaked reasoning up to its close tag, and the blank line after it' do
    assert_equal 'Keeping An Avocado Fresh', title("<think>the user wants\na title</think>\n\nKeeping An Avocado Fresh")
    assert_equal 'Keeping An Avocado Fresh', title("so a title...</think>\nKeeping An Avocado Fresh")
  end

  it 'keeps the first line, capped at seven words and eighty characters' do
    assert_equal 'One Two Three Four Five Six Seven', title("One Two Three Four Five Six Seven Eight\nsecond line")
    long = title('Pneumonoultramicroscopicsilicovolcanoconiosis ' * 3)
    assert_operator long.length, :<=, described_class::MAX_CHARS
  end

  it 'answers nil when the model said nothing usable' do
    assert_nil title("<think>pondering</think>\n\n   \n")
  end

  it 'queues its request on the throttle like any turn' do
    server = 'http://titler.invalid/v1'
    Pikuri::Conversations::Throttle.limit(server, 1)
    seen = []
    sem = Pikuri::Conversations::Throttle.for(server)
    # Runs inside the HTTP call, so it sees the permit the request holds.
    probe = Class.new(Pikuri::Testing::Gate) do
      define_method(:await) { seen << sem.available }
    end.new
    transport = Pikuri::Testing.fake_transport(api_base: server, gate: probe) { |llm| llm.reply('A Title') }
    described_class.new(transport:).title_for('hello')
    assert_equal [0], seen
  ensure
    Pikuri::Conversations::Throttle.reset!
  end
end
