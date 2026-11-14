# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

RSpec.describe Pikuri::Code::ProjectRoot do
  def with_home(path)
    original = ENV['HOME']
    ENV['HOME'] = path
    yield
  ensure
    ENV['HOME'] = original
  end

  describe '.find' do
    it 'finds the nearest ancestor with .git' do
      Dir.mktmpdir do |root|
        repo = File.join(root, 'repo')
        nested = File.join(repo, 'src', 'deep')
        FileUtils.mkdir_p(File.join(repo, '.git'))
        FileUtils.mkdir_p(nested)

        Dir.mktmpdir do |fake_home|
          with_home(fake_home) do
            assert_equal Pathname.new(repo).realpath, described_class.find(cwd: nested)
          end
        end
      end
    end

    it 'finds a .git regular file (worktree / submodule)' do
      Dir.mktmpdir do |root|
        repo = File.join(root, 'submodule')
        nested = File.join(repo, 'src')
        FileUtils.mkdir_p(nested)
        # Worktrees and submodules use a regular .git file, not a directory.
        File.write(File.join(repo, '.git'), "gitdir: /elsewhere\n")

        Dir.mktmpdir do |fake_home|
          with_home(fake_home) do
            assert_equal Pathname.new(repo).realpath, described_class.find(cwd: nested)
          end
        end
      end
    end

    it 'finds .hg and .svn too' do
      Dir.mktmpdir do |root|
        hg_repo = File.join(root, 'hg-repo', 'sub')
        svn_repo = File.join(root, 'svn-repo', 'sub')
        FileUtils.mkdir_p(File.join(root, 'hg-repo', '.hg'))
        FileUtils.mkdir_p(File.join(root, 'svn-repo', '.svn'))
        FileUtils.mkdir_p(hg_repo)
        FileUtils.mkdir_p(svn_repo)

        Dir.mktmpdir do |fake_home|
          with_home(fake_home) do
            assert_equal Pathname.new(File.join(root, 'hg-repo')).realpath,
                         described_class.find(cwd: hg_repo)
            assert_equal Pathname.new(File.join(root, 'svn-repo')).realpath,
                         described_class.find(cwd: svn_repo)
          end
        end
      end
    end

    it 'returns nil when no VCS marker is reachable within the safe-climb bounds' do
      Dir.mktmpdir do |fake_home|
        nested = File.join(fake_home, 'temp', 'subdir')
        FileUtils.mkdir_p(nested)

        with_home(fake_home) do
          assert_nil described_class.find(cwd: nested)
        end
      end
    end

    it 'stops at $HOME — does not find markers above HOME' do
      Dir.mktmpdir do |outer|
        FileUtils.mkdir_p(File.join(outer, '.git'))
        fake_home = File.join(outer, 'home', 'fakeuser')
        nested = File.join(fake_home, 'proj', 'src')
        FileUtils.mkdir_p(nested)

        with_home(fake_home) do
          assert_nil described_class.find(cwd: nested)
        end
      end
    end

    it 'stops before crossing into a DENIED_CLIMB_ROOTS directory' do
      skip 'no /var/tmp on this host' unless File.directory?('/var/tmp')

      Dir.mktmpdir(nil, '/var/tmp') do |scratch|
        Dir.mktmpdir do |fake_home|
          with_home(fake_home) do
            # No .git anywhere reachable; the walk must not cross into /var.
            assert_nil described_class.find(cwd: scratch)
          end
        end
      end
    end

    it 'still considers the starting cwd even when it is a banned directory' do
      skip 'no /tmp on this host' unless File.directory?('/tmp')

      # If user explicitly invokes from /tmp/<scratch> with a .git there,
      # the cwd itself is considered (we just don't climb above /tmp).
      Dir.mktmpdir(nil, '/tmp') do |scratch|
        FileUtils.mkdir_p(File.join(scratch, '.git'))
        Dir.mktmpdir do |fake_home|
          with_home(fake_home) do
            assert_equal Pathname.new(scratch).realpath, described_class.find(cwd: scratch)
          end
        end
      end
    end

    it 'returns the nearest VCS marker regardless of type (local priority)' do
      # .git at outer, .hg at inner subdir, cwd inside inner — the inner
      # .hg wins because it's the nearest project root from cwd. Markers
      # are checked together at each level rather than the whole chain
      # per marker.
      Dir.mktmpdir do |root|
        outer = File.join(root, 'outer')
        inner = File.join(outer, 'inner')
        deep = File.join(inner, 'deep')
        FileUtils.mkdir_p(File.join(outer, '.git'))
        FileUtils.mkdir_p(File.join(inner, '.hg'))
        FileUtils.mkdir_p(deep)

        Dir.mktmpdir do |fake_home|
          with_home(fake_home) do
            assert_equal Pathname.new(inner).realpath, described_class.find(cwd: deep)
          end
        end
      end
    end
  end
end
