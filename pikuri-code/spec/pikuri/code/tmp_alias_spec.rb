# frozen_string_literal: true

require 'tmpdir'

RSpec.describe Pikuri::Code::TmpAlias do
  let(:root)    { Pathname.new(Dir.mktmpdir('pikuri-alias-root-')).realpath }
  let(:scratch) { Pikuri::Paths.new_temp }
  let(:fs) do
    described_class.new(Pikuri::Workspace::Filesystem.new(project_root: root, writable: [scratch]), tmp: scratch)
  end

  after do
    FileUtils.remove_entry(root)
    FileUtils.remove_entry(scratch) if scratch.exist?
  end

  it 'rewrites /tmp/foo to <scratch>/foo for resolve_for_read' do
    File.write(scratch + 'foo.txt', 'x')
    assert_equal scratch + 'foo.txt', fs.resolve_for_read('/tmp/foo.txt')
  end

  it 'rewrites /tmp/foo to <scratch>/foo for resolve_for_write' do
    assert_equal scratch + 'sub/new.txt', fs.resolve_for_write('/tmp/sub/new.txt')
  end

  it 'rewrites exactly /tmp to the scratch folder' do
    assert_equal scratch, fs.resolve_for_read('/tmp')
  end

  it 'takes a Pathname as readily as a String' do
    assert_equal fs.resolve_for_read('/tmp/foo.txt'), fs.resolve_for_read(Pathname.new('/tmp/foo.txt'))
    assert_equal fs.resolve_for_read('sub/a.rb'), fs.resolve_for_read(Pathname.new('sub/a.rb'))
  end

  it 'does NOT rewrite /tmpfoo (only /tmp and /tmp/...)' do
    err = assert_raises(Pikuri::Workspace::Filesystem::Error) { fs.resolve_for_read('/tmpfoo') }
    assert_includes err.message, 'outside the workspace'
  end

  # The sandbox binds the scratch folder at /tmp first and the roots over it,
  # so inside bash /tmp/<root> is the real project. An LSP result is always
  # absolute, so rewriting it would send every in-root path to the scratch.
  it 'leaves a project that itself lives under /tmp alone' do
    File.write(root + 'here.rb', 'x')
    inside = (root + 'here.rb').to_s
    assert inside.start_with?('/tmp/'), 'fixture root must be under /tmp for this to mean anything'

    assert_equal root + 'here.rb', fs.resolve_for_read(inside)
    assert_equal scratch + 'foo.txt', fs.resolve_for_read('/tmp/foo.txt')
  end

  it 'answers everything else as the wrapped filesystem does' do
    assert_equal root, fs.project_root
    assert_includes fs.writable, scratch
    refute fs.private?
  end

  it 'refuses a scratch folder the filesystem cannot write' do
    err = assert_raises(ArgumentError) do
      described_class.new(Pikuri::Workspace::Filesystem.new(project_root: root), tmp: scratch)
    end
    assert_includes err.message, 'writable'
  end
end
