# frozen_string_literal: true

require 'pikuri/testing'

# The detector is pikuri-core's; these stub it and check what the cache in front
# of it does.
RSpec.describe Pikuri::Conversations::Probe do
  let(:detector) { Pikuri::Agent::ContextWindowDetector }
  let(:props) { detector::Props }
  let(:calls) { [] }
  let(:answer) { props.new(n_ctx: 16_384, total_slots: 4, modalities: { vision: true }) }
  let(:lookup) { { vision: false } }
  let(:unstated) { Pikuri::Testing.fake_transport(context_window: nil, modalities: nil, api_base: 'http://x:8080/v1') }

  before do
    @detect = detector.method(:detect)
    @detect_modalities = detector.method(:detect_modalities)
    log = calls
    full = -> { answer }
    cheap = -> { lookup }
    detector.define_singleton_method(:detect) do |transport, **|
      log << [:detect, transport.model]
      full.call
    end
    detector.define_singleton_method(:detect_modalities) do |transport, **|
      log << [:modalities, transport.model]
      cheap.call
    end
  end

  after do
    detect = @detect
    detect_modalities = @detect_modalities
    detector.define_singleton_method(:detect) { |*a, **k| detect.call(*a, **k) }
    detector.define_singleton_method(:detect_modalities) { |*a, **k| detect_modalities.call(*a, **k) }
    described_class.reset!
  end

  it 'asks once per server and model, /v1 or not' do
    described_class.props(unstated)
    described_class.props(unstated.with(api_base: 'http://x:8080'))
    described_class.props(unstated.with(model: 'other'))
    assert_equal [[:detect, 'fake-model'], [:detect, 'other']], calls
  end

  it 'fills in what it learnt, never over what the transport states' do
    assert_same unstated, described_class.facts(unstated)
    described_class.props(unstated)
    assert_equal [16_384, { vision: true }], described_class.facts(unstated).then { [_1.context_window, _1.modalities] }

    stated = unstated.with(context_window: 4096, modalities: { vision: false })
    assert_same stated, described_class.facts(stated)
  end

  it 'answers modalities from the full probe when it has one, else looks them up once' do
    assert_equal({ vision: false }, described_class.modalities(unstated))
    assert_equal({ vision: false }, described_class.modalities(unstated))
    assert_equal({ vision: false }, described_class.facts(unstated).modalities)
    described_class.props(unstated)
    assert_equal({ vision: true }, described_class.modalities(unstated))
    assert_equal [[:modalities, 'fake-model'], [:detect, 'fake-model']], calls
  end

  it 'asks again after an empty answer, once RETRY_AFTER has passed' do
    nothing = props::NONE
    log = calls
    detector.define_singleton_method(:detect) do |_transport, **|
      log << :detect
      nothing
    end
    described_class.props(unstated)
    described_class.props(unstated)
    assert_equal 1, calls.size

    meta = described_class.singleton_class
    original = meta.instance_method(:now)
    later = described_class.send(:now) + described_class::RETRY_AFTER + 1
    meta.send(:define_method, :now) { later }
    begin
      described_class.props(unstated)
    ensure
      meta.send(:define_method, :now, original)
      meta.send(:private, :now)
    end
    assert_equal 2, calls.size
  end

  it 'probes an uncached model once however many threads ask at once' do
    gate = Queue.new
    log = calls
    one = props.new(n_ctx: 1, total_slots: 1, modalities: nil)
    detector.define_singleton_method(:detect) do |_transport, **|
      log << :detect
      gate.pop
      one
    end
    askers = 3.times.map { Thread.new { described_class.props(unstated) } }
    sleep 0.05
    gate << :go
    assert_equal [1, 1, 1], askers.map { _1.value.n_ctx }
    assert_equal [:detect], calls
  end
end
