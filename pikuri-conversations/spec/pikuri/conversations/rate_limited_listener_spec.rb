# frozen_string_literal: true

RSpec.describe Pikuri::Conversations::RateLimitedListener do
  let(:inner) { Pikuri::Agent::Listener::InMemoryEventList.new }
  let(:clock_time) { [0.0] }
  let(:listener) { described_class.new(inner, fps: 10, clock: -> { clock_time[0] }) }

  def advance(seconds) = clock_time[0] += seconds
  def assistant_delta(text) = Pikuri::Agent::Event::AssistantDelta.new(content: text)
  def thinking_delta(text) = Pikuri::Agent::Event::ThinkingDelta.new(content: text)
  def contents = inner.events.map(&:content)

  it 'flushes the first delta at once, then coalesces the rest of the period into one event' do
    listener.on_event(assistant_delta('hel'))
    advance(0.05)
    listener.on_event(assistant_delta('lo'))
    assert_equal ['hel'], contents

    advance(0.06) # crosses the 0.1 s tick
    listener.on_event(assistant_delta('!'))
    assert_equal %w[hel lo!], contents
  end

  it 'buffers assistant and thinking deltas apart' do
    listener.on_event(assistant_delta('A1'))
    listener.on_event(thinking_delta('T1'))
    advance(0.1)
    listener.on_event(assistant_delta('A2'))

    assert_equal %w[A1 A2], inner.events.grep(Pikuri::Agent::Event::AssistantDelta).map(&:content)
    assert_equal %w[T1], inner.events.grep(Pikuri::Agent::Event::ThinkingDelta).map(&:content)
  end

  it 'flushes the first delta at once even after a long idle start' do
    advance(5.0)
    listener.on_event(assistant_delta('a'))
    assert_equal ['a'], contents
  end

  it 'catches up past missed ticks after a long pause instead of backlogging them' do
    advance(5.0)
    listener.on_event(assistant_delta('a'))
    advance(0.05)
    listener.on_event(assistant_delta('b'))
    assert_equal ['a'], contents
  end

  it 'drops a buffered delta when its own bookend arrives — the bookend carries the whole text' do
    listener.on_event(assistant_delta('A1'))
    listener.on_event(assistant_delta('A2'))
    listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'A1A2'))
    assert_equal %w[A1 A1A2], contents
  end

  it "flushes the other stream's buffer at a bookend, dropping only its own" do
    listener.on_event(thinking_delta('T1'))
    listener.on_event(assistant_delta('A1'))
    listener.on_event(thinking_delta('T2'))
    listener.on_event(assistant_delta('A2'))
    thinking = Pikuri::Agent::Event::Thinking.new(content: 'T1T2')
    listener.on_event(thinking)

    assert_equal [thinking_delta('T1'), assistant_delta('A1A2'), thinking], inner.events
  end

  it 'flushes thinking, then assistant, ahead of any other agent event' do
    listener.on_event(thinking_delta('T0'))
    listener.on_event(thinking_delta('T1'))
    listener.on_event(assistant_delta('A1'))
    cancelled = Pikuri::Agent::Event::Cancelled.new
    listener.on_event(cancelled)

    assert_equal [thinking_delta('T0'), thinking_delta('T1'), assistant_delta('A1'), cancelled], inner.events
  end

  it "flushes ahead of an extension's own event, which comes on the agent's thread too" do
    listener.on_event(assistant_delta('A0'))
    listener.on_event(assistant_delta('A1'))
    own = Data.define(:note).new(note: 'indexed')
    listener.on_event(own)

    assert_equal [assistant_delta('A0'), assistant_delta('A1'), own], inner.events
  end

  it 'sends no empty delta ahead of an event when nothing is buffered' do
    cancelled = Pikuri::Agent::Event::Cancelled.new
    listener.on_event(cancelled)
    assert_equal [cancelled], inner.events
  end

  # PendingChanged comes from the thread the user types on, mid-reply; touching
  # the buffers from there would race the turn thread's flush.
  it "passes a conversation's own event straight through, leaving the buffers alone" do
    listener.on_event(assistant_delta('A0'))
    listener.on_event(assistant_delta('A1'))
    queued = Pikuri::Agent::Control::Interloper::Item.new(kind: :user, content: 'also')
    pending = Pikuri::Conversations::Event::PendingChanged.new(items: [queued].freeze)
    listener.on_event(pending)
    assert_equal [assistant_delta('A0'), pending], inner.events

    bookend = Pikuri::Agent::Event::Assistant.new(content: 'A0A1')
    listener.on_event(bookend)
    assert_equal [assistant_delta('A0'), pending, bookend], inner.events
  end

  # A turn that fails mid-stream emits no agent event after its last delta.
  it "flushes a failed turn's tail ahead of TurnEnded, not into the next turn" do
    listener.on_event(assistant_delta('Keep it'))
    listener.on_event(assistant_delta(' coo'))
    ended = Pikuri::Conversations::Event::TurnEnded.new(outcome: :failed, error: RuntimeError.new('down'),
                                                        restarting: false)
    listener.on_event(ended)
    started = Pikuri::Conversations::Event::TurnStarted.new(user_message: 'again', attachments: [])
    listener.on_event(started)
    user_turn = Pikuri::Agent::Event::UserTurn.new(content: 'again', attachments: [], mid_loop: false)
    listener.on_event(user_turn)

    assert_equal [assistant_delta('Keep it'), assistant_delta(' coo'), ended, started, user_turn], inner.events
  end

  it 'rejects a non-positive fps' do
    assert_raises(ArgumentError) { described_class.new(inner, fps: 0) }
    assert_raises(ArgumentError) { described_class.new(inner, fps: -1) }
  end

  it "wraps the inner listener's sub-agent variant, or opts out with it" do
    sub_inner = Pikuri::Agent::Listener::InMemoryEventList.new
    inner.define_singleton_method(:for_sub_agent) { |**| sub_inner }
    sub = listener.for_sub_agent(id: 'researcher 0')
    assert_kind_of described_class, sub
    sub.on_event(Pikuri::Agent::Event::Cancelled.new)
    assert_equal [Pikuri::Agent::Event::Cancelled.new], sub_inner.events

    inner.define_singleton_method(:for_sub_agent) { |**| nil }
    assert_nil listener.for_sub_agent
  end

  # A sub-agent failing mid-stream emits nothing after its last delta, and
  # its limiter sees no TurnEnded.
  describe "a failed sub-agent's tail" do
    let(:sub_inner) { Pikuri::Agent::Listener::InMemoryEventList.new }
    let(:sub) do
      sub_inner = self.sub_inner
      inner.define_singleton_method(:for_sub_agent) { |**| sub_inner }
      listener.for_sub_agent(id: 'researcher 0')
    end

    before do
      sub.on_event(assistant_delta('Found'))
      sub.on_event(assistant_delta(' it')) # within the period: held back
    end

    it "is flushed ahead of its parent's TurnEnded" do
      ended = Pikuri::Conversations::Event::TurnEnded.new(outcome: :failed, error: RuntimeError.new('down'),
                                                          restarting: false)
      listener.on_event(ended)

      assert_equal [assistant_delta('Found'), assistant_delta(' it')], sub_inner.events
      assert_equal [ended], inner.events
    end

    it "is flushed ahead of its parent's next event, when the failure is caught" do
      listener.on_event(assistant_delta('Then'))

      assert_equal [assistant_delta('Found'), assistant_delta(' it')], sub_inner.events
      assert_equal [assistant_delta('Then')], inner.events
    end
  end

  it 'names its fps and the inner listener' do
    assert_equal "RateLimited(10fps, #{inner})", listener.to_s
  end
end
