# frozen_string_literal: true

require 'timeout'
require 'pikuri/testing'

# Runs the real Agent against pikuri's scripted transport: every turn below is a
# real run_loop on a conversation's own thread, held open with a Gate where a
# test needs it running.
RSpec.describe Pikuri::Conversations::Conversation do
  Event = Pikuri::Conversations::Event

  # Records every event, agent's and conversation's alike, for #await to wait on.
  class Recorder < Pikuri::Agent::Listener::Base
    attr_reader :events

    def initialize
      super
      @events = []
      @lock = Mutex.new
      @cv = ConditionVariable.new
    end

    def on_event(event)
      @lock.synchronize do
        @events << event
        @cv.broadcast
      end
    end

    # Wait for the +nth+ event of +klass+ (counting from the start) and return it.
    def await(klass, nth: 1, timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @lock.synchronize do
        loop do
          found = @events.grep(klass)
          return found[nth - 1] if found.size >= nth

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise "timed out waiting for #{klass} ##{nth}; saw #{@events.map(&:class)}" if remaining <= 0

          @cv.wait(@lock, remaining)
        end
      end
    end

    def all(klass) = @lock.synchronize { @events.grep(klass) }
  end

  let(:recorder) { Recorder.new }
  let(:saved) { Queue.new }
  let(:configure) { nil }
  let(:convs) do
    Pikuri::Conversations.new(system_prompt: 'test', configure:, streaming: false,
                              on_turn_end: ->(conv, history) { saved << [conv.id, history] })
  end

  # A Gate that also says when a response has parked in it, so a test knows the
  # turn is running before it acts.
  let(:parked) { Queue.new }
  let(:gate) do
    g = Pikuri::Testing::Gate.new
    q = parked
    g.define_singleton_method(:await) do
      q << true
      super()
    end
    g
  end

  after { convs.shutdown(timeout: 5) }

  def contents(history) = history.messages.map(&:content)

  def open(transport, **opts)
    convs.open(id: 'c1', transport:, listener: recorder, **opts)
  end

  it 'boots, runs a turn, saves before going idle' do
    conv = open(Pikuri::Testing.fake_transport { |llm| llm.reply('Keep it cool.') })
    recorder.await(Event::Ready)
    assert_equal :idle, conv.status.state

    assert_equal :started, conv.submit('how do I keep an avocado?')
    ended = recorder.await(Event::TurnEnded)
    assert_equal :completed, ended.outcome
    refute ended.restarting

    id, history = saved.pop
    assert_equal 'c1', id
    assert_equal ['how do I keep an avocado?', 'Keep it cool.'], contents(history)
    assert_equal :idle, conv.status.state
    assert_equal history, conv.history
  end

  it 'injects a message sent mid-turn and restarts a bare turn to deliver it' do
    transport = Pikuri::Testing.fake_transport(gate:) do |llm|
      llm.reply('one')
      llm.reply('two')
    end
    conv = open(transport)
    recorder.await(Event::Ready)
    gate.block!
    assert_equal :started, conv.submit('first')
    parked.pop

    assert_equal :injected, conv.submit('second')
    assert_equal :ignored, conv.submit('  ')
    assert_equal 1, conv.status.pending
    gate.release!

    assert recorder.await(Event::TurnEnded).restarting
    refute recorder.await(Event::TurnEnded, nth: 2).restarting
    assert_equal %w[first one second two], contents(conv.history)
    assert_equal [1, 0], recorder.all(Event::PendingChanged).map(&:count)
    mid = recorder.all(Pikuri::Agent::Event::UserTurn).map { [_1.content, _1.mid_loop] }
    assert_equal [['first', false], ['second', true]], mid
  end

  it 'keeps an undelivered message across a cancel, and a blank submit re-sends it' do
    transport = Pikuri::Testing.fake_transport(gate:) do |llm|
      llm.tool_call('calculator', expression: '1 + 1')
      llm.reply('done')
    end
    convs = Pikuri::Conversations.new(system_prompt: 'test', streaming: false,
                                      configure: ->(c, _) { c.add_tool(Pikuri::Tool::CALCULATOR) })
    conv = convs.open(id: 'c1', transport:, listener: recorder)
    recorder.await(Event::Ready)
    gate.block!
    conv.submit('first')
    parked.pop
    conv.submit('actually, second')
    assert_equal :cancelled, conv.cancel
    gate.release!

    assert_equal :cancelled, recorder.await(Event::TurnEnded).outcome
    assert_equal ['actually, second'], conv.pending.map(&:content)
    assert_equal :started, conv.submit
    assert_equal :completed, recorder.await(Event::TurnEnded, nth: 2).outcome
    assert_equal 'done', conv.history.messages.last.content
    assert_equal :ignored, conv.submit
  ensure
    convs&.shutdown(timeout: 5)
  end

  it 'stays :new until the first message, then runs it as an ordinary turn' do
    resumed = Pikuri::Agent::History.new(
      messages: [Pikuri::Agent::History::Message.new(id: Pikuri::Agent::History.mint_id, role: 'user', content: 'earlier')]
    )
    conv = open(Pikuri::Testing.fake_transport { |llm| llm.reply('hi') }, history: resumed, boot: false)
    assert_equal :new, conv.status.state
    assert_equal ['earlier'], contents(conv.history)
    assert_nil conv.trifecta

    assert_equal :started, conv.submit('hello')
    recorder.await(Event::TurnEnded)
    assert_equal %w[earlier hello hi], contents(conv.history)
    assert_equal [false], recorder.all(Pikuri::Agent::Event::UserTurn).map(&:mid_loop)
    refute_nil conv.trifecta
  end

  it 'applies a model switch at the next turn, last pick wins' do
    first = Pikuri::Testing.fake_transport(model: 'a') { |llm| llm.reply('from a') }
    second = Pikuri::Testing.fake_transport(model: 'b') { |llm| llm.reply('from b') }
    third = Pikuri::Testing.fake_transport(model: 'c')
    conv = open(first)
    recorder.await(Event::Ready)

    assert_equal :selected, conv.switch_model(third)
    assert_equal :selected, conv.switch_model(second)
    assert_equal 'a', conv.status.model.model
    assert_equal 'b', conv.status.next_model.model

    conv.submit('hi')
    recorder.await(Event::TurnEnded)
    assert_equal 'from b', conv.history.messages.last.content
    assert_equal 'b', conv.status.model.model
    assert_equal ['c', 'b', nil], recorder.all(Event::ModelPending).map { _1.transport&.model }
  end

  it 'undoes a pick when the current model is picked again' do
    first = Pikuri::Testing.fake_transport(model: 'a')
    conv = open(first)
    conv.switch_model(Pikuri::Testing.fake_transport(model: 'b'))
    conv.switch_model(first)
    assert_equal 'a', conv.status.next_model.model
  end

  it 'refuses an attachment the next model states it cannot take' do
    conv = open(Pikuri::Testing.fake_transport(modalities: { vision: false }), boot: false)
    png = Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: 'png'.b)
    assert_raises(Pikuri::Agent::UnsupportedAttachmentError) { conv.submit('look', attachments: [png]) }
    assert_equal :new, conv.status.state
    assert_equal 0, conv.status.pending
  end

  context 'closing' do
    it 'refuses while a turn runs, and with force closes without saving' do
      conv = open(Pikuri::Testing.fake_transport(gate:) { |llm| llm.reply('late') })
      recorder.await(Event::Ready)
      gate.block!
      conv.submit('hi')
      parked.pop

      assert_equal :busy, conv.close
      assert_equal :busy, conv.clear
      assert_equal :closing, conv.close(force: true)
      assert_equal :discarded, conv.submit('more')
      gate.release!

      recorder.await(Event::Closed)
      assert saved.empty?
      assert_equal :closed, conv.status.state
      assert_nil convs['c1']
    end

    it 'closes an idle conversation at once' do
      conv = open(Pikuri::Testing.fake_transport)
      recorder.await(Event::Ready)
      assert_equal :closed, conv.close
      assert conv.wait_closed(5)
      assert_equal :discarded, conv.switch_model(Pikuri::Testing.fake_transport(model: 'b'))
      assert_equal :closed, conv.close
    end

    it 'shuts the whole list down, waiting for the agents' do
      open(Pikuri::Testing.fake_transport)
      convs.open(id: 'c2', transport: Pikuri::Testing.fake_transport, listener: Recorder.new, boot: false)
      assert convs.shutdown(timeout: 5)
      assert_equal [], convs.to_a
    end
  end

  it 'clears into a fresh agent with an empty history' do
    conv = open(Pikuri::Testing.fake_transport { |llm| llm.reply('one') })
    recorder.await(Event::Ready)
    conv.submit('hi')
    recorder.await(Event::TurnEnded)

    assert_equal :cleared, conv.clear
    recorder.await(Event::Ready, nth: 2)
    assert_nil conv.history
    assert_equal :idle, conv.status.state
  end

  context 'when the agent fails to boot' do
    let(:attempts) { [] }
    let(:configure) do
      tries = attempts
      lambda do |_c, _conv|
        tries << true
        raise 'MCP server down' if tries.size == 1
      end
    end

    it 'reports it, keeps the message, and boots again on the next submit' do
      conv = open(Pikuri::Testing.fake_transport { |llm| llm.reply('hi') }, boot: false)
      assert_equal :started, conv.submit('hello')
      assert_equal 'MCP server down', recorder.await(Event::BootFailed).error.message
      assert_equal :new, conv.status.state
      assert_equal 1, conv.status.pending

      assert_equal :started, conv.submit
      recorder.await(Event::TurnEnded)
      assert_equal %w[hello hi], contents(conv.history)
    end
  end
end
