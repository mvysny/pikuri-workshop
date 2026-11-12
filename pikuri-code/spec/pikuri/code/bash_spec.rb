# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Code::Bash do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-bash-root-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:confirmer) { build_confirmer(true) }
  let(:tool)      { described_class.new(filesystem: filesystem, confirmer: confirmer) }

  after do
    FileUtils.rm_rf(root)
    # Belt and braces: kill any background subprocesses a spec spawned
    # past its #wait point (timeout tests in particular).
    Pikuri::Subprocess.cleanup!
  end

  # Inline confirmer double: records every request it sees, returns
  # successive elements of +answers+. Each answer is +true+ (→ Approved
  # carrying the command unchanged), +false+ (→ Rejected), or an explicit
  # Approved/Rejected/Redirected value. Calling +ask+ when no
  # answer is queued raises — surfaces "test silently consumed a
  # confirmation" bugs rather than letting nil flow through as a decline.
  def build_confirmer(*answers)
    queue    = answers.dup
    requests = []
    cf = Object.new
    cf.define_singleton_method(:ask) do |request:|
      requests << request
      raise "build_confirmer received an unexpected #ask call (request: #{request.inspect})" if queue.empty?

      case (answer = queue.shift)
      when true  then Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: request.detail)
      when false then Pikuri::Workspace::Confirmer::Rejected.new
      else answer
      end
    end
    cf.define_singleton_method(:requests) { requests }
    cf
  end

  describe '.run happy path' do
    it 'runs the command and returns command-echo + output + exit status' do
      result = described_class.run(filesystem: filesystem, confirmer: confirmer,
                                   command: 'echo hello', description: nil, timeout: 120).to_s

      assert_equal "$ echo hello\nhello\n\n\nexit status: 0", result
    end

    it 'combines stdout and stderr into one stream' do
      result = described_class.run(filesystem: filesystem, confirmer: confirmer,
                                   command: 'echo out; echo err >&2',
                                   description: nil, timeout: 120).to_s

      assert_includes result, 'out'
      assert_includes result, 'err'
      assert_includes result, 'exit status: 0'
    end

    it 'reports non-zero exit status as a normal observation (not an Error)' do
      result = described_class.run(filesystem: filesystem, confirmer: confirmer,
                                   command: 'exit 3', description: nil, timeout: 120).to_s

      refute result.start_with?('Error:'), "expected non-Error observation, got #{result.inspect}"
      assert_includes result, 'exit status: 3'
    end

    it 'runs in the workspace project_root' do
      result = described_class.run(filesystem: filesystem, confirmer: confirmer,
                                   command: 'pwd', description: nil, timeout: 120).to_s

      assert_includes result, root.to_s
    end
  end

  describe '.run confirmation' do
    it 'composes the request with description and a non-default timeout' do
      cf = build_confirmer(true)

      described_class.run(filesystem: filesystem, confirmer: cf,
                          command: 'ls -la', description: 'List files',
                          timeout: 300)

      request = cf.requests.first
      assert_equal 'OK to run bash: List files [Timeout: 300s]', request.question
      assert_equal '$ ls -la', request.detail
    end

    it 'drops the trailing colon when no description is given' do
      cf = build_confirmer(true)

      described_class.run(filesystem: filesystem, confirmer: cf,
                          command: 'pwd', description: nil, timeout: 120)

      assert_equal 'OK to run bash', cf.requests.first.question
    end

    it 'omits the timeout suffix at the default 120s' do
      cf = build_confirmer(true)

      described_class.run(filesystem: filesystem, confirmer: cf,
                          command: 'pwd', description: 'Print working dir',
                          timeout: 120)

      assert_equal 'OK to run bash: Print working dir', cf.requests.first.question
    end

    it 'includes the timeout suffix when non-default with no description' do
      cf = build_confirmer(true)

      described_class.run(filesystem: filesystem, confirmer: cf,
                          command: 'pwd', description: nil, timeout: 300)

      assert_equal 'OK to run bash [Timeout: 300s]', cf.requests.first.question
    end

    it 'treats whitespace-only description as no description' do
      cf = build_confirmer(true)

      described_class.run(filesystem: filesystem, confirmer: cf,
                          command: 'pwd', description: '   ', timeout: 120)

      assert_equal 'OK to run bash', cf.requests.first.question
    end

    it 'returns a decline-Error when the user rejects' do
      cf = build_confirmer(false)

      result = described_class.run(filesystem: filesystem, confirmer: cf,
                                   command: 'rm -rf /', description: nil, timeout: 120).to_s

      assert_equal "Error: user declined the bash command. Don't retry it or reach the same end another way; tell the user you stopped.", result
      assert_equal 1, cf.requests.size
    end

    it 'quotes a redirect back to the model, not as an error' do
      cf = build_confirmer(Pikuri::Workspace::Confirmer::Redirected.new(message: 'too risky right now'))

      result = described_class.run(filesystem: filesystem, confirmer: cf,
                                   command: 'rm -rf /', description: nil, timeout: 120)

      refute result.error?
      assert_equal 'The user declined the bash command and said: too risky right now', result.content
    end
  end

  describe '.run passive_detector' do
    # A predicate that approves iff the command matches a fixed string —
    # enough to prove the branch without pulling in PassiveCommandDetector.
    def approver_for(ok)
      Object.new.tap { |o| o.define_singleton_method(:passive?) { |cmd| cmd == ok } }
    end

    it 'runs an approved command WITHOUT consulting the confirmer' do
      cf = build_confirmer # empty queue → #ask raises if reached
      result = described_class.run(filesystem: filesystem, confirmer: cf,
                                   passive_detector: approver_for('echo hi'),
                                   command: 'echo hi', description: nil, timeout: 120).to_s

      assert_equal "$ echo hi\nhi\n\n\nexit status: 0", result
      assert_empty cf.requests, 'an approved command must not reach the confirmer'
    end

    it 'falls through to the confirmer for a command the approver does not vouch for' do
      cf = build_confirmer(false) # rejects
      result = described_class.run(filesystem: filesystem, confirmer: cf,
                                   passive_detector: approver_for('echo hi'),
                                   command: 'rm -rf /', description: nil, timeout: 120).to_s

      assert_equal "Error: user declined the bash command. Don't retry it or reach the same end another way; tell the user you stopped.", result
      assert_equal 1, cf.requests.size
    end
  end

  describe '.run input validation' do
    it 'rejects empty command before consulting the confirmer' do
      cf = build_confirmer # no answers queued

      result = described_class.run(filesystem: filesystem, confirmer: cf,
                                   command: '', description: nil, timeout: 120).to_s

      assert_equal 'Error: empty bash command.', result
      assert_equal [], cf.requests
    end

    it 'rejects whitespace-only command' do
      cf = build_confirmer
      result = described_class.run(filesystem: filesystem, confirmer: cf,
                                   command: "  \t\n  ", description: nil, timeout: 120).to_s

      assert_equal 'Error: empty bash command.', result
      assert_equal [], cf.requests
    end

    it 'rejects timeout < 1 before consulting the confirmer' do
      cf = build_confirmer
      result = described_class.run(filesystem: filesystem, confirmer: cf,
                                   command: 'echo hi', description: nil, timeout: 0).to_s

      assert_equal 'Error: timeout must be >= 1, got 0', result
      assert_equal [], cf.requests
    end

    it 'rejects timeout > MAX_TIMEOUT before consulting the confirmer' do
      cf = build_confirmer
      result = described_class.run(filesystem: filesystem, confirmer: cf,
                                   command: 'echo hi', description: nil, timeout: 601).to_s

      assert_equal 'Error: timeout must be <= 600, got 601', result
      assert_equal [], cf.requests
    end
  end

  describe '.run timeout' do
    it 'returns a timeout Error when the command exceeds the limit' do
      # 1s timeout, sleeping 3s: timeout sends SIGTERM, sleep handles it,
      # exits via signal — `timeout` exits 124.
      result = described_class.run(filesystem: filesystem, confirmer: confirmer,
                                   command: 'sleep 3', description: nil, timeout: 1).to_s

      assert result.start_with?('Error: command timed out after 1s'),
             "expected timeout Error, got #{result.inspect}"
      assert_includes result, 'SIGTERM, then SIGKILL'
      assert_includes result, '$ sleep 3'
    end

    it 'includes any partial output captured before the timeout' do
      # Print before sleeping so popen2e's pipe carries the line; then
      # block past the 1s timeout. Echo's stdout is line-buffered, so
      # the line lands before the sleep.
      result = described_class.run(filesystem: filesystem, confirmer: confirmer,
                                   command: 'echo partial; sleep 3',
                                   description: nil, timeout: 1).to_s

      assert result.start_with?('Error: command timed out'),
             "expected timeout Error, got #{result.inspect}"
      assert_includes result, 'partial'
    end
  end

  describe '.git_hardening_delta (git config-execution hardening)' do
    # Even a read-only `git diff`/`status` runs whatever the repo config
    # directs (core.fsmonitor); these keys force the GIT_CONFIG_* env
    # protocol, which overrides a hostile repo-local .git/config. See
    # Bash::GIT_HARDENING.

    it 'forces core.fsmonitor=false and core.pager=cat at indices 0,1 with no inherited count' do
      saved = ENV.delete('GIT_CONFIG_COUNT')
      delta = described_class.send(:git_hardening_delta)

      assert_equal '2', delta['GIT_CONFIG_COUNT']
      assert_equal 'core.fsmonitor', delta['GIT_CONFIG_KEY_0']
      assert_equal 'false',          delta['GIT_CONFIG_VALUE_0']
      assert_equal 'core.pager',     delta['GIT_CONFIG_KEY_1']
      assert_equal 'cat',            delta['GIT_CONFIG_VALUE_1']
    ensure
      ENV['GIT_CONFIG_COUNT'] = saved unless saved.nil?
    end

    it 'offsets past an inherited GIT_CONFIG_COUNT so host entries are not clobbered' do
      saved = ENV['GIT_CONFIG_COUNT']
      ENV['GIT_CONFIG_COUNT'] = '2'
      delta = described_class.send(:git_hardening_delta)

      # Ours append at 2,3 (higher index ⇒ wins on duplicate key); the
      # host's KEY_0/KEY_1 are left untouched (absent from our delta).
      assert_equal '4', delta['GIT_CONFIG_COUNT']
      assert_equal 'core.fsmonitor', delta['GIT_CONFIG_KEY_2']
      assert_equal 'core.pager',     delta['GIT_CONFIG_KEY_3']
      refute delta.key?('GIT_CONFIG_KEY_0'), 'must not overwrite a host-set GIT_CONFIG_KEY_0'
    ensure
      saved.nil? ? ENV.delete('GIT_CONFIG_COUNT') : ENV['GIT_CONFIG_COUNT'] = saved
    end

    it 'subprocess_env carries the hardening keys alongside the bundler/identity deltas' do
      env = described_class.send(:subprocess_env, filesystem)

      assert env.key?('GIT_CONFIG_COUNT')
      assert_includes env.values, 'core.fsmonitor'
      assert_includes env.values, 'false'
      # The de-bundlerized base (Pikuri::BundlerEnv) is merged in too, or a
      # `bundle exec` in another project resolves against pikuri's Gemfile.
      assert_equal Pikuri::BundlerEnv.clean_delta.keys - env.keys, []
    end
  end

  describe '.run hardens git config-execution (regression)' do
    it 'overrides a hostile repo-local core.fsmonitor with false' do
      skip 'git not on PATH' unless system('command -v git >/dev/null 2>&1')

      # Make the project root a repo whose OWN config sets a code-exec
      # fsmonitor. Without env hardening, `git config core.fsmonitor`
      # echoes the hostile command; with it, the env override wins.
      git = ->(*args) { system('git', '-C', root.to_s, *args, out: File::NULL, err: File::NULL) }
      git.call('init', '-q')
      git.call('config', 'core.fsmonitor', 'echo HOSTILE_FSMONITOR_RAN')

      result = described_class.run(filesystem: filesystem, confirmer: confirmer,
                                   command: 'git config core.fsmonitor',
                                   description: nil, timeout: 30).to_s

      assert_includes result, 'false'
      refute_includes result, 'HOSTILE_FSMONITOR_RAN'
    end
  end

  describe '.run de-bundlerizes the subprocess (regression)' do
    it 'does not leak pikuri\'s BUNDLE_GEMFILE into the command' do
      # Under bundler BUNDLE_GEMFILE points at pikuri's own Gemfile; the
      # bash subprocess must not see it, or `bundle exec` in another
      # project breaks. Skip when not running under bundler.
      skip 'not running under bundler' unless ENV['BUNDLE_GEMFILE']

      result = described_class.run(filesystem: filesystem, confirmer: confirmer,
                                   command: 'echo "[${BUNDLE_GEMFILE:-unset}]"',
                                   description: nil, timeout: 30).to_s

      assert_includes result, '[unset]'
    end

    it 'preserves the host PATH so the command still finds its tools' do
      result = described_class.run(filesystem: filesystem, confirmer: confirmer,
                                   command: 'command -v echo >/dev/null && echo ok',
                                   description: nil, timeout: 30).to_s

      assert_includes result, 'ok'
    end
  end

  describe '.visible sanitization' do
    it 'preserves newlines (multi-line commands are normal)' do
      assert_equal "for x in 1 2 3; do\n  echo $x\ndone",
                   described_class.send(:visible, "for x in 1 2 3; do\n  echo $x\ndone")
    end

    it 'escapes carriage returns so the model cannot hide bytes via line overwrite' do
      assert_equal 'echo hi\\x0drm -rf /',
                   described_class.send(:visible, "echo hi\rrm -rf /")
    end

    it 'escapes ESC (the ANSI introducer)' do
      assert_equal 'echo \\x1b[2K',
                   described_class.send(:visible, "echo \e[2K")
    end

    it 'escapes NUL and DEL' do
      assert_equal 'a\\x00b\\x7fc',
                   described_class.send(:visible, "a\x00b\x7fc")
    end

    it 'leaves UTF-8 multibyte sequences alone' do
      assert_equal 'echo "héllo ✓"',
                   described_class.send(:visible, 'echo "héllo ✓"')
    end

    it 'the confirmation request carries the raw command — display escaping is the renderer\'s job' do
      cf = build_confirmer(false)

      described_class.run(filesystem: filesystem, confirmer: cf,
                          command: "echo hi\rrm -rf /", description: nil, timeout: 120)

      assert_equal "$ echo hi\rrm -rf /", cf.requests.first.detail
    end
  end

  describe '.truncate' do
    it 'is a no-op when output fits within head + tail' do
      output = 'x' * (described_class::OUTPUT_HEAD + described_class::OUTPUT_TAIL)
      assert_equal output, described_class.send(:truncate, output)
    end

    it 'keeps head and tail and reports omitted + total bytes in the marker' do
      head_bytes = described_class::OUTPUT_HEAD
      tail_bytes = described_class::OUTPUT_TAIL
      total      = head_bytes + tail_bytes + 5000
      output     = ('H' * head_bytes) + ('M' * 5000) + ('T' * tail_bytes)

      truncated = described_class.send(:truncate, output)

      assert truncated.start_with?('H' * head_bytes)
      assert truncated.end_with?('T' * tail_bytes)
      assert_includes truncated, "[5000 bytes omitted; total was #{total} bytes]"
      refute_includes truncated, 'M'
    end
  end

  describe '.run output truncation (integration)' do
    it 'truncates oversized output via .truncate' do
      # Generate output large enough to trigger truncation: 32 KB > 30 KB cap.
      # Use a quick `printf` repetition; combined head+tail is 30 KB so this
      # exercises the cap with a small margin.
      result = described_class.run(filesystem: filesystem, confirmer: confirmer,
                                   command: 'yes x | head -c 32768',
                                   description: nil, timeout: 30).to_s

      assert_includes result, 'bytes omitted'
      assert_includes result, 'exit status: 0'
    end
  end

  describe '.run workspace boundary' do
    it 'runs in the workspace project_root regardless of what the model passes in command' do
      # We don't path-resolve command args — bash itself interprets cd/etc.
      # But `chdir` for the spawn is fixed to workspace.project_root. Verify by
      # writing a file from inside the command via a relative path; it
      # should land under root.
      described_class.run(filesystem: filesystem, confirmer: confirmer,
                          command: "echo content > marker.txt",
                          description: nil, timeout: 30)

      assert (root + 'marker.txt').exist?
      assert_equal "content\n", (root + 'marker.txt').read
    end
  end

  describe 'tool integration (via #run)' do
    it 'validates args and produces a normal observation' do
      result = tool.run('command' => 'echo integ').to_s

      assert_includes result, '$ echo integ'
      assert_includes result, 'integ'
      assert_includes result, 'exit status: 0'
    end

    it 'accepts timeout as an integer' do
      result = tool.run('command' => 'echo ok', 'timeout' => 30).to_s

      assert_includes result, 'exit status: 0'
    end

    it 'accepts timeout as a numeric String (Parameters coerces)' do
      result = tool.run('command' => 'echo ok', 'timeout' => '30').to_s

      assert_includes result, 'exit status: 0'
    end

    it 'accepts an optional description and propagates it to the confirmer' do
      cf = build_confirmer(true)
      t  = described_class.new(filesystem: filesystem, confirmer: cf)

      t.run('command' => 'echo desc', 'description' => 'Echo a token')

      assert_includes cf.requests.first.question, 'Echo a token'
    end

    it 'reports a missing required command via the Parameters validator' do
      result = tool.run('description' => 'no command here').to_s

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'command'
    end

    it 'reports unknown parameters via the Parameters validator' do
      result = tool.run('command' => 'echo ok', 'shell' => 'zsh').to_s

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'shell'
    end
  end

  describe 'parameters schema' do
    it 'advertises command as required string, description optional string, timeout optional integer' do
      schema = tool.parameters.to_openai

      assert_equal %w[command], schema[:required]
      assert_equal 'string',  schema[:properties][:command][:type]
      assert_equal 'string',  schema[:properties][:description][:type]
      assert_equal 'integer', schema[:properties][:timeout][:type]
    end

    it 'wires through to_ruby_llm_tool under the "bash" name' do
      assert_equal 'bash', tool.to_ruby_llm_tool.name
    end
  end
end
