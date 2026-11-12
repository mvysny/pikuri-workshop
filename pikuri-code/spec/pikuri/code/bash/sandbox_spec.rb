# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

# Probed once at file load. The `skip` idiom doesn't work cleanly with
# this project's Minitest-on-RSpec setup (Minitest::Skip bubbles as a
# failure), so we gate the bwrap-dependent describes at registration
# time instead of inside `it` blocks.
BWRAP_AVAILABLE = begin
  Pikuri::Subprocess.spawn('bwrap', '--version', chdir: '/').wait.status.success?
rescue Errno::ENOENT
  false
end

# overlayfs in a user namespace needs Linux >= 5.11. The sandbox now
# degrades to --ro-bind when it's unavailable, so the overlay-asserting
# tests gate on this rather than just BWRAP_AVAILABLE.
OVERLAY_AVAILABLE = BWRAP_AVAILABLE && begin
  Pikuri::Subprocess.spawn(
    'bwrap', '--unshare-all', '--share-net', '--ro-bind', '/', '/',
    '--overlay-src', '/usr', '--tmp-overlay', '/tmp', '--die-with-parent',
    '/bin/true', chdir: '/'
  ).wait.status.success?
rescue Errno::ENOENT
  false
end

RSpec.describe Pikuri::Code::Bash::Sandbox do
  describe described_class::NONE do
    it '#wrap returns argv unchanged' do
      argv = %w[timeout --signal=TERM 30s bash -c ls]
      assert_equal argv, described_class.wrap(argv)
    end

    it '#wrap returns the same array object (no copy)' do
      argv = ['bash', '-c', 'true']
      assert_same argv, described_class.wrap(argv)
    end

    it 'answers the posture predicates conservatively — the identity element hides nothing' do
      assert described_class.egress?
      refute described_class.confined_to_workspace?
    end
  end

  describe described_class::Bubblewrap do
    let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-sb-root-')).realpath }
    let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }

    after do
      FileUtils.rm_rf(root)
      Pikuri::Subprocess.cleanup!
    end

    unless BWRAP_AVAILABLE
      it 'raises a clear RuntimeError when bwrap is missing' do
        err = assert_raises(RuntimeError) { described_class.new(filesystem: filesystem) }
        assert_includes err.message, "'bwrap' not found"
        assert_includes err.message, '--no-sandbox'
      end
    end

    # Fires before the bwrap probe, so this test is bwrap-availability-
    # independent.
    it 'refuses construction when the workspace lists / as writable' do
      ws = Pikuri::Workspace::Filesystem::AllowAll.new(project_root: root)
      err = assert_raises(RuntimeError) { described_class.new(filesystem: ws) }
      assert_includes err.message, "lists '/' as"
      assert_includes err.message, 'Sandbox::NONE'
    end

    # Also fires before the bwrap probe — bwrap-availability-independent.
    it 'refuses construction when temp is set but alias_tmp_to_temp is off' do
      ws = Pikuri::Workspace::Filesystem.new(
        project_root: root, temp: true, alias_tmp_to_temp: false
      )
      begin
        err = assert_raises(RuntimeError) { described_class.new(filesystem: ws) }
        assert_includes err.message, 'temp set'
        assert_includes err.message, 'alias_tmp_to_temp'
      ensure
        FileUtils.remove_entry(ws.temp.to_s) if ws.temp&.exist?
      end
    end

    # Probe-scheduling and probe-failure tests: stub Subprocess.spawn
    # to give us deterministic exit codes regardless of whether the
    # host actually has bwrap (let alone a recent-enough kernel for
    # overlayfs in user namespaces). Each block restores the original
    # method on the way out.
    describe 'bwrap probe' do
      def stub_subprocess_spawn(call_log:, results:)
        original = Pikuri::Subprocess.method(:spawn)
        result_struct = Struct.new(:status) do
          def wait; self; end
        end
        status_struct = Struct.new(:success?, :exitstatus)
        results = results.dup

        Pikuri::Subprocess.define_singleton_method(:spawn) do |*args, **_kwargs|
          call_log << args
          ok, code = results.shift || [true, 0]
          result_struct.new(status_struct.new(ok, code))
        end
        original
      end

      def restore_subprocess_spawn(original)
        Pikuri::Subprocess.define_singleton_method(:spawn, original)
      end

      it 'does NOT run the overlay probe when there are no readable dirs to overlay' do
        # workspace is project_root-only — nothing in readable, so the
        # overlay probe would be wasted.
        calls = []
        original = stub_subprocess_spawn(call_log: calls, results: [[true, 0]])
        begin
          described_class.new(filesystem: filesystem)
        ensure
          restore_subprocess_spawn(original)
        end

        bwrap_calls = calls.select { |argv| argv.first == 'bwrap' }
        assert_equal 1, bwrap_calls.size,
                     "expected only the basic bwrap probe, got #{bwrap_calls.size}: " \
                     "#{bwrap_calls.inspect}"
        refute_includes bwrap_calls.first, '--tmp-overlay',
                        'basic probe should not include --tmp-overlay'
      end

      it 'DOES run the overlay probe when the workspace has readable dirs' do
        overlay_dir = Pathname.new(Dir.mktmpdir('pikuri-sb-probe-')).realpath
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [overlay_dir])

        calls = []
        original = stub_subprocess_spawn(call_log: calls, results: [[true, 0], [true, 0]])
        begin
          described_class.new(filesystem: ws)
        ensure
          restore_subprocess_spawn(original)
          FileUtils.rm_rf(overlay_dir)
        end

        bwrap_calls = calls.select { |argv| argv.first == 'bwrap' }
        assert_equal 2, bwrap_calls.size,
                     "expected basic probe + overlay probe, got #{bwrap_calls.size}: " \
                     "#{bwrap_calls.inspect}"
        assert_includes bwrap_calls.last, '--tmp-overlay',
                        "second probe should include --tmp-overlay; got #{bwrap_calls.last.inspect}"
      end

      it 'degrades to --ro-bind (no raise) when the overlay probe fails' do
        ro_dir = Pathname.new(Dir.mktmpdir('pikuri-sb-degrade-')).realpath
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [ro_dir])

        calls = []
        # Basic probe succeeds; overlay probe fails (old kernel).
        original = stub_subprocess_spawn(call_log: calls, results: [[true, 0], [false, 1]])
        begin
          # Construction must NOT raise — it degrades.
          sandbox = described_class.new(filesystem: ws)
          restore_subprocess_spawn(original)

          # wrap() does not spawn, so it's safe after restore. The
          # readable dir falls back to a plain --ro-bind, no overlay.
          argv = sandbox.wrap(['true'])
          assert argv.each_cons(2).any? { |a, b| a == '--ro-bind' && b == ro_dir.to_s },
                 "expected --ro-bind #{ro_dir} in the degraded argv: #{argv.inspect}"
          refute argv.each_cons(2).any? { |a, b| a == '--overlay-src' && b == ro_dir.to_s },
                 "did not expect an overlay for #{ro_dir} after the probe failed: #{argv.inspect}"
        ensure
          restore_subprocess_spawn(original)
          FileUtils.rm_rf(ro_dir)
        end
      end

      it 'does NOT run the overlay probe when the basic probe already failed' do
        # Give the workspace a readable dir so the overlay probe WOULD
        # run absent the basic-probe gate — then assert it doesn't.
        ro_dir = Pathname.new(Dir.mktmpdir('pikuri-sb-gate-')).realpath
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [ro_dir])

        calls = []
        # Basic probe fails; overlay probe must not be attempted.
        original = stub_subprocess_spawn(call_log: calls, results: [[false, 1]])
        begin
          assert_raises(RuntimeError) { described_class.new(filesystem: ws) }
        ensure
          restore_subprocess_spawn(original)
          FileUtils.rm_rf(ro_dir)
        end

        bwrap_calls = calls.select { |argv| argv.first == 'bwrap' }
        assert_equal 1, bwrap_calls.size,
                     'overlay probe must be gated on the basic probe succeeding'
      end
    end

    # Pre-bwrap-probe validation: the container-socket-exposure
    # check fires before check_bwrap! so these stay
    # availability-independent.
    describe 'container-socket exposure refusal' do
      # Surgically replace DENIED_CONTAINER_SOCKETS with one path
      # under a controllable tmpdir so we can build a workspace that
      # exposes it without touching real host paths.
      let(:fake_sock_root) { Pathname.new(Dir.mktmpdir('pikuri-sb-sockroot-')).realpath }
      let(:fake_sock) { fake_sock_root + 'docker.sock' }

      around do |example|
        FileUtils.touch(fake_sock.to_s)
        original = described_class::DENIED_CONTAINER_SOCKETS
        described_class.send(:remove_const, :DENIED_CONTAINER_SOCKETS)
        described_class.const_set(:DENIED_CONTAINER_SOCKETS, [fake_sock].freeze)
        begin
          example.run
        ensure
          described_class.send(:remove_const, :DENIED_CONTAINER_SOCKETS)
          described_class.const_set(:DENIED_CONTAINER_SOCKETS, original)
          FileUtils.rm_rf(fake_sock_root)
        end
      end

      it 'refuses construction when a workspace.readable root contains a denied socket' do
        # workspace.readable includes fake_sock_root → the bind would
        # carry fake_sock_root/docker.sock into the sandbox.
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [fake_sock_root])
        err = assert_raises(RuntimeError) { described_class.new(filesystem: ws) }
        assert_includes err.message, 'container/VM control sockets'
        assert_includes err.message, fake_sock.to_s
        assert_includes err.message, 'root escape'
      end

      it 'refuses construction when a workspace.writable root contains a denied socket' do
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, writable: [fake_sock_root])
        err = assert_raises(RuntimeError) { described_class.new(filesystem: ws) }
        assert_includes err.message, 'container/VM control sockets'
        assert_includes err.message, fake_sock.to_s
      end

      it 'refuses construction when the socket itself is bound as writable (direct match, not just ancestor)' do
        # Simulate someone mounting just the socket path. The
        # workspace constructor needs a real directory for project_root,
        # but readable/writable accept any existing path including a
        # regular file or socket. We point writable directly at the
        # socket file.
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, writable: [fake_sock])
        err = assert_raises(RuntimeError) { described_class.new(filesystem: ws) }
        assert_includes err.message, fake_sock.to_s
      end

      it 'accepts a sibling path that does not expose the denied socket' do
        sibling = Pathname.new(Dir.mktmpdir('pikuri-sb-sibling-')).realpath
        begin
          # Workspace bind sibling, which does NOT contain fake_sock.
          ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [sibling])
          # Need a bwrap probe to actually run; without bwrap we'd
          # surface a different RuntimeError. Skip-then-assert pattern:
          # in the absence of bwrap we just confirm the socket check
          # passes (i.e. the error is the bwrap-not-found one).
          err = begin
            described_class.new(filesystem: ws)
            nil
          rescue RuntimeError => e
            e
          end
          if err
            refute_includes err.message, 'container/VM control sockets',
                            'socket check must not fire for an unrelated workspace path'
          end
        ensure
          FileUtils.rm_rf(sibling)
        end
      end
    end

    if OVERLAY_AVAILABLE
      it '#wrap overlays workspace.readable dirs (--overlay-src/--overlay, not --ro-bind)' do
        overlay_dir = Pathname.new(Dir.mktmpdir('pikuri-sb-overlay-')).realpath
        ws = Pikuri::Workspace::Filesystem.new(project_root: root, readable: [overlay_dir])
        begin
          sandbox = described_class.new(filesystem: ws)
          argv = sandbox.wrap(['true'])

          # The overlay path appears as --overlay-src <lower> followed by
          # --overlay <upper> <work> <dest>; the dest equals the lower.
          src_idx = argv.each_cons(2).find_index { |a, b| a == '--overlay-src' && b == overlay_dir.to_s }
          assert src_idx, "expected --overlay-src #{overlay_dir} in #{argv.inspect}"

          # --overlay <upper> <work> <dest> starts somewhere after src_idx
          ov_idx = argv.each_with_index.find { |arg, i| arg == '--overlay' && i > src_idx }&.last
          assert ov_idx, "expected --overlay after --overlay-src in #{argv.inspect}"
          upper = argv[ov_idx + 1]
          work  = argv[ov_idx + 2]
          dest  = argv[ov_idx + 3]
          assert_equal overlay_dir.to_s, dest
          assert upper.end_with?('/upper'), "expected upper ending /upper, got #{upper}"
          assert work.end_with?('/work'),   "expected work ending /work, got #{work}"
          # Upper + work live under the workspace umbrella so they get
          # swept with the rest of internal_temp at process exit.
          assert upper.start_with?(ws.internal_temp.to_s),
                 "expected upper under #{ws.internal_temp}, got #{upper}"
          assert work.start_with?(ws.internal_temp.to_s),
                 "expected work under #{ws.internal_temp}, got #{work}"
          assert File.directory?(upper), "expected #{upper} to exist on disk"
          assert File.directory?(work),  "expected #{work} to exist on disk"

          # The path must NOT also appear as --ro-bind — that would be
          # the bug we're guarding against (double-mount / wrong semantics).
          refute argv.each_cons(2).any? { |a, b| a == '--ro-bind' && b == overlay_dir.to_s },
                 "did not expect --ro-bind #{overlay_dir} alongside the overlay: #{argv.inspect}"
        ensure
          FileUtils.rm_rf(overlay_dir)
          FileUtils.remove_entry(ws.internal_temp.to_s) if ws.internal_temp&.exist?
        end
      end
    end

    if BWRAP_AVAILABLE
      it 'keeps the network and contains the filesystem' do
        sandbox = described_class.new(filesystem: filesystem)
        assert sandbox.egress?, 'gem/bundle/mvn/pip need --share-net'
        assert sandbox.confined_to_workspace?, 'the constructor already refuses an unbounded workspace'
      end

      it 'constructs successfully when bwrap is available' do
        sandbox = described_class.new(filesystem: filesystem)
        assert_kind_of described_class, sandbox
      end

      it '#wrap composes the expected bwrap argv shape' do
        sandbox = described_class.new(filesystem: filesystem)
        argv = sandbox.wrap(['bash', '-c', 'echo hi'])

        assert_equal 'bwrap', argv.first
        # Workspace project_root is in writable; the bind for it should appear.
        assert argv.each_cons(2).any? { |a, b| a == '--bind' && b == root.to_s },
               "expected --bind #{root} in #{argv.inspect}"
        # Isolation flags
        assert_includes argv, '--unshare-all'
        assert_includes argv, '--share-net'
        assert_includes argv, '--die-with-parent'
        assert_includes argv, '--new-session'
        # Synthetic mounts — workspace has no temp, so /tmp falls back to tmpfs.
        assert argv.each_cons(2).any? { |a, b| a == '--tmpfs' && b == '/tmp' },
               "expected --tmpfs /tmp in #{argv.inspect}"
        # User argv preserved at the tail
        assert_equal 'bash', argv[-3]
        assert_equal '-c', argv[-2]
        assert_equal 'echo hi', argv[-1]
      end

      it '#wrap binds workspace.temp at /tmp when temp: true (NOT --tmpfs /tmp)' do
        ws = Pikuri::Workspace::Filesystem.new(
          project_root: root, temp: true, alias_tmp_to_temp: true
        )
        begin
          sandbox = described_class.new(filesystem: ws)
          argv = sandbox.wrap(['true'])

          # /tmp is bound to the workspace temp (persistent across bash calls).
          assert argv.each_cons(3).any? { |a, b, c| a == '--bind' && b == ws.temp.to_s && c == '/tmp' },
                 "expected --bind #{ws.temp} /tmp in #{argv.inspect}"
          # The fallback tmpfs at /tmp is gone.
          refute argv.each_cons(2).any? { |a, b| a == '--tmpfs' && b == '/tmp' },
                 "did not expect --tmpfs /tmp when temp is set: #{argv.inspect}"
          # The temp host path is ALSO bound at its host path so file tools
          # and bash agree on a single canonical path.
          assert argv.each_cons(3).any? { |a, b, c| a == '--bind' && b == ws.temp.to_s && c == ws.temp.to_s },
                 "expected --bind #{ws.temp} #{ws.temp} in #{argv.inspect}"
        ensure
          FileUtils.remove_entry(ws.temp.to_s) if ws.temp.exist?
        end
      end

      it '#wrap exposes the OS-runtime baseline (/etc/ssl, etc.) when present' do
        sandbox = described_class.new(filesystem: filesystem)
        argv = sandbox.wrap(['true'])

        described_class::ETC_BASELINE.each do |p|
          next unless File.exist?(p)
          assert argv.each_cons(2).any? { |a, b| a == '--ro-bind' && b == p },
                 "expected --ro-bind #{p} in #{argv.inspect}"
        end
      end

      it 'end-to-end: bwrap-wrapped echo runs inside the sandbox' do
        sandbox = described_class.new(filesystem: filesystem)
        argv = sandbox.wrap(['bash', '-c', 'echo sandboxed'])
        result = Pikuri::Subprocess.spawn(*argv, chdir: root.to_s).wait

        assert result.status.success?, "spawn failed: #{result.output}"
        assert_includes result.output, 'sandboxed'
      end

      it 'end-to-end: the sandbox cannot see paths outside the workspace' do
        outside = Pathname.new(Dir.mktmpdir('pikuri-sb-outside-')).realpath
        begin
          File.write(outside + 'secret.txt', 'PEEKABOO')

          sandbox = described_class.new(filesystem: filesystem)
          argv = sandbox.wrap(['bash', '-c', "cat #{outside}/secret.txt 2>&1 || echo blocked"])
          result = Pikuri::Subprocess.spawn(*argv, chdir: root.to_s).wait

          refute_includes result.output, 'PEEKABOO',
                          'sandbox leaked an outside-the-workspace file: ' \
                          "#{result.output.inspect}"
        ensure
          FileUtils.rm_rf(outside)
        end
      end
    end
  end

  describe described_class::FullFsNoNet do
    let(:root)       { Pathname.new(Dir.mktmpdir('pikuri-ffnn-root-')).realpath }
    let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }

    after do
      FileUtils.rm_rf(root)
      Pikuri::Subprocess.cleanup!
    end

    # Stub Subprocess.spawn so the construction probe is deterministic
    # regardless of whether the host allows unprivileged net namespaces.
    def stub_subprocess_spawn(call_log:, results:)
      original = Pikuri::Subprocess.method(:spawn)
      result_struct = Struct.new(:status) do
        def wait; self; end
      end
      status_struct = Struct.new(:success?, :exitstatus)
      results = results.dup
      Pikuri::Subprocess.define_singleton_method(:spawn) do |*args, **_kwargs|
        call_log << args
        ok, code = results.shift || [true, 0]
        result_struct.new(status_struct.new(ok, code))
      end
      original
    end

    def restore_subprocess_spawn(original)
      Pikuri::Subprocess.define_singleton_method(:spawn, original)
    end

    # Construct past the probe (stubbed to succeed) and return the
    # sandbox; #wrap does not spawn, so it's safe to call after restore.
    def build_with_stubbed_probe(fs)
      original = stub_subprocess_spawn(call_log: [], results: [[true, 0]])
      described_class.new(filesystem: fs)
    ensure
      restore_subprocess_spawn(original)
    end

    unless BWRAP_AVAILABLE
      it 'raises a clear RuntimeError when bwrap is missing' do
        err = assert_raises(RuntimeError) { described_class.new(filesystem: filesystem) }
        assert_includes err.message, "'bwrap' not found"
        assert_includes err.message, 'no fallback'
      end
    end

    describe 'bwrap probe' do
      it 'probes with --unshare-net (not --share-net) and binds the whole root' do
        calls = []
        original = stub_subprocess_spawn(call_log: calls, results: [[true, 0]])
        begin
          described_class.new(filesystem: filesystem)
        ensure
          restore_subprocess_spawn(original)
        end

        probe = calls.find { |argv| argv.first == 'bwrap' }
        assert probe, 'expected a bwrap probe'
        assert_includes probe, '--unshare-net'
        refute_includes probe, '--share-net'
        # Flag-for-flag with #wrap: a host that refuses a mask must fail at boot.
        masks = described_class::SESSION_IPC_MASKS
        unless masks.empty?
          assert probe.each_cons(masks.size).any? { |w| w == masks },
                 "masks missing from the probe: #{probe.inspect}"
        end
        # --dev-bind, matching #wrap flag-for-flag: a probe of a mount shape
        # the real argv doesn't use proves nothing.
        assert probe.each_cons(3).any? { |a, b, c| a == '--dev-bind' && b == '/' && c == '/' },
               "expected --dev-bind / / in the probe: #{probe.inspect}"
        refute_includes probe, '--bind'
      end

      it 'raises (no networked fallback) when the netns probe fails' do
        calls = []
        original = stub_subprocess_spawn(call_log: calls, results: [[false, 1]])
        begin
          err = assert_raises(RuntimeError) { described_class.new(filesystem: filesystem) }
          assert_includes err.message, 'probe failed'
          assert_includes err.message, 'does NOT fall back'
        ensure
          restore_subprocess_spawn(original)
        end
      end
    end

    describe '#wrap argv shape' do
      it 'binds the whole root and severs only the network' do
        argv = build_with_stubbed_probe(filesystem).wrap(['bash', '-c', 'echo hi'])

        assert_equal 'bwrap', argv.first
        assert argv.each_cons(3).any? { |a, b, c| a == '--dev-bind' && b == '/' && c == '/' },
               "expected --dev-bind / / in #{argv.inspect}"
        assert_includes argv, '--unshare-net'
        # The inverse of Bubblewrap: no shared-net, and PID/IPC/UTS stay
        # shared so the agent can see host processes/services.
        refute_includes argv, '--share-net'
        refute_includes argv, '--unshare-all'
        refute_includes argv, '--unshare-pid'
        assert_includes argv, '--die-with-parent'
        assert_includes argv, '--new-session'
        assert argv.each_cons(2).any? { |a, b| a == '--proc' && b == '/proc' },
               "expected --proc /proc in #{argv.inspect}"
        # The real device tree, NOT bwrap's synthetic --dev: a synthetic /dev
        # omits block-device nodes, turning smartctl's honest EACCES into a
        # confusing ENOENT while lsblk/sysfs still show the disk. Guard against
        # a "cleanup" reintroducing --dev.
        assert argv.each_cons(3).any? { |a, b, c| a == '--dev-bind' && b == '/dev' && c == '/dev' },
               "expected --dev-bind /dev /dev in #{argv.inspect}"
        refute_includes argv, '--dev'
        # And never plain --bind: it applies MS_NODEV, which leaves every node
        # visible to ls/stat but unopenable — `echo x > /dev/null` refused
        # EACCES on a crw-rw-rw- file. A lying environment, worse than a
        # missing one; see pikuri-code/design/architecture.md.
        refute_includes argv, '--bind'
        assert argv.each_cons(2).any? { |a, b| a == '--chdir' && b == root.to_s },
               "expected --chdir #{root} in #{argv.inspect}"
        # User argv preserved at the tail.
        assert_equal %w[bash -c], argv[-3..-2]
        assert_equal 'echo hi', argv[-1]
      end

      it 'masks the live session IPC surface, after the full-root bind' do
        masks = described_class::SESSION_IPC_MASKS
        skip 'host has no session runtime dir and no X11 socket dir' if masks.empty?

        argv = build_with_stubbed_probe(filesystem).wrap(['bash', '-c', 'echo hi'])

        assert argv.each_cons(masks.size).any? { |window| window == masks },
               "expected #{masks.inspect} spliced into #{argv.inspect}"
        # Order is load-bearing and silent under every other test: a mask placed
        # *before* --dev-bind / / would be covered by that bind, handing the
        # session bus — hence egress — straight back.
        assert argv.index(masks.first) > argv.index('--dev-bind'),
               "masks must follow the full-root bind: #{argv.inspect}"
      end

      it 'masks only directories that exist (bwrap cannot mkdir under /run/user)' do
        masks = described_class::SESSION_IPC_MASKS

        masks.each_cons(2) do |flag, path|
          next unless flag == '--tmpfs'

          assert File.directory?(path), "masked a nonexistent dir: #{path}"
        end
        runtime = ENV['XDG_RUNTIME_DIR'] || "/run/user/#{Process.uid}"
        if File.directory?(runtime)
          assert masks.each_cons(2).any? { |a, b| a == '--tmpfs' && b == runtime },
                 "expected the session runtime dir masked: #{masks.inspect}"
        end
      end

      it 'does NOT reject a Filesystem::AllowAll workspace (unlike Bubblewrap)' do
        ws = Pikuri::Workspace::Filesystem::AllowAll.new(project_root: root)
        sandbox = build_with_stubbed_probe(ws)
        assert_kind_of described_class, sandbox
        argv = sandbox.wrap(['true'])
        assert argv.each_cons(3).any? { |a, b, c| a == '--dev-bind' && b == '/' && c == '/' }
      end
    end

    if BWRAP_AVAILABLE
      it 'severs the network and admits the whole filesystem — Bubblewrap inverted' do
        sandbox = described_class.new(filesystem: filesystem)
        refute sandbox.egress?, '--unshare-net plus the session-IPC masks'
        refute sandbox.confined_to_workspace?, '--dev-bind / / is the whole real root'
      end

      it 'constructs when bwrap + unprivileged netns are available' do
        # Also requires unprivileged user+net namespaces; if the host has
        # bwrap but disables those, this (correctly) raises.
        sandbox = described_class.new(filesystem: filesystem)
        assert_kind_of described_class, sandbox
      end

      it 'end-to-end: a command runs and sees the real filesystem' do
        File.write(root + 'marker.txt', 'REALFS')
        sandbox = described_class.new(filesystem: filesystem)
        argv = sandbox.wrap(['bash', '-c', "cat #{root}/marker.txt"])
        result = Pikuri::Subprocess.spawn(*argv, chdir: '/').wait

        assert result.status.success?, "spawn failed: #{result.output}"
        assert_includes result.output, 'REALFS'
      end

      it 'end-to-end: the session bus is unreachable (egress cannot be delegated out)' do
        bus = ENV['DBUS_SESSION_BUS_ADDRESS']&.slice(/unix:path=([^,;]+)/, 1)
        skip 'no session bus on this host' unless bus && File.exist?(bus)

        # Guards the mount, not the argv: reaching this socket lets the sandboxed
        # command have systemd --user spawn a networked process outside every
        # namespace, so --unshare-net alone proves nothing.
        sandbox = described_class.new(filesystem: filesystem)
        argv = sandbox.wrap(['bash', '-c', "test -S #{bus} && echo REACHABLE || echo MASKED"])
        result = Pikuri::Subprocess.spawn(*argv, chdir: '/').wait

        assert result.status.success?, "spawn failed: #{result.output}"
        assert_includes result.output, 'MASKED'
      end

      it 'end-to-end: the pseudo-devices an ordinary user may open are openable' do
        # Guards the flag, not the argv: plain --bind adds MS_NODEV, and only
        # executing the argv catches that — the assertions above pass either way.
        sandbox = described_class.new(filesystem: filesystem)
        argv = sandbox.wrap(['bash', '-c',
                             'echo x > /dev/null && head -c1 /dev/zero > /dev/null && ' \
                             'head -c1 /dev/urandom > /dev/null && echo DEVOK'])
        result = Pikuri::Subprocess.spawn(*argv, chdir: '/').wait

        assert result.status.success?, "device nodes unopenable: #{result.output}"
        assert_includes result.output, 'DEVOK'
      end

      it 'end-to-end: a root-owned device stays EACCES (--dev-bind grants no authority)' do
        # --dev-bind restores device *access*, not authority: a root:disk node
        # stays as unopenable inside as out, which is what keeps smartctl's
        # escalation hand-off honest.
        node = Dir.glob('/dev/loop*').find { |p| File.blockdev?(p) && !File.readable?(p) }
        skip 'no unreadable block device to probe on this host' unless node

        sandbox = described_class.new(filesystem: filesystem)
        argv = sandbox.wrap(['bash', '-c', "head -c1 #{node} 2>&1"])
        result = Pikuri::Subprocess.spawn(*argv, chdir: '/').wait

        refute result.status.success?, "expected #{node} to stay unopenable: #{result.output}"
        assert_match(/permission denied/i, result.output,
                     "expected an honest EACCES, got: #{result.output.inspect}")
      end

      it 'end-to-end: the network is severed (fresh netns has only loopback)' do
        sandbox = described_class.new(filesystem: filesystem)
        # A fresh network namespace has exactly one interface (lo). With a
        # fresh --proc (net-namespaced), /proc/net/dev lists interfaces
        # after two header lines, so a count of 1 proves the process is in
        # an isolated netns — the host has more.
        argv = sandbox.wrap(['bash', '-c', 'tail -n +3 /proc/net/dev | wc -l'])
        result = Pikuri::Subprocess.spawn(*argv, chdir: '/').wait

        assert result.status.success?, "spawn failed: #{result.output}"
        assert_equal '1', result.output.strip,
                     "expected only loopback in the sandbox netns: #{result.output.inspect}"
      end
    end
  end
end
