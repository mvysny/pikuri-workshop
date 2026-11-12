# frozen_string_literal: true

module Pikuri
  module Code
    # Curated list of filesystem prefixes a coding agent benefits from seeing:
    # system toolchains under +/usr+/+/opt+, per-user toolchain managers
    # (mise/asdf/rbenv/pyenv/nvm/rustup), and the per-user dependency caches the
    # toolchains mutate (Gradle, Maven, Cargo, npm, pip, …). Not a tool — a
    # config helper +bin/pikuri-code+ feeds into
    # +Filesystem.new(readable: …)+ alongside the skill catalog's roots.
    #
    # Every entry is mounted by {Pikuri::Code::Bash::Sandbox::Bubblewrap} as a
    # read-write *ephemeral overlay* (read-only bind without overlayfs): the
    # host's real dir is the read-through lower, a per-session upper absorbs
    # writes and is discarded at exit. Overlaid rather than read-only because
    # build tools assume their dirs are writable — a read-only +~/.rbenv+ breaks
    # +gem install+ with +EROFS+, since the install target lives *inside* the
    # version-manager dir with no separate cache to overlay. The workspace also
    # lists these in +readable+ so the LLM can Read/Grep/Glob them via the file
    # tools (which run on the host fs); writes through bash land in the overlay
    # and are not visible to those tools — an accepted asymmetry.
    #
    # == Why subdirs, not whole toolchain dirs
    #
    # The dependency caches are listed as *content-only subdirs* that *exclude*
    # the toolchain's credential / persistence files. The overlay is ephemeral,
    # but the host's real file is the read-through lower — so a narrower mount
    # keeps secrets out of the sandbox's *view* entirely rather than relying on
    # "the write vanished". Exposed paths hold cache content; excluded paths
    # hold secrets or build-config:
    #
    #   * +~/.gradle/caches+ + +wrapper/dists+ + +jdks+ — NOT
    #     +gradle.properties+ (signing keys / OSSRH / Develocity tokens), NOT
    #     +init.d+ (persistence: a future +./gradlew+ outside pikuri would
    #     execute init scripts a poisoned session planted here), NOT
    #     +enterprise+ (Develocity keys), NOT +daemon+ (logs leaking +-P+
    #     properties).
    #   * +~/.m2/repository+ — NOT +~/.m2/settings.xml+ (server creds).
    #   * +~/.cargo/registry+ — NOT +~/.cargo/credentials.toml+ (publish tokens).
    #   * +~/.ivy2/cache+ — NOT +~/.ivy2/.credentials+ (resolver creds).
    #
    # The version-manager roots (+~/.rbenv+, +~/.pyenv+, …) are listed *whole*
    # because they carry no credential files and their install targets live
    # directly under them. mise installs under +~/.local/share/mise/installs+
    # (so overlaying +~/.local/share/mise+ covers it); system Ruby under +/usr+.
    module ToolchainPaths
      # @return [Array<String>] absolute paths, stable order, presence-filtered
      #   to existing directories (no Rust installed ⇒ no phantom +~/.rustup+; a
      #   missing +~/.gradle/caches+ stays out). See the module header for the
      #   overlay treatment and the content-only-subdir rationale.
      def self.readable
        home = Dir.home
        candidates = [
          # System + per-user toolchains, listed whole (see module header).
          '/usr',
          '/opt',
          File.join(home, '.local/share/mise'),
          File.join(home, '.config/mise'),
          File.join(home, '.asdf'),
          File.join(home, '.rbenv'),
          File.join(home, '.gem'),
          File.join(home, '.pyenv'),
          File.join(home, '.nvm'),
          File.join(home, '.rustup'),
          # Content-only cache subdirs — credential / persistence files
          # deliberately excluded (see module header).
          File.join(home, '.cargo/registry'),
          File.join(home, '.m2/repository'),
          File.join(home, '.gradle/caches'),
          File.join(home, '.gradle/wrapper/dists'),
          File.join(home, '.gradle/jdks'),
          File.join(home, '.ivy2/cache'),
          File.join(home, 'go/pkg/mod'),
          File.join(home, '.cache/pip'),
          File.join(home, '.cache/uv'),
          File.join(home, '.npm'),
          File.join(home, '.local/share/pnpm/store'),
          File.join(home, '.nuget/packages')
        ]
        candidates.select { |p| File.directory?(p) }.freeze
      end
    end
  end
end
