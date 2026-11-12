# frozen_string_literal: true

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'

require 'pikuri-mcp'

# Silence Pikuri's default $stderr logging for the suite so production
# log lines don't bleed into rspec output. Specs that exercise logging
# swap +Pikuri.log_io+ to a +StringIO+ and restore it.
Pikuri.log_io = File.open(File::NULL, 'w')

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

# The argv that spawns the in-tree MCP fixture at
# +spec/support/test_mcp_server.rb+.
#
# {Pikuri::Mcp::ClientWrapper} de-bundlerizes every child it spawns (see
# {Pikuri::BundlerEnv}) — right for a server that serves *another* project, but
# this fixture is pikuri's own bundle, and +Bundler.unbundled_env+ drops every
# +BUNDLE_*+ variable plus, under a nested +bundle exec+ (CI runs
# +rake test+ → +bundle exec rspec+), the +GEM_HOME+ / +GEM_PATH+ the outermost
# one invented. A host that keeps its gem path in +.bundle/config+ never
# notices; CI, which passes it as +BUNDLE_PATH+, gets a child that cannot
# resolve the +mcp+ gem, dies before writing a byte, and reddens every example
# with "Server process closed stdout unexpectedly".
#
# The variables are handed back through the child's own argv rather than
# through the entry's +env:+, so the spawn env stays the de-bundlerized one the
# wrapper is under test for.
module TestServer
  FIXTURE = File.expand_path('support/test_mcp_server.rb', __dir__)

  # What the fixture needs to find pikuri's bundle, whichever of them this
  # host happens to resolve it through.
  RESOLUTION_VARS = ->(key) { key.start_with?('BUNDLE_') || %w[GEM_HOME GEM_PATH].include?(key) }

  # @param extra_env [Hash{String=>String}] further assignments for the child,
  #   set after the bundler ones.
  # @return [Array<String>] the command for a +Registry::StdioEntry+.
  def self.command(extra_env = {})
    assignments = ENV.to_h.select { |k, _| RESOLUTION_VARS.call(k) }.merge(extra_env)
    ['env', *assignments.map { |k, v| "#{k}=#{v}" }, 'bundle', 'exec', 'ruby', FIXTURE]
  end
end
