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

# pikuri itself, "just" a dependency: its git master, with Gemfile.lock
# pinning the commit; `bundle update pikuri-core` moves it. To work against
# a local checkout instead:
#   bundle config set --local local.pikuri-core ../pikuri
# The gems a workshop gemspec doesn't name are the demo binaries' and the
# specs' choices: web tools, the PDF extractor, Thunderbird for
# pikuri-computer, and vectordb for the shared Qdrant image pin.
git 'https://codeberg.org/mvysny/pikuri.git', branch: 'master' do
  gem 'pikuri-core'
  gem 'pikuri-pdf'
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
end

group :development do
  # Generates YARD docs from the inline tags required by AGENTS.md.
  gem 'yard', '~> 0.9.43'

  # Drives the Rakefile (lockstep release task + fan-out test task).
  gem 'rake', '~> 13.0'
end
