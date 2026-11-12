# frozen_string_literal: true

# Read by every gemspec, never by a +lib/+: Bundler loads this while it
# resolves, so the constants exist only at build and bundle time.
module Pikuri
  module Workshop
    # The workshop gems' own version, bumped in lockstep by +rake release+.
    VERSION = '0.1.0'

    # What every workshop gem requires of the vanilla pikuri gems it uses
    # (pikuri-core, pikuri-workspace, pikuri-subagents). A workshop release
    # sets it to the pikuri release it was built against, which must already
    # be on rubygems.
    PIKURI = '~> 0.1'
  end
end
