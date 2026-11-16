# frozen_string_literal: true

source 'https://rubygems.org'

# The workshop gems, each in its own subdirectory with its own gemspec.
gemspec path: 'pikuri-extractors'
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
# specs' choices: web tools, the PDF extractor, Thunderbird for
# pikuri-computer, vectordb for the shared Qdrant image pin, and rag for
# pikuri-stemmers' spec through a real FTS5 index.
PIKURI_REF = 'ea0a3e615d84778c40e6e66d05efdd9f26504cc8'
git 'https://codeberg.org/mvysny/pikuri.git', ref: PIKURI_REF do
  gem 'pikuri-core'
  gem 'pikuri-pdf'
  gem 'pikuri-rag'
  gem 'pikuri-subagents'
  gem 'pikuri-thunderbird'
  gem 'pikuri-vectordb'
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
