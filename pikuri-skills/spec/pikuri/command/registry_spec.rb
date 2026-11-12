# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

RSpec.describe Pikuri::Command::Registry do
  # Command trees are one-file-per-command, so they are cheaper to build in a
  # tmpdir per example than to commit as fixtures — and the interesting cases
  # (namespacing, shadowing, sidecars) are all about a *tree shape*.
  def with_tree(files)
    Dir.mktmpdir('pikuri-commands') do |root|
      files.each do |relative, content|
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      yield root
    end
  end

  def captured_log
    captured = StringIO.new
    original = Pikuri.log_io
    Pikuri.log_io = captured
    yield
    captured.string
  ensure
    Pikuri.log_io = original if original
  end

  describe 'discovery' do
    it 'scans both subdirs and names a command after its path' do
      with_tree(
        '.pikuri/commands/deploy.md' => "---\ndescription: ship it\n---\nDeploy.",
        '.claude/commands/frontend/build.md' => 'Build the frontend.'
      ) do |root|
        registry = described_class.new(search_bases: [root])

        assert_equal %w[deploy frontend:build], registry.list.map(&:name).sort
        assert_equal 'ship it', registry.get('deploy').description
      end
    end

    it 'takes a frontmatter-less file as an ordinary command, body and all' do
      with_tree('.pikuri/commands/plain.md' => "Just a body.\n") do |root|
        command = described_class.new(search_bases: [root]).get('plain')

        assert_equal "Just a body.\n", command.body
        assert_equal 'plain', command.description
        assert_nil command.argument_hint
      end
    end

    it 'keeps the path name and warns when frontmatter declares another' do
      with_tree('.pikuri/commands/wh.md' => "---\nname: weekly\n---\nBody.") do |root|
        log = captured_log { @registry = described_class.new(search_bases: [root]) }

        assert_equal ['wh'], @registry.list.map(&:name)
        assert_includes log, "frontmatter name 'weekly' ignored"
      end
    end

    it 'falls back to the name when a description is missing, and says so' do
      with_tree('.pikuri/commands/wh.md' => "---\nargument-hint: <label>\n---\nBody.") do |root|
        log = captured_log { @registry = described_class.new(search_bases: [root]) }

        assert_equal 'wh', @registry.get('wh').description
        assert_equal '<label>', @registry.get('wh').argument_hint
        assert_includes log, "no 'description'"
      end
    end

    it 'keeps the first command seen for a name and warns about the loser' do
      with_tree(
        '.pikuri/commands/wh.md' => 'project version',
        '.claude/commands/wh.md' => 'home version'
      ) do |root|
        log = captured_log { @registry = described_class.new(search_bases: [root]) }

        assert_equal 'project version', @registry.get('wh').body
        assert_includes log, "command name 'wh' at"
        assert_includes log, 'is shadowed by earlier entry at'
      end
    end

    it 'reports the roots it covered so a host can make them readable' do
      with_tree('.claude/commands/wh.md' => 'Body.') do |root|
        registry = described_class.new(search_bases: [root])

        assert_equal [File.join(root, '.claude/commands')], registry.roots
      end
    end
  end

  describe '#get' do
    it 'returns nil for a name nobody typed correctly' do
      with_tree('.pikuri/commands/wh.md' => 'Body.') do |root|
        assert_nil described_class.new(search_bases: [root]).get('nope')
      end
    end

    it 'raises for a command declaring allowed-tools, in either spelling' do
      with_tree(
        '.pikuri/commands/hyphen.md' => "---\nallowed-tools: Bash(git status:*)\n---\nBody.",
        '.pikuri/commands/underscore.md' => "---\nallowed_tools: Bash\n---\nBody."
      ) do |root|
        registry = described_class.new(search_bases: [root])

        %w[hyphen underscore].each do |name|
          error = assert_raises(Pikuri::Command::RefusedError) { registry.get(name) }
          assert_includes error.message, 'allowed-tools'
        end
      end
    end

    it 'raises for a body carrying a bash pre-execution directive' do
      with_tree('.pikuri/commands/status.md' => "Current status: !`git status`\n") do |root|
        error = assert_raises(Pikuri::Command::RefusedError) do
          described_class.new(search_bases: [root]).get('status')
        end

        assert_includes error.message, '!`…`'
      end
    end

    it 'detects that directive inside a fenced block too, on purpose' do
      with_tree('.pikuri/commands/doc.md' => "About the syntax:\n\n```\n!`git status`\n```\n") do |root|
        assert_raises(Pikuri::Command::RefusedError) do
          described_class.new(search_bases: [root]).get('doc')
        end
      end
    end

    it 'keeps a refused command in #list so the human can be told why' do
      with_tree('.pikuri/commands/status.md' => 'Run !`git status`') do |root|
        command = described_class.new(search_bases: [root]).list.first

        assert_equal 'status', command.name
        assert command.refused?
      end
    end
  end

  describe '#expand' do
    it 'is get + render in one call' do
      with_tree('.pikuri/commands/wh.md' => 'Log for $ARGUMENTS.') do |root|
        assert_equal 'Log for swingai.',
                     described_class.new(search_bases: [root]).expand('wh', arguments: 'swingai')
      end
    end

    it 'returns nil for an unknown name and raises for a refused one' do
      with_tree(
        '.pikuri/commands/wh.md' => 'Body.',
        '.pikuri/commands/status.md' => 'Run !`git status`'
      ) do |root|
        registry = described_class.new(search_bases: [root])

        assert_nil registry.expand('nope')
        assert_raises(Pikuri::Command::RefusedError) { registry.expand('status') }
      end
    end
  end

  describe '#untrusted_level' do
    it 'is hard over a base nobody vouched for' do
      with_tree('.claude/commands/wh.md' => 'Body.') do |root|
        assert_equal :hard, described_class.new(search_bases: [root]).untrusted_level
      end
    end

    it 'drops when every stored command came from a vouched base' do
      with_tree('.claude/commands/wh.md' => 'Body.') do |root|
        registry = described_class.new(
          search_bases: [Pikuri::Bundle::Base.new(dir: root, trusted: true)]
        )

        assert_equal :none, registry.untrusted_level
      end
    end

    it 'is none for an empty registry' do
      Dir.mktmpdir('pikuri-commands') do |root|
        registry = described_class.new(search_bases: [root])

        assert registry.empty?
        assert_equal :none, registry.untrusted_level
      end
    end

    it 'ignores a refused command, whose bytes can never reach the context' do
      with_tree('.claude/commands/status.md' => 'Run !`git status`') do |root|
        assert_equal :none, described_class.new(search_bases: [root]).untrusted_level
      end
    end
  end

  describe 'sidecar detection' do
    it 'is off for a directory of nothing but commands' do
      with_tree(
        '.pikuri/commands/wh.md' => 'Body.',
        '.pikuri/commands/frontend/build.md' => 'Body.'
      ) do |root|
        registry = described_class.new(search_bases: [root])

        refute registry.get('wh').sidecars?
        refute registry.get('frontend:build').sidecars?
      end
    end

    it 'is on when the directory holds something the registry did not load' do
      with_tree(
        '.pikuri/commands/wh.md' => 'Body.',
        '.pikuri/commands/report-template.txt' => 'a template'
      ) do |root|
        assert described_class.new(search_bases: [root]).get('wh').sidecars?
      end
    end
  end
end
