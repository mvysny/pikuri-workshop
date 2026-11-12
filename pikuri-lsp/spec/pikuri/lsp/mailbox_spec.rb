# frozen_string_literal: true

require 'timeout'

describe Pikuri::Lsp::Mailbox do
  # Drains until +count+ values (nils included) have been yielded, so an
  # assertion never depends on a tick landing.
  collect = lambda do |mailbox, count, tick: 0.01|
    seen = []
    Timeout.timeout(5) do
      mailbox.drain(tick: tick) do |value|
        seen << value
        break if seen.size >= count
      end
    end
    seen
  end

  it 'keeps the newest value per key, not a backlog' do
    mailbox = described_class.new
    mailbox.push('token-1', 'first')
    mailbox.push('token-1', 'second')
    mailbox.push('token-1', 'newest')

    assert_equal 1, mailbox.size
    assert_equal ['newest'], collect.call(mailbox, 1)
  end

  it 'coalesces per key, so concurrent tasks do not overwrite each other' do
    mailbox = described_class.new
    mailbox.push('importing', 'gradle')
    mailbox.push('building', 'workspace')
    mailbox.push('importing', 'maven')

    assert_equal %w[maven workspace], collect.call(mailbox, 2),
                 'first-push order, latest value'
  end

  it 'empties as it drains, so a second pass sees only what arrived since' do
    mailbox = described_class.new
    mailbox.push('a', 1)
    assert_equal [1], collect.call(mailbox, 1)

    assert_equal 0, mailbox.size
    assert_nil collect.call(mailbox, 1).first, 'nothing parked yields nil'
  end

  it 'yields nil on an idle tick, which is how the consumer polls its own exits' do
    mailbox = described_class.new

    assert_equal [nil, nil, nil], collect.call(mailbox, 3)
  end

  it 'wakes early on a push instead of sleeping out the tick' do
    mailbox = described_class.new
    Thread.new do
      sleep 0.05
      mailbox.push('late', 'value')
    end

    elapsed = Time.now
    values = Timeout.timeout(5) do
      mailbox.drain(tick: 30) do |value| # a tick nothing would wait out
        break value if value
      end
    end

    assert_equal 'value', values
    assert_operator Time.now - elapsed, :<, 5, 'the condition variable, not the tick, ended the wait'
  end

  it 'returns whatever the block breaks with' do
    mailbox = described_class.new
    mailbox.push('k', 'v')

    assert_equal :done, Timeout.timeout(5) { mailbox.drain(tick: 0.01) { |_value| break :done } }
  end

  it 'lets an exception out of the block, so cancellation propagates' do
    mailbox = described_class.new

    assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
      Timeout.timeout(5) do
        mailbox.drain(tick: 0.01) { |_value| raise Pikuri::Agent::Control::Cancellable::Cancelled }
      end
    end
  end

  it 'carries values across the thread boundary it exists for' do
    mailbox = described_class.new
    producer = Thread.new do
      100.times { |i| mailbox.push('token', i) }
      mailbox.push('token', :last)
    end

    last = Timeout.timeout(5) do
      mailbox.drain(tick: 0.01) { |value| break value if value == :last }
    end
    producer.join

    assert_equal :last, last, 'the newest push always arrives, however many were dropped'
  end
end
