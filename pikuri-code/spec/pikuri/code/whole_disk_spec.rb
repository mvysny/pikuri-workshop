# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Code::WholeDisk do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-wholedisk-root-')).realpath }
  let(:outside)   { Pathname.new(Dir.mktmpdir('pikuri-wholedisk-outside-')).realpath }
  let(:fake_home) { Pathname.new(Dir.mktmpdir('pikuri-wholedisk-home-')).realpath }
  let(:filesystem) { described_class.new(project_root: root) }

  after do
    FileUtils.rm_rf(root)
    FileUtils.rm_rf(outside)
    FileUtils.rm_rf(fake_home)
  end

  describe 'resolution' do
    it 'reads and writes outside the project_root' do
      File.write(outside + 'data.txt', 'x')

      assert_equal outside + 'data.txt', filesystem.resolve_for_read((outside + 'data.txt').to_s)
      assert_equal outside + 'new.rb', filesystem.resolve_for_write((outside + 'new.rb').to_s)
    end

    it 'resolves a path whose intermediate folders do not exist' do
      assert_equal outside + 'a/b/c.rb', filesystem.resolve_for_write((outside + 'a/b/c.rb').to_s)
    end

    it 'resolves relative paths against the project_root' do
      assert_equal root + 'lib/foo.rb', filesystem.resolve_for_read('lib/foo.rb')
    end

    it 'follows a symlink out of the project_root' do
      File.write(outside + 'target', 'x')
      File.symlink(outside.to_s, (root + 'link').to_s)

      assert_equal outside + 'target', filesystem.resolve_for_read('link/target')
    end

    it 'lists / as writable, which is what Bubblewrap refuses' do
      assert_includes filesystem.writable, Pathname.new('/')
      assert_includes filesystem.readable, Pathname.new('/')
    end
  end

  describe 'project_root' do
    it 'accepts the roots a plain Filesystem refuses' do
      assert_raises(Pikuri::Workspace::Filesystem::Error) do
        Pikuri::Workspace::Filesystem.new(project_root: '/')
      end

      assert_equal Pathname.new('/'), described_class.new(project_root: '/').project_root
    end
  end

  describe 'trifecta flags' do
    it 'accepts private:, a whole disk being exactly where it is meant' do
      assert described_class.new(project_root: root, private: true).private?
    end

    it 'refuses trusted: outright' do
      error = assert_raises(ArgumentError) { described_class.new(project_root: root, trusted: true) }
      assert_includes error.message, 'not representable'
    end

    it 'reports untrusted when nothing was declared' do
      refute filesystem.trusted?
    end
  end

  describe 'credential denylist' do
    # Pointed at fake_home, so the fake credential folders never touch the
    # developer's real ones.
    let(:denylist) do
      %w[.ssh .aws .gnupg .docker .kube .netrc].map { |p| fake_home + p }.push(Pathname.new('/etc/shadow'))
    end
    let(:filesystem) { described_class.new(project_root: root, denylist: denylist) }

    def assert_denied(&block)
      err = assert_raises(Pikuri::Workspace::Filesystem::Error, &block)
      assert_includes err.message, 'denied credential location'
    end

    it 'refuses reads into a denied folder' do
      FileUtils.mkdir_p(fake_home + '.ssh')
      File.write(fake_home + '.ssh/id_rsa', 'secret')

      assert_denied { filesystem.resolve_for_read((fake_home + '.ssh/id_rsa').to_s) }
    end

    it 'refuses writes into a denied folder' do
      FileUtils.mkdir_p(fake_home + '.ssh')

      assert_denied { filesystem.resolve_for_write((fake_home + '.ssh/new_evil').to_s) }
    end

    it 'refuses writes that would create a denied folder not yet present' do
      # A keyring planted for a later GPG run to pick up: the literal-prefix
      # fallback catches it though .gnupg doesn't realpath.
      refute (fake_home + '.gnupg').exist?

      assert_denied { filesystem.resolve_for_write((fake_home + '.gnupg/keyring').to_s) }
    end

    it 'refuses a symlink whose target is denied' do
      FileUtils.mkdir_p(fake_home + '.ssh')
      File.write(fake_home + '.ssh/id_rsa', 'secret')
      File.symlink((fake_home + '.ssh/id_rsa').to_s, (root + 'decoy').to_s)

      assert_denied { filesystem.resolve_for_read('decoy') }
    end

    it 'refuses the real folder behind a symlinked denylist entry' do
      real_ssh = Pathname.new(Dir.mktmpdir('pikuri-real-ssh-')).realpath
      File.write(real_ssh + 'id_rsa', 'secret')
      File.symlink(real_ssh.to_s, (fake_home + '.ssh').to_s)

      assert_denied { filesystem.resolve_for_read((real_ssh + 'id_rsa').to_s) }
    ensure
      FileUtils.rm_rf(real_ssh) if real_ssh
    end

    it 'refuses a ~/ path the base class expands' do
      home_fs = described_class.new(project_root: root, denylist: [Pathname.new(Dir.home) + '.ssh'])

      assert_denied { home_fs.resolve_for_read('~/.ssh/id_rsa') }
    end

    it 'accepts a sibling whose name merely starts like a denied one' do
      FileUtils.mkdir_p(fake_home)
      File.write(fake_home + '.ssh-backup', 'x')

      assert_equal fake_home + '.ssh-backup', filesystem.resolve_for_read((fake_home + '.ssh-backup').to_s)
    end

    it 'opens credential paths for read and write when emptied' do
      open = described_class.new(project_root: root, denylist: [])
      FileUtils.mkdir_p(fake_home + '.ssh')

      assert_equal fake_home + '.ssh/id_rsa', open.resolve_for_read((fake_home + '.ssh/id_rsa').to_s)
      assert_equal fake_home + '.ssh/authorized_keys',
                   open.resolve_for_write((fake_home + '.ssh/authorized_keys').to_s)
      assert_empty open.denied_roots
    end
  end

  describe 'DEFAULT_CREDENTIAL_DENYLIST' do
    let(:paths) { described_class::DEFAULT_CREDENTIAL_DENYLIST.map(&:to_s) }

    it 'covers the per-home credential folders, for you and for root' do
      %w[.ssh .aws .gnupg .docker .kube .netrc].each do |name|
        assert_includes paths, File.join(Dir.home, name)
        assert_includes paths, File.join('/root', name)
      end
    end

    it 'covers /etc/shadow' do
      assert_includes paths, '/etc/shadow'
    end

    it 'is the default' do
      assert_equal described_class::DEFAULT_CREDENTIAL_DENYLIST, filesystem.denylist
    end
  end

  # pikuri's walking tools ask Filesystem#denied? of every path they find on
  # their own (pikuri:D_walked_path_denylist); pikuri pins that with a stub,
  # this pins it against the real override.
  describe 'what the tools walk to' do
    let(:root) { fake_home + 'proj' }
    let(:filesystem) do
      described_class.new(project_root: root, denylist: [fake_home + '.ssh', root + '.ssh'])
    end
    let(:workspace) { Pikuri::Workspace::Workspace.new(filesystem: filesystem) }

    before do
      FileUtils.mkdir_p(fake_home + '.ssh')
      File.write(fake_home + '.ssh/id_rsa', "-----BEGIN PRIVATE KEY-----\nsecret\n")
      FileUtils.mkdir_p(root + '.ssh')
      File.write(root + 'ok.txt', 'BEGIN PRIVATE KEY is mentioned here too')
      File.write(root + '.ssh/inner_key', "-----BEGIN PRIVATE KEY-----\ninner\n")
      File.symlink(fake_home + '.ssh', root + 'decoy_dir')
      File.symlink(fake_home + '.ssh/id_rsa', root + 'decoy_file')
    end

    def grep(workspace)
      Pikuri::Workspace::Search::Grep.search(
        workspace: workspace, pattern: 'BEGIN PRIVATE KEY', path: nil, glob: nil,
        case_insensitive: false, output_mode: 'content'
      ).to_s
    end

    it 'catches symlink decoys inside the workspace' do
      assert filesystem.denied?(root + 'decoy_dir')
      assert filesystem.denied?(root + 'decoy_file')
      refute filesystem.denied?(root + 'ok.txt')
    end

    it 'has read refuse a denied path' do
      result = Pikuri::Workspace::Read.read(workspace: workspace, path: '.ssh/inner_key',
                                            offset: 1, limit: 100).to_s

      assert_includes result, 'denied credential location'
      refute_includes result, 'BEGIN PRIVATE KEY'
    end

    it 'has file_list mark denied folders and decoys instead of entering them' do
      result = Pikuri::Workspace::FileList.list(workspace: workspace, path: nil, depth: 3).to_s

      assert_includes result, ".ssh/  #{Pikuri::Workspace::Listing::DENIED}"
      assert_includes result, "decoy_dir/  #{Pikuri::Workspace::Listing::DENIED}"
      assert_includes result, "decoy_file  #{Pikuri::Workspace::Listing::DENIED}"
      refute_includes result, 'inner_key'
      refute_includes result, 'id_rsa'
    end

    it 'has glob and grep leave denied paths out' do
      globbed = Pikuri::Workspace::Search::Glob.search(workspace: workspace, pattern: '**/*', path: nil).to_s
      grepped = grep(workspace)

      assert_includes globbed, 'ok.txt'
      assert_includes grepped, 'ok.txt'
      [globbed, grepped].each do |result|
        refute_includes result, 'inner_key'
        refute_includes result, 'secret'
      end
    end

    it 'lists and searches credential paths as ordinary ones under an empty denylist' do
      open = Pikuri::Workspace::Workspace.new(filesystem: described_class.new(project_root: root, denylist: []))
      listing = Pikuri::Workspace::FileList.list(workspace: open, path: nil, depth: 2).to_s

      assert_includes listing, 'inner_key'
      assert_includes grep(open), 'inner_key'
    end
  end
end
