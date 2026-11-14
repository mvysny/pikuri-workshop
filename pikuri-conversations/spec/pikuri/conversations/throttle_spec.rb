# frozen_string_literal: true

RSpec.describe Pikuri::Conversations::Throttle do
  after { described_class.reset! }

  let(:semaphore_class) { Pikuri::Conversations::Throttle::Semaphore }
  let(:cancelled) { Pikuri::Agent::Control::Cancellable::Cancelled }

  # Wait for a handoff between threads rather than sleeping a guessed interval.
  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert yield, 'condition never became true'
  end

  describe '.key_for' do
    it 'normalizes a trailing slash and /v1 to one key' do
      keys = %w[http://x:8080 http://x:8080/ http://x:8080/v1 http://x:8080/v1/].map { described_class.key_for(_1) }
      assert_equal ['http://x:8080'], keys.uniq
    end

    it 'is nil when there is no server to key on' do
      [nil, '', '   ', '/'].each { |blank| assert_nil described_class.key_for(blank) }
    end
  end

  describe '.limit / .for' do
    it 'sizes a server, keyed past the /v1 difference, one semaphore for all' do
      described_class.limit('http://x:8080/v1', 2)
      assert_equal 2, described_class.for('http://x:8080').permits
      assert_same described_class.for('http://x:8080'), described_class.for('http://x:8080/v1/')
      assert_equal({ 'http://x:8080' => 2 }, described_class.sizes)
    end

    it 'answers UNLIMITED for an unsized server, no server, and an explicit nil' do
      described_class.limit('https://api.openai.com/v1', nil)
      assert_same described_class::UNLIMITED, described_class.for('http://unsized:8080')
      assert_same described_class::UNLIMITED, described_class.for(nil)
      assert_same described_class::UNLIMITED, described_class.for('https://api.openai.com')
    end

    it 'rebuilds the semaphore only when the size changes' do
      described_class.limit('http://x:8080', 2)
      first = described_class.for('http://x:8080')
      described_class.limit('http://x:8080', 2)
      assert_same first, described_class.for('http://x:8080')
      described_class.limit('http://x:8080', 3)
      assert_equal 3, described_class.for('http://x:8080').permits
    end

    it 'refuses a non-positive or non-Integer size, and a blank server' do
      [0, -1, '2', 1.5].each do |bad|
        assert_raises(ArgumentError) { described_class.limit('http://x:8080', bad) }
      end
      assert_raises(ArgumentError) { described_class.limit('', 1) }
    end
  end

  describe '.default' do
    it 'never overrides a limit, whichever lands first, and the first default wins' do
      described_class.limit('http://x:8080', 1)
      described_class.default('http://x:8080', 4)
      described_class.default('http://y:8080', 4)
      described_class.limit('http://y:8080', 1)
      described_class.default('http://z:8080', 4)
      described_class.default('http://z:8080', 1)
      assert_equal [1, 1, 4], %w[x y z].map { described_class.for("http://#{_1}:8080").permits }
    end

    it 'marks the server sized, a recorded "unlimited" included' do
      refute described_class.sized?('http://x:8080')
      described_class.default('http://x:8080', nil)
      assert described_class.sized?('http://x:8080/v1')
      refute described_class.sized?(nil)
    end
  end

  describe '.call' do
    it 'runs the request under a permit of the server it dials' do
      described_class.limit('http://x:8080', 1)
      sem = described_class.for('http://x:8080')
      assert_equal :answer, described_class.call('http://x:8080/v1', nil) {
        assert_equal 0, sem.available
        :answer
      }
      assert_equal 1, sem.available
    end
  end

  describe 'Semaphore' do
    it 'never lets more than `permits` blocks run at once' do
      sem = semaphore_class.new(2)
      lock = Mutex.new
      in_flight = 0
      peak = 0
      6.times.map do
        Thread.new do
          sem.acquire do
            lock.synchronize { peak = [peak, in_flight += 1].max }
            sleep 0.02
            lock.synchronize { in_flight -= 1 }
          end
        end
      end.each(&:join)
      assert_equal 2, peak
    end

    it 'releases the permit when the block raises' do
      sem = semaphore_class.new(1)
      assert_raises(RuntimeError) { sem.acquire { raise 'boom' } }
      assert_equal 1, sem.available
    end

    it 'raises Cancelled while parked, without waiting for the permit to free' do
      sem = semaphore_class.new(1)
      cancellable = Pikuri::Agent::Control::Cancellable.new
      hold = Queue.new
      holder = Thread.new { sem.acquire { hold.pop } }
      wait_until { sem.available.zero? }

      waiter = Thread.new do
        sem.acquire(cancellable:) { :ran }
      rescue cancelled
        :cancelled
      end
      cancellable.cancel!
      assert_equal :cancelled, waiter.value
      assert_equal 0, sem.available

      hold << :go
      holder.join
      assert_equal 1, sem.available
    end

    it 'reports its state for a debug print' do
      sem = semaphore_class.new(2)
      assert_equal '2/2 permits', sem.to_s
      sem.acquire { assert_equal '1/2 permits', sem.to_s }
      assert_equal 'unlimited', semaphore_class.new(nil).to_s
    end
  end
end
