# frozen_string_literal: true

require 'timeout'
require 'pikuri/testing'

# Runs the real Agent against pikuri's scripted transport: every turn below is a
# real run_loop on a conversation's own thread, held open with a Gate where a
# test needs it running.
RSpec.describe Pikuri::Conversations::Conversation do
  Event = Pikuri::Conversations::Event

  # Records every event, agent's and conversation's alike, and the thread it came
  # on, for #await to wait on.
  class Recorder < Pikuri::Agent::Listener::Base
    attr_reader :events, :threads

    def initialize
      super
      @events = []
      @threads = []
      @lock = Mutex.new
      @cv = ConditionVariable.new
    end

    def on_event(event)
      @lock.synchronize do
        @events << event
        @threads << Thread.current
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

  # RateLimitedListener flushes on TurnEnded without a lock, relying on this.
  it "ends a failed turn on the thread its agent's last event came on" do
    conv = open(Pikuri::Testing.fake_transport { |_llm| }) # no reply scripted: the request raises
    recorder.await(Event::Ready)
    conv.submit('hello')
    ended = recorder.await(Event::TurnEnded)
    assert_equal :failed, ended.outcome

    at = recorder.events.index(ended)
    last_agent = recorder.events[0...at].rindex { |e| e.class.name.start_with?('Pikuri::Agent::Event::') }
    assert_equal recorder.threads[last_agent], recorder.threads[at]
    refute_equal Thread.current, recorder.threads[at]
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

  context 'a system: block with the message' do
    # What the model was handed, in order: [:system, text] and [:user, text].
    def handed
      recorder.events.filter_map do |event|
        case event
        in Pikuri::Agent::Event::SystemInjected(content:) then [:system, content]
        in Pikuri::Agent::Event::UserTurn(content:) then [:user, content]
        else nil
        end
      end
    end

    it 'goes ahead of the message in one turn from idle' do
      conv = open(Pikuri::Testing.fake_transport { |llm| llm.reply('done') })
      recorder.await(Event::Ready)

      assert_equal :started, conv.submit('extract page 3', system: ['SKILL'])
      refute recorder.await(Event::TurnEnded).restarting
      assert_equal [[:system, 'SKILL'], [:user, 'extract page 3']], handed
      assert_equal 1, recorder.all(Event::TurnStarted).size
    end

    it 'goes ahead of the message into a running turn' do
      transport = Pikuri::Testing.fake_transport(gate:) do |llm|
        llm.reply('one')
        llm.reply('two')
      end
      conv = open(transport)
      recorder.await(Event::Ready)
      gate.block!
      conv.submit('first')
      parked.pop

      assert_equal :injected, conv.submit('second', system: ['SKILL'])
      gate.release!
      refute recorder.await(Event::TurnEnded, nth: 2).restarting
      assert_equal [[:user, 'first'], [:system, 'SKILL'], [:user, 'second']], handed
    end

    it 'waits ahead of the message for an agent still to boot' do
      conv = open(Pikuri::Testing.fake_transport { |llm| llm.reply('done') }, boot: false)

      assert_equal :started, conv.submit('extract page 3', system: ['SKILL'])
      refute recorder.await(Event::TurnEnded).restarting
      assert_equal [[:system, 'SKILL'], [:user, 'extract page 3']], handed
    end

    it 'runs a bare turn to deliver a block sent alone' do
      conv = open(Pikuri::Testing.fake_transport { |llm| llm.reply('loaded') })
      recorder.await(Event::Ready)

      assert_equal :started, conv.submit(system: ['SKILL'])
      assert_equal :completed, recorder.await(Event::TurnEnded).outcome
      assert_equal [[:system, 'SKILL']], handed
    end

    it 'refuses a blank block, queueing nothing' do
      conv = open(Pikuri::Testing.fake_transport, boot: false)
      assert_raises(ArgumentError) { conv.submit('hello', system: ['  ']) }
      assert_equal 0, conv.status.pending
    end
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

  it 'boots on #boot after opening with boot: false, and only once' do
    conv = open(Pikuri::Testing.fake_transport, boot: false)
    assert_empty recorder.events

    conv.boot
    recorder.await(Event::Ready)
    conv.boot
    assert_equal :idle, conv.status.state
    assert_equal 1, recorder.all(Event::Booting).size
  end

  it 'settles only once the listener has heard TurnEnded, though idle before' do
    held = Queue.new
    recorder.define_singleton_method(:on_event) do |event|
      held.pop if event.is_a?(Event::TurnEnded)
      super(event)
    end
    conv = open(Pikuri::Testing.fake_transport { |llm| llm.reply('hi') })
    assert conv.wait_settled(5)
    assert_equal :idle, conv.status.state

    conv.submit('hello')
    Timeout.timeout(5) { sleep 0.005 until conv.status.state == :idle }
    refute conv.wait_settled(0.05)
    held << true
    assert conv.wait_settled(5)
    assert_equal 1, recorder.all(Event::TurnEnded).size
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
    it 'refuses while a turn runs, and with force cancels it, saves it, then closes' do
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
      # Pushed before the agent's release began, so present by Closed.
      refute saved.empty?, 'the cut turn was not saved before Closed'
      _, history = saved.pop
      assert_equal 'hi', history.messages.first.content
      assert_equal :closed, conv.status.state
      assert_nil convs['c1']
    end

    it 'saves a running turn on shutdown before releasing its agent' do
      conv = open(Pikuri::Testing.fake_transport(gate:) { |llm| llm.reply('late') })
      recorder.await(Event::Ready)
      gate.block!
      conv.submit('hi')
      parked.pop

      refute convs.shutdown(timeout: 0)
      gate.release!

      assert convs.shutdown(timeout: 5)
      assert_equal 1, saved.size
      assert_equal :closed, conv.status.state
    end

    it 'returns from shutdown only once the listener has heard Closed' do
      hearing = Queue.new
      hold = Queue.new
      recorder.define_singleton_method(:on_event) do |event|
        super(event)
        next unless event.is_a?(Event::Closed)

        hearing << true
        hold.pop
      end
      open(Pikuri::Testing.fake_transport)
      recorder.await(Event::Ready)

      shutdown = Thread.new { convs.shutdown(timeout: 5) }
      hearing.pop
      refute shutdown.join(0.2), 'shutdown returned while Closed was still being heard'
      hold << true
      assert shutdown.value
    ensure
      hold << true
    end

    it 'closes an idle conversation at once' do
      conv = open(Pikuri::Testing.fake_transport)
      recorder.await(Event::Ready)
      assert_equal :closed, conv.close
      assert conv.wait_closed(5)
      assert_equal :discarded, conv.switch_model(Pikuri::Testing.fake_transport(model: 'b'))
      assert_equal :closed, conv.close
    end

    context 'while booting' do
      # The boot parks in its probe until released, as against a server that
      # does not answer; a transport stating no modalities is what asks.
      let(:probe_gate) { Queue.new }
      let(:built) { Queue.new }
      let(:configure) { ->(_c, _conv) { built << true } }
      let(:transport) { Pikuri::Testing.fake_transport(modalities: nil) { |llm| llm.reply('hi') } }

      before do
        gate = probe_gate
        detector.define_singleton_method(:detect_modalities) do |*, **|
          gate.pop
          nil
        end
      end

      it 'closes a boot nothing waits on, without building the agent' do
        conv = open(transport)
        assert_equal :booting, conv.status.state

        assert_equal :closing, conv.close
        assert_equal :discarded, conv.submit('hello')
        probe_gate << true

        recorder.await(Event::Closed)
        assert built.empty?
        assert_empty recorder.all(Event::Ready)
        assert_equal :closed, conv.status.state
      end

      it 'refuses a boot a message waits on' do
        conv = open(transport)
        conv.submit('hello')

        assert_equal :busy, conv.close
        probe_gate << true
        assert_equal :completed, recorder.await(Event::TurnEnded).outcome
      end

      it 'is busy while a message waits on the boot, and not once a cancel ends it' do
        conv = open(transport)
        refute conv.status.busy?
        conv.submit('hello')
        assert conv.status.busy?

        conv.cancel
        probe_gate << true
        recorder.await(Event::Ready)
        refute conv.status.busy?
        assert_equal 1, conv.status.pending
        assert_empty recorder.all(Event::TurnEnded)
      end
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
    restarts = recorder.events.map(&:class).select { [Event::Cleared, Event::Booting].include?(_1) }
    assert_equal [Event::Booting, Event::Cleared, Event::Booting], restarts
  end

  context 'clearing while booting' do
    let(:resumed) do
      Pikuri::Agent::History.new(
        messages: [Pikuri::Agent::History::Message.new(id: Pikuri::Agent::History.mint_id, role: 'user', content: 'earlier')]
      )
    end
    # Each build records the history it was handed, and the first one parks
    # until released.
    let(:built) { Queue.new }
    let(:build_gate) { Queue.new }
    let(:configure) do
      histories = built
      gate = build_gate
      builds = 0
      lambda do |c, _conv|
        builds += 1
        histories << c.history
        gate.pop if builds == 1
      end
    end

    def restarts = recorder.events.map(&:class).select { [Event::Cleared, Event::Booting, Event::Ready].include?(_1) }

    it 'builds from the cleared history when the clear lands during the probe' do
      probe_gate = Queue.new
      detector.define_singleton_method(:detect_modalities) do |*, **|
        probe_gate.pop
        nil
      end
      build_gate << true
      conv = open(Pikuri::Testing.fake_transport(modalities: nil), history: resumed)

      assert_equal :cleared, conv.clear
      probe_gate << true
      recorder.await(Event::Ready)

      assert_equal [nil], drain(built)
      assert_nil conv.history
      assert_equal :idle, conv.status.state
      assert_equal [Event::Booting, Event::Cleared, Event::Booting, Event::Ready], restarts
    end

    it 'builds again when the clear lands during the build' do
      conv = open(Pikuri::Testing.fake_transport, history: resumed)
      first = built.pop

      assert_equal :cleared, conv.clear
      build_gate << true
      recorder.await(Event::Ready)
      assert conv.wait_settled(5)

      assert_equal ['earlier'], contents(first)
      assert_equal [nil], drain(built)
      assert_nil conv.history
      assert_equal [Event::Booting, Event::Cleared, Event::Booting, Event::Ready], restarts
    end
  end

  it 'reports a clear with no agent to replace, though nothing boots' do
    resumed = Pikuri::Agent::History.new(
      messages: [Pikuri::Agent::History::Message.new(id: Pikuri::Agent::History.mint_id, role: 'user', content: 'earlier')]
    )
    conv = open(Pikuri::Testing.fake_transport, history: resumed, boot: false)

    assert_equal :cleared, conv.clear
    assert_equal [Event::Cleared], recorder.events.map(&:class)
    assert_nil conv.history
    assert_equal :new, conv.status.state
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

  context 'titling' do
    let(:titling) { Queue.new }
    let(:titler_gate) do
      g = Pikuri::Testing::Gate.new
      q = titling
      g.define_singleton_method(:await) do
        q << true
        super()
      end
      g
    end
    let(:titler) do
      Pikuri::Conversations::Titler.new(
        transport: Pikuri::Testing.fake_transport(model: 'titler', gate: titler_gate) { |llm| llm.reply('Keeping An Avocado') }
      )
    end
    let(:convs) do
      Pikuri::Conversations.new(system_prompt: 'test', streaming: false, titler:,
                                on_turn_end: ->(conv, history) { saved << [conv.id, history] })
    end

    def chat(*replies)
      Pikuri::Testing.fake_transport { |llm| replies.each { llm.reply(_1) } }
    end

    it 'names an untitled conversation once its first turn has ended, once' do
      conv = open(chat('Keep it cool.', 'Yes.'), untitled: true)
      conv.submit('how do I keep an avocado?')
      assert_equal 'Keeping An Avocado', recorder.await(Event::Titled).title
      ended = recorder.events.index { _1.is_a?(Event::TurnEnded) }
      assert_operator ended, :<, recorder.events.index { _1.is_a?(Event::Titled) }

      conv.submit('and ripe?')
      assert conv.wait_settled(5)
      assert_equal 2, recorder.all(Event::TurnEnded).size
      assert_equal 1, recorder.all(Event::Titled).size
    end

    it 'settles only once the title has landed' do
      titler_gate.block!
      conv = open(chat('Keep it cool.'), untitled: true)
      conv.submit('how do I keep an avocado?')
      titling.pop
      refute conv.wait_settled(0.05)

      titler_gate.release!
      assert conv.wait_settled(5)
      assert_equal 1, recorder.all(Event::Titled).size
    ensure
      titler_gate.release!
    end

    it 'titles a resumed conversation from its own opener' do
      resumed = Pikuri::Agent::History.new(
        messages: [Pikuri::Agent::History::Message.new(id: Pikuri::Agent::History.mint_id, role: 'user',
                                                       content: 'how do I keep an avocado?')]
      )
      conv = open(chat('Cool it.'), history: resumed, untitled: true)
      conv.submit('remind me')
      assert_equal 'Keeping An Avocado', recorder.await(Event::Titled).title
    end

    it 'leaves a conversation that has a name alone' do
      conv = open(chat('Keep it cool.'))
      conv.submit('how do I keep an avocado?')
      assert conv.wait_settled(5)
      assert_equal 1, recorder.all(Event::TurnEnded).size
      assert_empty recorder.all(Event::Titled)
    end

    it 'drops a title that lands after the conversation closed' do
      titler_gate.block!
      conv = open(chat('Keep it cool.'), untitled: true)
      conv.submit('how do I keep an avocado?')
      titling.pop
      assert_equal :closed, conv.close
      titler_gate.release!
      assert conv.wait_settled(5)
      assert_equal 1, recorder.all(Event::Closed).size
      assert_empty recorder.all(Event::Titled)
    ensure
      titler_gate.release!
    end

    it 'hears out a title that passed before the close, ahead of Closed and of shutdown returning' do
      hearing = Queue.new
      hold = Queue.new
      recorder.define_singleton_method(:on_event) do |event|
        super(event)
        next unless event.is_a?(Event::Titled)

        hearing << true
        hold.pop
      end
      open(chat('Keep it cool.'), untitled: true).submit('how do I keep an avocado?')
      hearing.pop
      recorder.await(Event::TurnEnded)

      shutdown = Thread.new { convs.shutdown(timeout: 5) }
      refute shutdown.join(0.2), 'shutdown returned while Titled was still being heard'
      hold << true
      assert shutdown.value
      assert_equal [Event::Titled, Event::Closed],
                   recorder.events.map(&:class).select { [Event::Titled, Event::Closed].include?(_1) }
    ensure
      hold << true
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
      # A retry is a boot, not a fresh start: the error line stays on screen.
      assert_equal 2, recorder.all(Event::Booting).size
      assert_empty recorder.all(Event::Cleared)
    end
  end
end
