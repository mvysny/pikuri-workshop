# frozen_string_literal: true

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'

require 'pikuri-memory'

# Silence Pikuri's default $stderr logging for the suite so production
# log lines don't bleed into rspec output. Specs that exercise logging
# swap +Pikuri.log_io+ to a +StringIO+ and restore it.
Pikuri.log_io = File.open(File::NULL, 'w')

# Match pikuri-core's spec_helper minitest wiring: mix the assertion
# module in + provide the `assertions` accessor that `assert_equal` and
# friends require internally. AGENTS.md's "Tests" convention —
# minitest-style assertions inside rspec example groups.
RSpec.configure do |config|
  config.include Minitest::Assertions
  config.include(Module.new do
    attr_writer :assertions

    def assertions
      @assertions ||= 0
    end

    # Minitest::Assertions#skip shadows rspec's own and raises an
    # exception rspec reports as a *failure* — so an environment guard
    # (`skip 'git not on PATH'`) reddens the build on precisely the
    # hosts it means to excuse. Delegate back to rspec's pending
    # machinery; the trailing backtrace arg is minitest's signature.
    def skip(message = nil, _backtrace = nil)
      RSpec::Core::Pending.instance_method(:skip).bind_call(self, message)
    end
  end)
end
