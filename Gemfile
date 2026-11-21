# frozen_string_literal: true

source 'https://rubygems.org'

# The workshop gems, each in its own subdirectory with its own gemspec.
gemspec path: 'pikuri-extractors'
gemspec path: 'pikuri-vectordb'
gemspec path: 'pikuri-rag'
gemspec path: 'pikuri-skills'
gemspec path: 'pikuri-tasks'
gemspec path: 'pikuri-memory'
gemspec path: 'pikuri-mcp'
gemspec path: 'pikuri-lsp'
gemspec path: 'pikuri-code'
gemspec path: 'pikuri-os'
gemspec path: 'pikuri-conversations'
gemspec path: 'pikuri-stemmers'

# pikuri itself, "just" a dependency, pinned to one commit of its repo, so
# the Gemfile says which pikuri this was built against. Move it by editing
# PIKURI_REF to a commit that is already pushed, then `bundle install`.
# The gems a workshop gemspec doesn't name are the demo binaries' and the
# specs' choices: web tools, the PDF extractor for pikuri-corpus and
# vectordb's line-range spec, and Thunderbird for pikuri-computer.
PIKURI_REF = '91f5e3c6508e4a280192f564b895e0e49b060c10'
git 'https://github.com/mvysny/pikuri.git', ref: PIKURI_REF do
  gem 'pikuri-core'
  gem 'pikuri-fileindex'
  gem 'pikuri-pdf'
  gem 'pikuri-subagents'
  gem 'pikuri-thunderbird'
  gem 'pikuri-web'
  gem 'pikuri-workspace'
end

group :test do
  # Test runner. We use the rspec-core describe/it harness but write
  # assertions in minitest style — see AGENTS.md.
  gem 'rspec-core', '~> 3.13'

  # Provides the minitest-style assertion methods (assert_equal, refute,
  # …) used throughout spec/.
  gem 'minitest', '~> 6.0'

  # Finnish morphology (FFI to the distro's libvoikko) for pikuri-stemmers'
  # specs: real Voikko::Analysis values, and the real dictionary where
  # libvoikko1 + voikko-fi are installed. 0.2 brings Analysis#morphemes and
  # Voikko#language.
  gem 'voikko', '~> 0.2'
end

group :development do
  # Generates YARD docs from the inline tags required by AGENTS.md.
  gem 'yard', '~> 0.9.43'

  # Drives the Rakefile (lockstep release task + fan-out test task).
  gem 'rake', '~> 13.0'
end
