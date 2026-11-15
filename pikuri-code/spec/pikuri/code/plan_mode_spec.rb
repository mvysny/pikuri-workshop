# frozen_string_literal: true

RSpec.describe Pikuri::Code::PlanMode do
  describe '#initialize' do
    it 'defaults to inactive' do
      refute described_class.new.active?
    end

    it 'honors active: true for a startup-flag posture' do
      assert described_class.new(active: true).active?
    end
  end

  describe '#activate! / #deactivate!' do
    it 'activate! turns the flag on' do
      flag = described_class.new
      flag.activate!
      assert flag.active?
    end

    it 'deactivate! turns the flag off' do
      flag = described_class.new(active: true)
      flag.deactivate!
      refute flag.active?
    end

    it 'activate! is idempotent' do
      flag = described_class.new
      flag.activate!
      flag.activate!
      assert flag.active?
    end

    it 'deactivate! is idempotent' do
      flag = described_class.new
      flag.deactivate!
      refute flag.active?
    end
  end

  describe '#on_change' do
    it 'fires with the new state on a real transition' do
      flag = described_class.new
      seen = []
      flag.on_change { |active| seen << active }

      flag.activate!
      flag.deactivate!

      assert_equal [true, false], seen
    end

    it 'does not fire on a no-op flip' do
      flag = described_class.new
      seen = []
      flag.on_change { |active| seen << active }

      flag.deactivate! # already inactive
      flag.activate!
      flag.activate! # already active

      assert_equal [true], seen
    end

    it 'fans out to every registered callback' do
      flag = described_class.new
      a = []
      b = []
      flag.on_change { |s| a << s }
      flag.on_change { |s| b << s }

      flag.activate!

      assert_equal [true], a
      assert_equal [true], b
    end

    it 'requires a block' do
      assert_raises(ArgumentError) { described_class.new.on_change }
    end

    it 'returns the registered block' do
      blk = proc { |_active| nil }
      assert_same blk, described_class.new.on_change(&blk)
    end
  end

  describe '#remove_on_change' do
    it 'stops the removed callback, leaving the others' do
      flag = described_class.new
      a = []
      b = []
      cb = flag.on_change { |s| a << s }
      flag.on_change { |s| b << s }

      assert flag.remove_on_change(cb)
      flag.activate!

      assert_empty a
      assert_equal [true], b
    end

    it 'answers false for a callable that is not registered' do
      refute described_class.new.remove_on_change(proc { nil })
    end

    it 'removes one registration per call' do
      flag = described_class.new
      seen = []
      cb = proc { |s| seen << s }
      flag.on_change(&cb)
      flag.on_change(&cb)

      flag.remove_on_change(cb)
      flag.activate!

      assert_equal [true], seen
    end
  end

  describe 'cross-thread transitions' do
    it 'an #activate! from another thread is observed via #active?' do
      flag = described_class.new

      Thread.new { flag.activate! }.join

      assert flag.active?
    end
  end

  describe '#to_s' do
    it 'renders the off state' do
      assert_equal 'PlanMode(off)', described_class.new.to_s
    end

    it 'renders the on state' do
      assert_equal 'PlanMode(on)', described_class.new(active: true).to_s
    end
  end
end
