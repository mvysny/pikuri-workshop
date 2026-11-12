# frozen_string_literal: true

RSpec.describe Pikuri::Skill::PathMatcher do
  # Warnings go through Pikuri's logger, which the spec_helper points at
  # /dev/null; redirect to a StringIO so the fail-open warning can be asserted.
  def captured_log
    captured = StringIO.new
    original = Pikuri.log_io
    Pikuri.log_io = captured
    yield
    captured.string
  ensure
    Pikuri.log_io = original if original
  end

  def parse(value)
    described_class.parse(value, path: '/skills/x/SKILL.md')
  end

  describe 'the unconditional spellings' do
    it 'treats an absent key as unconditional' do
      assert_equal [], parse(nil)
    end

    it 'treats an empty list as unconditional, not as "matches nothing"' do
      assert_equal [], parse([])
    end

    it 'treats a match-all pattern as unconditional' do
      assert_equal [], parse(['**'])
      assert_equal [], parse('**')
    end

    it 'treats a list of nothing but match-all patterns as unconditional' do
      assert_equal [], parse(['**', '/**'])
    end
  end

  describe 'sequences' do
    it 'keeps the patterns in the authored order' do
      assert_equal ['**/*.rb', '**/*.gemspec'], parse(['**/*.rb', '**/*.gemspec'])
    end

    it 'strips a trailing /** so src and src/** compare equal' do
      assert_equal parse(['src']), parse(['src/**'])
      assert_equal ['src'], parse(['src/**'])
    end

    it 'strips the suffix once only' do
      assert_equal ['src/**'], parse(['src/**/**'])
    end

    it 'drops blank entries' do
      assert_equal ['docs'], parse(['', '  ', 'docs'])
    end
  end

  describe 'scalars' do
    it 'comma-splits a single string' do
      assert_equal %w[src docs], parse('src/**, docs')
    end

    it 'protects commas inside a brace group' do
      assert_equal ['{app,lib}/**/*.rb', 'spec'], parse('{app,lib}/**/*.rb, spec')
    end

    it 'comma-splits inside a sequence element too' do
      assert_equal %w[src docs spec], parse(['src, docs', 'spec'])
    end
  end

  describe 'a value that is neither' do
    it 'warns and leaves the skill unconditional rather than hiding it' do
      log = captured_log { assert_equal [], parse({ 'src' => true }) }
      assert_match(/'paths:' must be a string or a list of strings/, log)
      assert_match(/stays unconditional/, log)
    end

    it 'refuses a mixed list rather than reading half of it' do
      log = captured_log { assert_equal [], parse(['src', 42]) }
      assert_match(/must be a string or a list of strings/, log)
    end

    it 'says nothing when the key is simply absent' do
      log = captured_log { parse(nil) }
      assert_equal '', log
    end
  end

  # Every expectation below was cross-checked against ripgrep's gitignore
  # engine — the pattern in a .gitignore, the paths as files, `rg --files`
  # naming the survivors — so the dialect claim is measured, not asserted.
  describe '.match?' do
    def match?(patterns, path) = described_class.match?(patterns, path)

    it 'floats a slash-less pattern to any depth' do
      assert match?(['build.gradle'], 'app/sub/build.gradle')
      assert match?(['*.rb'], 'lib/pikuri/agent.rb')
      refute match?(['*.rb'], 'lib/agent.rbx')
    end

    it 'roots a pattern carrying a slash at the workspace' do
      assert match?(['src/main'], 'src/main/A.java')
      refute match?(['src/main'], 'other/src/main/A.java')
    end

    it 'roots a leading-slash pattern and drops the slash itself' do
      assert match?(['/README.md'], 'README.md')
      refute match?(['/README.md'], 'docs/README.md')
    end

    it 'matches everything beneath a bare directory' do
      assert match?(['ideas'], 'ideas')
      assert match?(['ideas'], 'ideas/sub/deep/note.md')
      refute match?(['ideas'], 'nonideas/note.md')
    end

    it 'reads a trailing slash as the same directory pattern' do
      assert match?(['ideas/'], 'ideas/note.md')
    end

    it 'spans any number of directories per **, including none' do
      pattern = ['src/**/java/**/*.java']
      assert match?(pattern, 'src/main/java/com/foo/Bar.java')
      assert match?(pattern, 'src/java/Bar.java')
      refute match?(pattern, 'src/main/kotlin/com/foo/Bar.kt')
      refute match?(pattern, 'other/src/main/java/com/foo/Bar.java')
    end

    it 'keeps a lone * inside one path segment' do
      assert match?(['lib/*.rb'], 'lib/agent.rb')
      refute match?(['lib/*.rb'], 'lib/pikuri/agent.rb')
    end

    it 'expands a brace group, as ripgrep does and git itself does not' do
      assert match?(['{app,lib}/**/*.rb'], 'lib/pikuri/agent.rb')
      refute match?(['{app,lib}/**/*.rb'], 'spec/agent_spec.rb')
      assert match?(['*.{java,kt}'], 'src/Bar.kt')
    end

    it 'descends into a dotted directory' do
      assert match?(['.claude/**'], '.claude/skills/x/SKILL.md')
    end

    it 'roots a /** that survived normalization, rather than floating it' do
      assert match?(['src/**'], 'src/a/b.rb')
      refute match?(['src/**'], 'other/src/a.rb')
    end

    it 'fires on the first pattern that matches' do
      assert match?(%w[docs src/main], 'src/main/A.java')
      refute match?(%w[docs src/main], 'spec/a_spec.rb')
    end

    it 'matches a path that does not exist yet, so a write target fires' do
      assert match?(['ideas'], 'ideas/not-written-yet.md')
    end

    it 'matches nothing for an unconditional spec' do
      refute match?(described_class::UNCONDITIONAL, 'src/main/A.java')
    end

    it 'tolerates the ./ a caller may leave on a relative path' do
      assert match?(['ideas'], './ideas/note.md')
    end

    it 'refuses an absolute path rather than matching the wrong tree' do
      error = assert_raises(ArgumentError) { match?(['ideas'], '/home/x/ideas/note.md') }
      assert_match(%r{workspace-relative.*/home/x/ideas/note\.md}, error.message)
    end

    it 'matches what parse produced, brace group and comma split intact' do
      patterns = parse('{app,lib}/**/*.rb, docs')
      assert match?(patterns, 'lib/pikuri/agent.rb')
      assert match?(patterns, 'docs/guide/intro.md')
      refute match?(patterns, 'spec/agent_spec.rb')
    end
  end
end
