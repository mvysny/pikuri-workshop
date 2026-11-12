# frozen_string_literal: true

RSpec.describe Pikuri::Code::Bash::Tokenizer do
  def tok(command)
    described_class.tokenize(command)
  end

  describe 'segments and words' do
    it 'splits a bare command into one segment of words' do
      assert_equal [%w[grep -w install]], tok('grep -w install')
    end

    it 'splits a chain on every sequencer operator' do
      assert_equal [%w[ls], %w[pwd]], tok('ls && pwd')
      assert_equal [%w[ls], %w[pwd]], tok('ls||pwd')
      assert_equal [%w[ls], %w[pwd]], tok('ls ; pwd')
      assert_equal [%w[ps aux], %w[grep ssh]], tok('ps aux | grep ssh')
      assert_equal [%w[ls], %w[pwd], %w[df -h]], tok("ls\npwd\ndf -h")
    end

    it 'keeps a pure-comment segment as an empty word list (a no-op)' do
      assert_equal [[], %w[ls]], tok("# explain\nls")
    end
  end

  describe 'single-quote removal' do
    it 'drops the marks and keeps the interior as one literal word' do
      assert_equal [%w[grep -w install]], tok("grep -w 'install'")
      assert_equal [['grep', 'foo bar', '/etc/hosts']], tok("grep 'foo bar' /etc/hosts")
      assert_equal [['grep', '']], tok("grep ''") # empty quoted arg is a real word
    end

    it 'treats an interior operator/metacharacter as literal, not structural' do
      assert_equal [['echo', 'a | b']], tok("echo 'a | b'")   # quoted pipe does not split
      assert_equal [['echo', 'a && b']], tok("echo 'a && b'")
      assert_equal [['ls ; rm']], tok("ls' ; 'rm")            # concatenates to one word
    end

    it 'hands back the TRUE de-quoted word (no placeholder), collapsing empty pairs' do
      # The crux: --''clear must decode to --clear so a denylist sees it.
      assert_equal [%w[dmesg --clear]], tok("dmesg --''clear")
      assert_equal [%w[dmesg --clear]], tok("dmesg --cl'e'ar")
      assert_equal [%w[git diff --output=/x]], tok("git diff --''output=/x")
    end

    it 'returns nil on an unbalanced single quote' do
      assert_nil tok("grep 'foo")
    end
  end

  describe 'double-quote removal (inert interior only)' do
    it 'drops the marks and keeps the interior as one literal word' do
      assert_equal [['cat', 'f'], ['echo', ' bytes']], tok('cat f && echo " bytes"')
      assert_equal [['grep', 'foo bar', '/etc/hosts']], tok('grep "foo bar" /etc/hosts')
      assert_equal [['grep', '']], tok('grep ""') # empty quoted arg is a real word
    end

    it 'treats an interior operator/metacharacter as literal, not structural' do
      assert_equal [['echo', 'a | b']], tok('echo "a | b"')   # quoted pipe does not split
      assert_equal [['echo', 'a && b']], tok('echo "a && b"')
      assert_equal [['echo', "a\nb"]], tok(%(echo "a\nb"))    # quoted newline does not split
      assert_equal [['echo', 'a * b ~ #c']], tok('echo "a * b ~ #c"')
    end

    it 'concatenates across quote styles and keeps the other quote literal' do
      assert_equal [%w[echo abc]], tok(%q(echo "a"'b'c))
      assert_equal [['echo', 'say "hi"']], tok(%q(echo 'say "hi"')) # " inside '...'
      assert_equal [['echo', "it's"]], tok(%q(echo "it's")) # ' inside "..."
    end

    it 'hands back the TRUE de-quoted word (no placeholder), collapsing empty pairs' do
      assert_equal [%w[dmesg --clear]], tok('dmesg --""clear')
      assert_equal [%w[dmesg --clear]], tok('dmesg --cl"e"ar')
      assert_equal [%w[git diff --output=/x]], tok('git diff --"output"=/x')
    end

    it 'keeps ! literal (history expansion is interactive-only; Bash spawns bash -c)' do
      assert_equal [['echo', 'done!']], tok('echo "done!"')
    end

    it 'returns nil the moment a POSIX-live byte appears inside the span' do
      assert_nil tok('echo "$HOME"')          # parameter expansion
      assert_nil tok('echo "$(rm -rf ~)"')    # command substitution
      assert_nil tok('echo "`rm`"')           # backtick substitution
      assert_nil tok('echo "a\\"b; rm x"')    # backslash — the escaped-quote mis-parse bait
      assert_nil tok('echo "a\\nb"')          # backslash, even a harmless-looking one
    end

    it 'returns nil on an unbalanced double quote' do
      assert_nil tok('grep "foo')
    end
  end

  describe 'forbidden bytes (more than a simple chain)' do
    [
      'echo $(rm -rf ~)',        # command substitution
      'echo `rm`',               # backtick
      'echo a\\;b',              # backslash stays forbidden
      'ls *.txt',                # glob
      'ls ~/secret',             # tilde
      'rm -rf {a,b}',            # brace
      'ls & pwd',                # lone & (background) is not a sequencer
      'ls |& grep x'             # |& leaves a stray &
    ].each do |command|
      it "returns nil for #{command.inspect}" do
        assert_nil tok(command)
      end
    end
  end

  describe 'allow_glob: keeps unquoted glob/brace/tilde bytes literal' do
    def gtok(command)
      described_class.tokenize(command, allow_glob: true)
    end

    it 'keeps an unquoted glob byte as a literal word byte' do
      assert_equal [%w[ls *.txt]], gtok('ls *.txt')
      assert_equal [%w[ls *]], gtok('ls *')
      assert_equal [['cat', '~/notes/*.md']], gtok('cat ~/notes/*.md')
      assert_equal [['ls', 'a{1,2}b']], gtok('ls a{1,2}b')
      assert_equal [['cat', '[a-z]*.txt', 'file?.txt']], gtok('cat [a-z]*.txt file?.txt')
    end

    it 'still splits, de-quotes and drops safe redirects around globs' do
      assert_equal [%w[ls *], %w[wc -l]], gtok('ls * | wc -l')
      assert_equal [%w[ls *.log]], gtok('ls *.log 2>/dev/null')
    end

    it 'still rejects every non-glob complication' do
      assert_nil gtok('ls $(rm)*')       # command substitution
      assert_nil gtok('ls * > out')      # real redirect
      assert_nil gtok('ls `rm`*')        # backtick
      assert_nil gtok('ls * && ')        # dangling sequencer
    end

    it 'is off by default (a glob still rejects)' do
      assert_nil tok('ls *.txt')
      assert_nil tok('ls ~/secret')
    end
  end

  describe 'redirects' do
    it 'consumes and drops write-nothing redirects' do
      assert_equal [%w[dpkg -S /bin/ls]], tok('dpkg -S /bin/ls 2>&1')
      assert_equal [%w[cat /etc/hostname]], tok('cat /etc/hostname >/dev/null')
      assert_equal [%w[ls]], tok('ls 2>&1 >/dev/null')
    end

    it 'returns nil for a redirect to a real file' do
      assert_nil tok('ls > out.txt')
      assert_nil tok('cat x 2>/tmp/err')
      assert_nil tok('ls 2>/dev/nullx')      # /dev/null look-alike
    end
  end

  describe 'structural nil cases' do
    it 'returns nil for an empty (dangling) segment' do
      assert_nil tok('ls && ')
      assert_nil tok('&& ls')
      assert_nil tok('ls ;; pwd')
    end

    it 'returns nil beyond MAX_CHAIN segments' do
      assert_nil tok((['ls'] * 65).join(' && '))
      assert_equal 64, tok((['ls'] * 64).join(' && ')).size
    end

    it 'returns nil for an empty command' do
      assert_nil tok('')
    end
  end
end
