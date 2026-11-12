# frozen_string_literal: true

require 'json'
require 'timeout'

describe Pikuri::Lsp::Readiness do
  cancelled = Pikuri::Agent::Control::Cancellable::Cancelled

  # jdtls's own $/progress lifecycle, replayed from the recorded frames (J_progress_opt_in, J_readiness_edge).
  progress = lambda do |name|
    JSON.parse(fixture("jdtls_progress_#{name}"))['params']
  end

  # Short enough to keep the suite fast, long enough that a stalled machine
  # cannot cross the window between two assertions and make this flake.
  settle = 0.1
  gate = -> { described_class.new(server_id: 'java', settle: settle) }

  # Waits, collecting every progress the gate yields.
  waiting = lambda do |readiness, cancellable: nil, alive: -> { true }|
    seen = []
    result = Timeout.timeout(5) do
      readiness.wait(cancellable: cancellable, alive: alive) { |update| seen << update }
    end
    [result, seen]
  end

  describe '#ready?' do
    it 'is false while a task is open, however long it has been open' do
      readiness = gate.call
      readiness.observe('$/progress', progress.call('begin'))
      sleep settle * 3

      refute readiness.ready?, 'an open token is an open token'
    end

    it 'is false for the settle window after the last task closes' do
      readiness = gate.call
      readiness.observe('$/progress', progress.call('begin'))
      readiness.observe('$/progress', progress.call('end'))

      refute readiness.ready?, 'jdtls answered nothing for 0.9s after its last token closed'
      sleep settle * 2
      assert readiness.ready?
    end

    it 'ignores everything that is not $/progress' do
      readiness = gate.call
      readiness.observe('$/progress', progress.call('begin'))
      readiness.observe('language/status', JSON.parse(fixture('jdtls_language_status'))['params'])
      readiness.observe('window/logMessage', { 'type' => 3, 'message' => 'indexing' })

      refute readiness.ready?, 'a non-spec status notification neither opens nor closes the gate'
    end

    it 'holds the gate for a task that reported before pikuri saw it begin' do
      readiness = gate.call
      readiness.observe('$/progress', progress.call('report'))
      sleep settle * 2

      refute readiness.ready?, 'a report is evidence of work in flight, begin or no begin'
    end

    it 'treats a server that announces nothing as ready once it has been quiet' do
      readiness = gate.call

      sleep settle * 2
      assert readiness.ready?, 'silence is the only signal some servers give'
    end
  end

  describe '#wait' do
    it 'returns true and yields nothing when the gate is already open' do
      readiness = gate.call
      sleep settle * 2

      assert_equal [true, []], waiting.call(readiness)
    end

    it 'yields the server\'s own words while it works, then returns true' do
      readiness = gate.call
      readiness.observe('$/progress', progress.call('begin'))
      Thread.new do
        sleep settle
        readiness.observe('$/progress', progress.call('end'))
      end

      result, seen = waiting.call(readiness)

      assert_equal true, result
      first = seen.first
      assert_equal 'java', first.server_id, 'so a host can key two concurrent bars'
      assert_equal 'Initialize Workspace', first.title
      assert_equal 'Importing gradle project', first.message
      assert_nil first.percentage, 'a begin carries none, and plenty of servers never do'
      refute first.done
      assert seen.last.done, 'the end arrives before the gate opens'
      assert_equal 'Initialize Workspace', seen.last.title, 'titled by its begin, not by the token'
    end

    it 'yields current state, not the burst of reports that piled up' do
      readiness = gate.call
      readiness.observe('$/progress', progress.call('begin'))
      100.times do |i|
        readiness.observe('$/progress',
                          progress.call('report').merge('value' => { 'kind' => 'report',
                                                                     'message' => "#{i}/100 projects",
                                                                     'percentage' => i }))
      end
      Thread.new do
        sleep settle
        readiness.observe('$/progress', progress.call('end'))
      end

      _result, seen = waiting.call(readiness)

      refute_includes seen.map(&:message), '0/100 projects', 'a replayed backlog races stale percentages'
      assert_includes seen.map(&:message), '99/100 projects'
      assert_operator seen.size, :<, 5, "#{seen.size} events for 101 notifications"
    end

    it 'always takes the bar down, even when the server never sent an end' do
      readiness = gate.call
      readiness.observe('$/progress', progress.call('begin'))
      dead = false
      result, seen = waiting.call(readiness, alive: -> { !dead.tap { dead = true } })

      assert_equal false, result, 'a child that died indexing will never be ready'
      assert seen.last.done, 'otherwise a host keeps the bar up forever'
      assert_equal 'Initialize Workspace', seen.last.title
      assert_nil seen.last.percentage, 'the terminal event carries no stale progress'
    end

    it 'raises on cancellation, and takes the bar down on the way out' do
      readiness = gate.call
      readiness.observe('$/progress', progress.call('begin'))
      cancellable = Pikuri::Agent::Control::Cancellable.new
      cancellable.cancel!
      seen = []

      assert_raises(cancelled) do
        Timeout.timeout(5) { readiness.wait(cancellable: cancellable) { |update| seen << update } }
      end
      assert_equal [true], seen.map(&:done), 'the human is the timeout, and their bar still goes away'
    end

    it 'does not re-announce a task it already saw end' do
      readiness = gate.call
      readiness.observe('$/progress', progress.call('begin'))
      readiness.observe('$/progress', progress.call('end'))

      _result, seen = waiting.call(readiness)

      assert_equal [true], seen.map(&:done), 'one end, not an end plus a synthetic one'
    end
  end

  describe '#reset!' do
    it 'shuts the gate again, because a restarted server indexes from nothing' do
      readiness = gate.call
      sleep settle * 2
      assert readiness.ready?

      readiness.reset!
      refute readiness.ready?
      sleep settle * 2
      assert readiness.ready?
    end

    it 'drops the dead child\'s open tasks, which will never end now' do
      readiness = gate.call
      readiness.observe('$/progress', progress.call('begin'))
      readiness.reset!
      sleep settle * 2

      assert readiness.ready?, 'the fresh child gets to announce its own work'
    end
  end
end
