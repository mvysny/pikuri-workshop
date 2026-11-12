# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::Memory::Recorder do
  # A thread-safe fake client that records every #add call. Captures
  # are async, so the fake uses a Queue the spec can block on rather
  # than racing on an Array.
  let(:fake_client_class) do
    Class.new do
      def initialize(raise_on: nil)
        @raise_on = raise_on
        @calls = Thread::Queue.new
      end

      def add(content:, user_id:, infer:, prompt:)
        raise 'mem0 down' if content == @raise_on

        @calls << { content: content, user_id: user_id, infer: infer, prompt: prompt }
        []
      end

      # Block until +n+ adds have landed (or raise on timeout) so the
      # spec is deterministic without sleeping.
      def await(count, timeout: 2)
        deadline = Time.now + timeout
        collected = []
        collected << @calls.pop until collected.size == count
        collected
      rescue StandardError
        collected
      ensure
        raise "timed out waiting for #{count} adds (got #{collected.size})" if Time.now > deadline && collected.size < count
      end

      def count
        @calls.size
      end
    end
  end

  it 'drains enqueued turns to client.add on the worker thread' do
    client = fake_client_class.new
    recorder = described_class.new(client: client, user_id: 'martin', prompt: 'PROMPT').start

    recorder.enqueue('I am vegetarian')
    recorder.enqueue('I live in Brno')

    calls = client.await(2)
    contents = calls.map { |c| c[:content] }
    assert_includes contents, 'I am vegetarian'
    assert_includes contents, 'I live in Brno'
    assert_equal 'martin', calls.first[:user_id]
    assert_equal 'PROMPT', calls.first[:prompt]
  ensure
    recorder.close
  end

  it 'ignores blank and post-close enqueues' do
    client = fake_client_class.new
    recorder = described_class.new(client: client, user_id: 'u').start

    recorder.enqueue('   ')
    recorder.enqueue(nil)
    recorder.close
    recorder.enqueue('after close')

    assert_equal 0, client.count
  end

  it 'flushes queued work on close before stopping' do
    client = fake_client_class.new
    recorder = described_class.new(client: client, user_id: 'u').start

    recorder.enqueue('one')
    recorder.close # STOP is queued behind 'one', so 'one' drains first

    assert_equal 1, client.count
  end

  it 'keeps the worker alive when an add raises (logs and drops)' do
    client = fake_client_class.new(raise_on: 'poison')
    recorder = described_class.new(client: client, user_id: 'u').start

    recorder.enqueue('poison') # raises inside the worker, must not kill it
    recorder.enqueue('good')

    calls = client.await(1)
    assert_equal ['good'], calls.map { |c| c[:content] }
  ensure
    recorder.close
  end

  it 'is idempotent on start and close' do
    client = fake_client_class.new
    recorder = described_class.new(client: client, user_id: 'u')

    recorder.start
    recorder.start # no second worker
    recorder.enqueue('x')
    client.await(1)
    recorder.close
    recorder.close # no-op
  end
end
