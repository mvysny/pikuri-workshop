# frozen_string_literal: true

RSpec.describe Pikuri::Mcp::Thinker do
  let(:transport) { Pikuri::Agent::ChatTransport.new(model: 'qwen-x') }

  # Fake one-shot agent the stubbed Pikuri::Agent.new returns: records
  # the asked prompt, returns a canned answer, tracks #close.
  let(:fake_agent_class) do
    Class.new do
      attr_reader :asked, :closed

      def initialize
        @asked = []
        @closed = false
      end

      def run_loop(user_message:)
        @asked << user_message
        nil
      end

      def last_assistant_content
        'the reply'
      end

      def close
        @closed = true
      end
    end
  end

  def with_stubbed_agent_new(fake_agent)
    ctor_calls = []
    original = Pikuri::Agent.method(:new)
    Pikuri::Agent.define_singleton_method(:new) do |**kw, &_blk|
      ctor_calls << kw
      fake_agent
    end
    yield ctor_calls
  ensure
    Pikuri::Agent.define_singleton_method(:new) { |**kw, &blk| original.call(**kw, &blk) }
  end

  describe '#initialize' do
    it 'rejects a nil transport' do
      assert_raises(ArgumentError) { described_class.new(transport: nil) }
    end
  end

  describe '#call' do
    it 'runs the prompt through a fresh tools-free agent and returns the reply' do
      fake = fake_agent_class.new
      thinker = described_class.new(transport: transport)

      with_stubbed_agent_new(fake) do |ctor_calls|
        assert_equal 'the reply', thinker.call('summarize X')

        assert_equal 1, ctor_calls.size
        ctor = ctor_calls.first
        assert_same transport, ctor[:transport]
        assert_equal described_class::SYSTEM_PROMPT, ctor[:system_prompt]
        assert_equal ['summarize X'], fake.asked
      end
    end

    it 'closes the one-shot agent even when run_loop raises' do
      fake = fake_agent_class.new
      fake.define_singleton_method(:run_loop) { |user_message:| raise 'provider blew up' }
      thinker = described_class.new(transport: transport)

      with_stubbed_agent_new(fake) do |_ctor_calls|
        assert_raises(RuntimeError) { thinker.call('p') }
        assert fake.closed, 'the one-shot agent must be closed on failure too'
      end
    end

    it 'constructs a fresh agent per call (no shared chat history across prompts)' do
      fakes = [fake_agent_class.new, fake_agent_class.new]
      handed_out = []
      original = Pikuri::Agent.method(:new)
      Pikuri::Agent.define_singleton_method(:new) do |**_kw, &_blk|
        handed_out << fakes[handed_out.size]
        handed_out.last
      end
      begin
        thinker = described_class.new(transport: transport)
        thinker.call('first')
        thinker.call('second')

        assert_equal 2, handed_out.size
        refute_same handed_out[0], handed_out[1]
        assert_equal ['first'],  handed_out[0].asked
        assert_equal ['second'], handed_out[1].asked
      ensure
        Pikuri::Agent.define_singleton_method(:new) { |**kw, &blk| original.call(**kw, &blk) }
      end
    end

    it 'checks the cancellable before constructing the agent, so a tripped flag aborts the pass' do
      cancellable = Pikuri::Agent::Control::Cancellable.new
      cancellable.cancel!
      thinker = described_class.new(transport: transport, cancellable: cancellable)

      with_stubbed_agent_new(fake_agent_class.new) do |ctor_calls|
        assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) { thinker.call('p') }
        assert_empty ctor_calls, 'pre-call check must fire before the agent is constructed'
      end
    end
  end
end
