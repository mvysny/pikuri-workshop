# frozen_string_literal: true

RSpec.describe Pikuri::Command::Renderer do
  def command(body, name: 'wh', location: '/home/u/.claude/commands/wh.md', sidecars: false)
    Pikuri::Command::Registry::Command.new(
      name: name, description: name, argument_hint: nil,
      location: location, body: body, refusal: nil, sidecars: sidecars
    )
  end

  describe 'substitution' do
    it 'replaces $ARGUMENTS with the raw argument string' do
      assert_equal 'Log for swingai --since 2026-08-10.',
                   described_class.expand(command('Log for $ARGUMENTS.'),
                                          arguments: 'swingai --since 2026-08-10')
    end

    it 'indexes $1..$9 one-based, whitespace-split' do
      assert_equal 'a=AAA b=BBB c=CCC',
                   described_class.expand(command('a=$1 b=$2 c=$3'), arguments: 'AAA BBB CCC')
    end

    it 'leaves an out-of-range $n as literal text rather than blanking it' do
      assert_equal 'one=swingai two=$2',
                   described_class.expand(command('one=$1 two=$2'), arguments: 'swingai')
    end

    it 'does not try to parse quotes: a multi-word argument is several tokens' do
      assert_equal '["two] [words"]',
                   described_class.expand(command('[$1] [$2]'), arguments: '"two words"')
    end
  end

  describe 'code spans and fences' do
    it 'leaves a backticked mention alone' do
      body = 'Read it off `$ARGUMENTS` rather than `$1`.'

      assert_equal body, described_class.expand(command(body), arguments: 'swingai').lines.first.chomp
    end

    it 'leaves shell positionals in a fenced block alone' do
      body = "Emit:\n\n```bash\ndeploy_to \"$1\" --tag \"$2\"\n```\n"

      assert_includes described_class.expand(command(body), arguments: 'staging v3'),
                      'deploy_to "$1" --tag "$2"'
    end

    it 'still substitutes prose on the same line as a code span' do
      assert_equal 'Run `git log` for swingai',
                   described_class.expand(command('Run `git log` for $ARGUMENTS'), arguments: 'swingai')
    end
  end

  describe 'the unreferenced-arguments append' do
    it "appends Claude Code's exact spelling when the body names neither token" do
      out = described_class.expand(command('Summarize the week.'), arguments: 'swingai')

      assert_equal "Summarize the week.\n\n\nARGUMENTS: swingai", out
    end

    it 'appends nothing when no arguments were typed' do
      assert_equal 'Summarize the week.', described_class.expand(command('Summarize the week.'))
    end

    it 'appends nothing when the body really uses a placeholder' do
      refute_includes described_class.expand(command('Log for $ARGUMENTS.'), arguments: 'swingai'),
                      'ARGUMENTS: swingai'
    end

    # The file that motivated the whole feature: every $ARGUMENTS in wh.md sits
    # inside a code span, so fence-aware substitution leaves the body untouched
    # and the append is the *only* thing carrying the typed argument. Read the
    # body blind here and the word vanishes with no error at all.
    it 'fires for a body whose every mention is backticked' do
      body = "Invoked as `/wh $ARGUMENTS`.\n\nRead the label off `$ARGUMENTS`.\n"
      out = described_class.expand(command(body), arguments: 'swingai')

      assert_includes out, 'Invoked as `/wh $ARGUMENTS`.'
      assert out.end_with?("ARGUMENTS: swingai"), out
    end
  end

  describe 'the sidecar footer' do
    it 'names the directory so the model can resolve a path the body mentions' do
      out = described_class.expand(
        command("See @docs/style.md.\n", location: '/repo/.pikuri/commands/lint.md', sidecars: true)
      )

      assert_equal "See @docs/style.md.\n\n(this command lives in /repo/.pikuri/commands)", out
    end

    it 'is absent for a command with no sidecars' do
      refute_includes described_class.expand(command('Body.')), 'this command lives in'
    end
  end
end
