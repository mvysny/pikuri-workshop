# frozen_string_literal: true

RSpec.describe Pikuri::Os::FileIndex do
  # A backend whose probe answers +reason+ and counts how often it ran.
  def backend(label, reason)
    Module.new do
      define_singleton_method(:label) { label }
      define_singleton_method(:probes) { @probes ||= 0 }
      define_singleton_method(:unavailable_reason) do
        @probes = probes + 1
        reason
      end
    end
  end

  it 'picks the first ready backend, probing none after it' do
    first = backend('first', 'not installed')
    second = backend('second', nil)
    third = backend('third', nil)

    assert_same second, described_class.pick([first, second, third])
    assert_equal [1, 1, 0], [first, second, third].map(&:probes)
  end

  it 'names every reason, by label, when no backend is ready' do
    err = assert_raises(described_class::Unavailable) do
      described_class.pick([backend('localsearch', 'the index holds no files yet.'),
                            backend('recoll', 'no index in /home/u/.recoll yet.')])
    end
    assert_equal "no file index is ready:\n" \
                 "- localsearch: the index holds no files yet.\n" \
                 '- recoll: no index in /home/u/.recoll yet.', err.message
  end

  it 'prefers localsearch over recoll' do
    assert_equal [Pikuri::Os::LocalSearch, Pikuri::Os::Recoll], described_class::BACKENDS
  end
end
