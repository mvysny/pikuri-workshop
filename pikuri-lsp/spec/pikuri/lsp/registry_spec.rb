# frozen_string_literal: true

describe Pikuri::Lsp::Registry do
  entry = Pikuri::Lsp::Registry::StdioEntry
  ruby = entry.new(id: 'ruby', command: %w[ruby-lsp], files: %w[*.rb *.rake *.gemspec Rakefile Gemfile])
  java = entry.new(id: 'java', command: %w[jdtls -data /tmp/x], files: %w[*.java],
                   env: { 'JAVA_HOME' => '/usr/lib/jvm/java-21' },
                   init_options: { extendedClientCapabilities: { classFileContentsSupport: true } })

  describe Pikuri::Lsp::Registry::StdioEntry do
    it 'derives the language id from the first extension-bearing glob' do
      assert_equal 'ruby', ruby.language_id
      assert_equal 'java', java.language_id
    end

    it 'takes an explicit language id over the table' do
      assert_equal 'erb', entry.new(id: 'erb', command: %w[x], files: %w[*.rb], language_id: 'erb').language_id
    end

    it 'refuses to guess when no glob carries a known extension' do
      error = assert_raises(ArgumentError) { entry.new(id: 'make', command: %w[x], files: %w[Makefile]) }
      assert_includes error.message, 'language_id'
    end

    it 'matches globs against the basename, so a directory never picks the server' do
      assert ruby.claims?('/home/m/pikuri/lib/pikuri/agent.rb')
      assert ruby.claims?('Rakefile'), 'a glob, not an extension — Rakefile has none'
      assert ruby.claims?('/home/m/pikuri/Gemfile')
      refute ruby.claims?('/home/m/ruby-project/README.md'), 'a path saying "ruby" is not a Ruby file'
      refute ruby.claims?('Main.java')
      assert java.claims?('src/main/java/Main.java')
    end

    it 'carries the two per-server escape hatches verbatim' do
      assert_equal({ 'JAVA_HOME' => '/usr/lib/jvm/java-21' }, java.env)
      assert_equal({ extendedClientCapabilities: { classFileContentsSupport: true } }, java.init_options)
      assert_equal({}, ruby.env)
      assert_nil ruby.init_options
    end

    it 'refuses a configuration that cannot launch or dispatch' do
      assert_raises(ArgumentError) { entry.new(id: '', command: %w[ruby-lsp], files: %w[*.rb]) }
      assert_raises(ArgumentError) { entry.new(id: 'ruby', command: [], files: %w[*.rb]) }
      assert_raises(ArgumentError) { entry.new(id: 'ruby', command: %w[ruby-lsp], files: []) }
    end
  end

  describe '#entry_for' do
    registry = described_class.new(entries: [ruby, java])

    it 'picks the first server that claims the file' do
      assert_equal 'ruby', registry.entry_for('lib/pikuri/agent.rb').id
      assert_equal 'java', registry.entry_for('Main.java').id
    end

    it 'answers nil for a file no server claims' do
      assert_nil registry.entry_for('README.md')
    end

    it 'resolves an overlap by declaration order, silently' do
      greedy = entry.new(id: 'greedy', command: %w[x], files: %w[*.rb])
      assert_equal 'greedy', described_class.new(entries: [greedy, ruby]).entry_for('a.rb').id
      assert_equal 'ruby', described_class.new(entries: [ruby, greedy]).entry_for('a.rb').id
    end
  end

  it 'refuses duplicate ids, which would collide in logs and progress bars' do
    error = assert_raises(ArgumentError) { described_class.new(entries: [ruby, ruby]) }
    assert_includes error.message, 'ruby'
  end

  describe '.from_h' do
    # What a host's own config file looks like once parsed — String keys, Arrays
    # and Hashes, nothing pikuri-shaped. This is the YAML in the class docs.
    config = {
      'ruby' => { 'command' => ['ruby-lsp'], 'files' => ['*.rb', 'Rakefile'] },
      'java' => { 'command' => ['jdtls', '-data', '/home/me/.cache/pikuri/jdtls/app'],
                  'files' => ['*.java'],
                  'env' => { 'JAVA_HOME' => '/usr/lib/jvm/java-21' },
                  'init_options' => { 'extendedClientCapabilities' => { 'classFileContentsSupport' => true } } }
    }

    it 'maps a parsed config file onto entries, keyed by id, in declaration order' do
      registry = described_class.from_h(config)
      assert_equal %w[ruby java], registry.entries.map(&:id)
      assert_equal %w[ruby-lsp], registry.entry_for('lib/pikuri/agent.rb').command
      assert_equal 'ruby', registry.entry_for('Rakefile').language_id, 'derived, as from a Ruby literal'
    end

    it 'carries env and init_options through untouched' do
      java = described_class.from_h(config).entry_for('Main.java')
      assert_equal({ 'JAVA_HOME' => '/usr/lib/jvm/java-21' }, java.env)
      # String keys, because that is what a config file yields; they encode to
      # the same JSON the Symbol keys of a Ruby literal do.
      assert_equal({ 'extendedClientCapabilities' => { 'classFileContentsSupport' => true } }, java.init_options)
    end

    it 'takes Symbol keys too, for a host holding its config in Ruby' do
      registry = described_class.from_h(ruby: { command: %w[ruby-lsp], files: %w[*.rb], language_id: 'ruby' })
      assert_equal 'ruby', registry.entries.first.id
      assert_equal %w[*.rb], registry.entries.first.files
    end

    it 'reads an absent config section as no servers, so no host needs an || {}' do
      assert described_class.from_h(nil).empty?
      assert described_class.from_h({}).empty?
    end

    it 'refuses an unknown field rather than dropping it silently' do
      error = assert_raises(ArgumentError) do
        described_class.from_h('ruby' => { 'command' => %w[ruby-lsp], 'files' => %w[*.rb], 'envs' => {} })
      end
      assert_includes error.message, 'ruby'
      assert_includes error.message, 'envs'
      assert_includes error.message, 'init_options', 'the message enumerates what it would have accepted'
    end

    it 'refuses a command or files written as one string instead of a list' do
      error = assert_raises(ArgumentError) do
        described_class.from_h('ruby' => { 'command' => 'ruby-lsp', 'files' => %w[*.rb] })
      end
      assert_includes error.message, 'command'
      assert_raises(ArgumentError) do
        described_class.from_h('ruby' => { 'command' => %w[ruby-lsp], 'files' => '*.rb' })
      end
      assert_raises(ArgumentError) { described_class.from_h('ruby' => { 'files' => %w[*.rb] }) }
    end

    it 'refuses an env value a config file left unquoted — the child environment holds strings' do
      error = assert_raises(ArgumentError) do
        described_class.from_h('ruby' => { 'command' => %w[x], 'files' => %w[*.rb], 'env' => { 'PORT' => 8080 } })
      end
      assert_includes error.message, 'PORT'
      assert_includes error.message, '8080'
    end

    it 'refuses a field of the wrong type, naming the server it came from' do
      error = assert_raises(ArgumentError) do
        described_class.from_h('java' => { 'command' => %w[jdtls], 'files' => %w[*.java],
                                           'init_options' => 'classFileContentsSupport' })
      end
      assert_includes error.message, 'java'
      assert_includes error.message, 'init_options'
      assert_raises(ArgumentError) { described_class.from_h('ruby' => ['ruby-lsp']) }
    end

    it 'passes what it built through the same construction a Ruby literal gets' do
      error = assert_raises(ArgumentError) do
        described_class.from_h('make' => { 'command' => %w[x], 'files' => %w[Makefile] })
      end
      assert_includes error.message, 'language_id', 'StdioEntry still refuses to guess'
    end

    it 'cannot express the duplicate id a list of entries could' do
      assert_equal 1, described_class.from_h('ruby' => { 'command' => %w[a], 'files' => %w[*.rb] }).entries.size
    end
  end

  it 'has an empty singleton for a host that configures nothing' do
    assert described_class::EMPTY.empty?
    assert_nil described_class::EMPTY.entry_for('a.rb')
    refute described_class.new(entries: [ruby]).empty?
  end
end
