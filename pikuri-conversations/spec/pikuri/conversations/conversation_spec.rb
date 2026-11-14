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

  # The probe dials /props for real; every example answers it here instead, and
  # records what was asked.
  let(:detector) { Pikuri::Conversations::Probe::Detector }
  let(:probed) { Queue.new }
  let(:props) { detector::Props::NONE }
  let(:looked_up) { nil }

  before do
    @detect = detector.method(:detect)
    @detect_modalities = detector.method(:detect_modalities)
    log = probed
    full = props
    cheap = looked_up
    detector.define_singleton_method(:detect) do |transport, **|
      log << [:detect, transport.model]
      full
    end
    detector.define_singleton_method(:detect_modalities) do |transport, **|
      log << [:modalities, transport.model]
      cheap
    end
  end

  after do
    convs.shutdown(timeout: 5)
    detect = @detect
    detect_modalities = @detect_modalities
    detector.define_singleton_method(:detect) { |*a, **k| detect.call(*a, **k) }
    detector.define_singleton_method(:detect_modalities) { |*a, **k| detect_modalities.call(*a, **k) }
    Pikuri::Conversations::Probe.reset!
    Pikuri::Conversations::Throttle.reset!
  end

  def drain(queue) = Array.new(queue.size) { queue.pop }

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
    assert_equal 1, conv.status.pending
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

  context 'the throttle' do
    let(:server) { 'http://throttled.invalid/v1' }

    # Counts the requests inside the HTTP call at once: Gate#await runs inside
    # the adapter, so inside the permit.
    let(:counting_gate) do
      Class.new(Pikuri::Testing::Gate) do
        attr_reader :peak, :in_flight

        def initialize
          super
          @counter = Mutex.new
          @in_flight = 0
          @peak = 0
        end

        def await
          @counter.synchronize { @peak = [@peak, @in_flight += 1].max }
          super
        ensure
          @counter.synchronize { @in_flight -= 1 }
        end
      end.new
    end

    it 'queues the turns of many conversations against a server sized to one' do
      Pikuri::Conversations::Throttle.limit(server, 1)
      gate = counting_gate
      gate.block!
      recorders = Array.new(3) { Recorder.new }
      conversations = recorders.each_with_index.map do |rec, i|
        transport = Pikuri::Testing.fake_transport(api_base: server, gate:) { |llm| llm.reply("answer #{i}") }
        convs.open(id: "c#{i}", transport:, listener: rec)
      end
      recorders.each { _1.await(Event::Ready) }
      conversations.each { _1.submit('hi') }

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.01 until gate.in_flight == 1 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
      assert_equal 1, gate.in_flight, 'a second request got past the permit'
      gate.release!

      recorders.each { assert_equal :completed, _1.await(Event::TurnEnded).outcome }
      assert_equal 1, gate.peak
    ensure
      gate&.release!
    end

    context 'sized by the probe' do
      let(:props) { detector::Props.new(n_ctx: 16_384, total_slots: 2, modalities: { vision: true }) }

      it "seeds the server's permits and the model's facts at the first turn, once" do
        transport = Pikuri::Testing.fake_transport(api_base: server, context_window: nil) do |llm|
          llm.reply('one')
          llm.reply('two')
        end
        conv = open(transport)
        recorder.await(Event::Ready)
        refute Pikuri::Conversations::Throttle.sized?(server)
        assert_nil conv.status.model.context_window

        conv.submit('hi')
        recorder.await(Event::TurnEnded)
        conv.submit('again')
        recorder.await(Event::TurnEnded, nth: 2)

        assert_equal({ 'http://throttled.invalid' => 2 }, Pikuri::Conversations::Throttle.sizes)
        assert_equal 16_384, conv.status.model.context_window
        assert_equal [[:detect, 'fake-model']], drain(probed)
        # Unknown at boot, learnt at the first turn ahead of its tokens, not
        # repeated at the second.
        assert_equal [nil, 16_384], recorder.all(Event::ContextCap).map(&:cap)
        first_tokens = recorder.events.index { _1.is_a?(Pikuri::Agent::Event::Tokens) }
        assert_operator recorder.events.index(Event::ContextCap.new(cap: 16_384)), :<, first_tokens
        # The agent adopted the learnt cap as the same model, not a switch.
        assert_empty recorder.all(Pikuri::Agent::Event::ModelSwitched)
      end

      it "announces a picked model's cap at its first turn" do
        first = Pikuri::Testing.fake_transport(api_base: server, model: 'a', context_window: 4096) { |llm| llm.reply('a') }
        second = Pikuri::Testing.fake_transport(api_base: server, model: 'b', context_window: nil) { |llm| llm.reply('b') }
        conv = open(first)
        recorder.await(Event::Ready)
        conv.switch_model(second)
        conv.submit('hi')
        recorder.await(Event::TurnEnded)
        assert_equal [4096, 16_384], recorder.all(Event::ContextCap).map(&:cap)
        assert_equal 1, recorder.all(Pikuri::Agent::Event::ModelSwitched).size
      end

      it 'leaves a host-set limit alone' do
        Pikuri::Conversations::Throttle.limit(server, 1)
        conv = open(Pikuri::Testing.fake_transport(api_base: server, context_window: nil) { |llm| llm.reply('one') })
        recorder.await(Event::Ready)
        conv.submit('hi')
        recorder.await(Event::TurnEnded)
        assert_equal 1, Pikuri::Conversations::Throttle.for(server).permits
      end
    end

    it 'asks nothing when the cap and inputs are stated and the server is sized' do
      Pikuri::Conversations::Throttle.limit(server, 1)
      conv = open(Pikuri::Testing.fake_transport(api_base: server) { |llm| llm.reply('one') })
      recorder.await(Event::Ready)
      conv.submit('hi')
      recorder.await(Event::TurnEnded)
      assert_empty drain(probed)
    end
  end

  context 'when the transport states no inputs' do
    let(:looked_up) { { vision: false } }

    it 'looks them up at boot, without loading the model, and refuses an image up front' do
      conv = open(Pikuri::Testing.fake_transport(modalities: nil))
      recorder.await(Event::Ready)
      assert_equal [[:modalities, 'fake-model']], drain(probed)
      assert_equal({ vision: false }, conv.status.next_model.modalities)

      png = Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: 'png'.b)
      assert_raises(Pikuri::Agent::UnsupportedAttachmentError) { conv.submit('look', attachments: [png]) }
    end
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
