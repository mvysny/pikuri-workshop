# frozen_string_literal: true

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'

require 'pikuri-lsp'
require 'pikuri/lsp/testing' # opt-in scaffolding, not loaded by pikuri-lsp boot

# Absolute so a fixture reads the same from any working directory.
FIXTURES = File.expand_path('fixtures', __dir__)

# @return [String] the fixture's bytes, exactly as recorded.
def fixture(name)
  File.read(File.join(FIXTURES, "#{name}.json"))
end

# Silence Pikuri's default $stderr logging for the suite so production
# log lines don't bleed into rspec output.
Pikuri.log_io = File.open(File::NULL, 'w')

# The Connection specs drive the client from worker threads and assert the
# exception through Thread#value, so Ruby's own "terminated with exception"
# warning is pure noise on a passing suite.
Thread.report_on_exception = false

# Match pikuri-core's spec_helper minitest wiring: mix the
# assertion module in + provide the `assertions` accessor that
# `assert_equal` and friends require internally. AGENTS.md's
# "Tests" convention — minitest-style assertions inside rspec
# example groups.
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
