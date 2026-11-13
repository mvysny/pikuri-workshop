# frozen_string_literal: true

require 'set'

module Pikuri
  module Code
    class Bash
      module Sandbox
        # The environment half of {Bubblewrap}'s wall: decides which inherited
        # variables a walled subprocess sees. Deny by default, the same rule the
        # filesystem half follows — an unlisted directory isn't mounted, an
        # unlisted variable isn't passed.
        #
        # The *second* wall. The first is pikuri's rule that the environment is
        # not a secret store: every other child pikuri spawns inherits the
        # environment whole, so a token belongs in a permissioned file, not an
        # export. This one catches, for sandboxed bash alone, what that review
        # missed.
        #
        #   wall = EnvWall.new(pass: ['ACME_HOME'])
        #   wall.passes?('JAVA_HOME', '/usr/lib/jvm/java-21')  # => true  (a path)
        #   wall.passes?('GITHUB_TOKEN', 'ghp_…')             # => false
        #   wall.withheld(ENV.to_h)                           # => ["GITHUB_TOKEN", …]
        #
        # A variable passes when any of these holds:
        #
        # * its name is in {BASELINE_NAMES} or starts with a {BASELINE_PREFIXES}
        #   entry — what a shell and a terminal need (+PATH+, +HOME+, +LANG+, +LC_*+);
        # * its name is in {TOOLCHAIN_NAMES} — the option variables build tools
        #   read whose values aren't paths (+MAVEN_OPTS+, +NODE_OPTIONS+, +CC+);
        # * its name was passed in +pass:+ — the user's escape hatch;
        # * its value is empty, or is *path-shaped* ({.path_shaped?}).
        #
        # == Why a path passes
        #
        # A path tells the subprocess nothing the filesystem wall doesn't
        # already govern. +JAVA_HOME=/usr/lib/jvm/…+ is useful because
        # {Bubblewrap} mounts that directory; +SSH_AUTH_SOCK=/run/user/1000/…+
        # and +GOOGLE_APPLICATION_CREDENTIALS=~/key.json+ are harmless because it
        # doesn't. One rule covers most toolchain variables (+*_HOME+, +GOPATH+,
        # +VIRTUAL_ENV+, +XDG_*+) without anyone listing them, and a token is
        # never path-shaped — nor is a +DATABASE_URL+ with a password in it.
        #
        # == Why deny by default
        #
        # The failure direction. An allowlist fails *closed and visibly* — the
        # build says +FOO_HOME is not set+ and the user adds a name; a denylist
        # (+*TOKEN*+, +*SECRET*+) fails *open and silently*, on the first secret
        # with an unexpected name. Telling the harmless from the secret is the
        # hard part either way; this puts the cost of a wrong guess on a broken
        # build rather than a leaked key. The full argument, and why only the
        # walled sandbox filters at all: +design/decisions.md+
        # +D_sandbox_env_wall+.
        class EnvWall
          # Names a shell, a terminal and the common CLIs need, whose values
          # aren't paths.
          BASELINE_NAMES = %w[
            PATH HOME USER LOGNAME SHELL SHLVL HOSTNAME
            LANG LANGUAGE TZ
            TERM COLORTERM NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE LS_COLORS
            EDITOR VISUAL PAGER LESS
            CI
          ].freeze

          # Name prefixes passed whole: the locale categories.
          BASELINE_PREFIXES = %w[LC_].freeze

          # Build-tool variables whose values are options or plain words rather
          # than paths, so the path rule misses them. Path-valued toolchain
          # variables (+JAVA_HOME+, +CARGO_HOME+, +NVM_DIR+, +GOPATH+…) need no
          # entry. Kept to options a build reads; credential-bearing ones
          # (+GOPROXY+ with a private proxy's auth, +NPM_TOKEN+) stay out on
          # purpose — those go through +pass:+ when a user wants them.
          TOOLCHAIN_NAMES = %w[
            JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS JAVA_OPTS
            MAVEN_OPTS MAVEN_ARGS GRADLE_OPTS SBT_OPTS
            NODE_OPTIONS NODE_ENV
            GOFLAGS GOOS GOARCH GO111MODULE GOTOOLCHAIN CGO_ENABLED
            RUSTFLAGS RUST_BACKTRACE RUST_LOG CARGO_TERM_COLOR CARGO_INCREMENTAL
            CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS
            PYTHONDONTWRITEBYTECODE PYTHONUNBUFFERED PYTHONIOENCODING
            RUBYOPT RAILS_ENV RACK_ENV
          ].freeze

          # Whether +value+ is an absolute path or a +:+-separated list of them,
          # each starting in a top-level directory that exists on this host.
          #
          # The existence check is what keeps a base64 secret that happens to
          # start with +/+ out: +/aB3x…+ names no top-level directory, while
          # +/usr/…+, +/home/…+ and +/opt/…+ do. Empty list items are allowed
          # (+PATH=/usr/bin::/bin+); a value with no item at all is not a path.
          #
          # @param value [String]
          # @return [Boolean]
          def self.path_shaped?(value)
            items = value.split(':').reject(&:empty?)
            return false if items.empty?

            items.all? do |item|
              next false unless item.start_with?('/')
              next false if item.match?(/[[:cntrl:]]/)

              top = item.split('/').reject(&:empty?).first
              top.nil? || File.directory?("/#{top}")
            end
          end

          # @param pass [Array<String>] extra variable names to let through
          #   whatever their value, e.g. +["ACME_LICENSE_SERVER"]+. The user's
          #   escape hatch for a build that needs a variable the rules withhold.
          def initialize(pass: [])
            @pass = pass.map(&:to_s).to_set.freeze
          end

          # @param name [String] variable name
          # @param value [String] its value
          # @return [Boolean] whether a walled subprocess may see this variable
          def passes?(name, value)
            BASELINE_NAMES.include?(name) ||
              BASELINE_PREFIXES.any? { |p| name.start_with?(p) } ||
              TOOLCHAIN_NAMES.include?(name) ||
              @pass.include?(name) ||
              value.empty? ||
              EnvWall.path_shaped?(value)
          end

          # @param env [Hash{String => String}] an environment, typically
          #   +ENV.to_h+
          # @return [Array<String>] the names {#passes?} rejects, sorted
          def withheld(env)
            env.reject { |name, value| passes?(name, value) }.keys.sort
          end
        end
      end
    end
  end
end
