# frozen_string_literal: true

RSpec.describe Pikuri::Code::VirtualMachine do
  # Stubbed, so the answer doesn't depend on where the suite runs.
  def with_probe(&outcome)
    original = Pikuri::Subprocess.method(:spawn)
    calls = []
    Pikuri::Subprocess.define_singleton_method(:spawn) do |*argv, **_kwargs|
      calls << argv
      ok = outcome.call
      Struct.new(:status) { def wait = self }.new(Struct.new(:success?).new(ok))
    end
    yield_result = described_class.inside?
    [yield_result, calls]
  ensure
    Pikuri::Subprocess.define_singleton_method(:spawn, original)
  end

  it 'asks systemd-detect-virt about hardware virtualization only' do
    answer, calls = with_probe { true }

    assert_equal true, answer
    assert_equal [%w[systemd-detect-virt --vm --quiet]], calls
  end

  it 'answers false outside a VM' do
    answer, = with_probe { false }

    assert_equal false, answer
  end

  it 'answers nil when it cannot tell' do
    answer, = with_probe { raise Errno::ENOENT, 'systemd-detect-virt' }

    assert_nil answer
  end
end
