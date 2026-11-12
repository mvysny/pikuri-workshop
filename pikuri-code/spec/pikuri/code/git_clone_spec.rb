# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Code::GitClone do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-git-clone-root-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  # Override the lazy Bubblewrap sandbox with the identity passthrough,
  # so the kernel-namespace probe doesn't bite this spec.
  let(:tool)      { described_class.new(filesystem: filesystem, sandbox: Pikuri::Code::Bash::Sandbox::NONE) }

  after { FileUtils.rm_rf(root) }

  describe 'URL validation' do
    it 'rejects ssh:// URLs (history of arg-injection RCE — see class header)' do
      result = tool.run('url' => 'ssh://git@example.com/repo.git').to_s
      assert_match(/Error: only https \/ http URLs are accepted/, result)
    end

    it 'rejects git:// URLs (insecure, no auth)' do
      result = tool.run('url' => 'git://example.com/repo.git').to_s
      assert_match(/Error: only https \/ http URLs are accepted/, result)
    end

    it 'rejects file:// URLs (symlink-based local file reads — see CVE-2022-39253)' do
      result = tool.run('url' => 'file:///tmp/repo').to_s
      assert_match(/Error: only https \/ http URLs are accepted/, result)
    end

    it 'rejects URLs with no host' do
      result = tool.run('url' => 'https://').to_s
      assert_match(/Error: URL must include a host/, result)
    end

    it 'reports malformed URLs as Error: rather than raising' do
      result = tool.run('url' => 'not a url').to_s
      assert_match(/Error:/, result)
    end
  end

  describe 'subprocess invocation' do
    # Capture the argv that would be spawned, without actually shelling out.
    def stub_subprocess(spawn_result_status:, output: '')
      received_argv = nil
      original_spawn = Pikuri::Subprocess.method(:spawn)
      Pikuri::Subprocess.define_singleton_method(:spawn) do |*argv, chdir:|
        received_argv = argv
        # Build a fake Subprocess handle whose #wait returns a Result.
        Object.new.tap do |fake|
          fake.define_singleton_method(:wait) do
            status_struct = Struct.new(:exitstatus, :success?).new(spawn_result_status, spawn_result_status.zero?)
            Pikuri::Subprocess::Result.new(output: output, status: status_struct)
          end
        end
      end
      yield received_argv_proc = -> { received_argv }
    ensure
      Pikuri::Subprocess.define_singleton_method(:spawn, &original_spawn) if original_spawn
    end

    it 'spawns git clone --depth 1 --no-recurse-submodules --quiet -- URL TARGET in the workspace' do
      stub_subprocess(spawn_result_status: 0) do |received_argv|
        result = tool.run('url' => 'https://github.com/example/sample-repo.git').to_s

        argv = received_argv.call
        refute_nil argv
        # Sandbox::NONE is identity wrap, so argv starts with timeout + git clone
        assert_equal 'timeout', argv[0]
        clone_idx = argv.index('clone')
        refute_nil clone_idx
        assert_includes argv[clone_idx..], '--depth'
        assert_includes argv[clone_idx..], '1'
        assert_includes argv[clone_idx..], '--no-recurse-submodules'
        assert_includes argv[clone_idx..], '--'
        assert_includes argv[clone_idx..], 'https://github.com/example/sample-repo.git'
        # Target derived from URL basename, sans .git
        assert_includes argv, 'sample-repo'
        assert_match(/Cloned .* sample-repo\//, result)
      end
    end

    it 'falls back to "repo" when the URL has no usable basename' do
      stub_subprocess(spawn_result_status: 0) do |received_argv|
        tool.run('url' => 'https://github.com/')

        argv = received_argv.call
        assert_includes argv, 'repo'
      end
    end

    it 'reports exit code 124 / 137 / 125 as a timeout error' do
      stub_subprocess(spawn_result_status: 124, output: 'fatal: too slow\n') do |_|
        result = tool.run('url' => 'https://github.com/example/repo').to_s
        assert_match(/Error: git clone timed out/, result)
      end
    end

    it 'reports a non-timeout non-zero exit as a clone failure' do
      stub_subprocess(spawn_result_status: 128, output: 'fatal: repository not found\n') do |_|
        result = tool.run('url' => 'https://github.com/example/nope').to_s
        assert_match(/Error: git clone failed \(exit 128\)/, result)
      end
    end

    it 'refuses to clone over an existing target directory' do
      (root + 'existing').mkdir
      result = tool.run('url' => 'https://github.com/example/existing.git').to_s
      assert_match(/Error: target directory "existing" already exists/, result)
    end
  end

  describe '#with_workspace' do
    # SubAgentTool hands the protocol the session Workspace composite;
    # GitClone reads .filesystem off it so its lazy Bubblewrap (which
    # needs readable/writable/temp) gets the bare Filesystem, not the
    # composite (which would blow up on the missing .writable).
    it 'binds a new instance to the composite workspace\'s Filesystem' do
      other_root = Pathname.new(Dir.mktmpdir('pikuri-git-clone-other-')).realpath
      begin
        other_fs = Pikuri::Workspace::Filesystem.new(project_root: other_root)
        other_ws = Pikuri::Workspace::Workspace.new(filesystem: other_fs)
        forked = tool.with_workspace(other_ws)

        assert_kind_of described_class, forked
        refute_equal tool.object_id, forked.object_id
        bound = forked.instance_variable_get(:@filesystem)
        assert_same other_fs, bound
        assert_equal other_root, bound.project_root
      ensure
        FileUtils.rm_rf(other_root)
      end
    end
  end
end
