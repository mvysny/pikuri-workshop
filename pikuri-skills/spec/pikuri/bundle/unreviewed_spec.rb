# frozen_string_literal: true

require 'tmpdir'
require 'open3'

RSpec.describe Pikuri::Bundle::Unreviewed do
  let(:dir) { Pathname.new(Dir.mktmpdir('unreviewed')).realpath }
  let(:skills) { dir + '.claude/skills' }

  after { FileUtils.rm_rf(dir) }

  def sh(*argv)
    output, status = Open3.capture2e(*argv, chdir: dir.to_s)
    raise "#{argv.join(' ')} failed: #{output}" unless status.success?
  end

  def write(rel, content)
    path = dir + rel
    path.dirname.mkpath
    path.write(content)
  end

  def commit_all
    sh('git', 'add', '-A')
    sh('git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q', '-m', 'c')
  end

  def unreviewed = described_class.files(repo: dir, roots: [skills.to_s])

  context 'in a git work tree' do
    before do
      sh('git', 'init', '-q')
      write('.claude/skills/cop/SKILL.md', "---\nname: cop\n---\nbody\n")
      commit_all
    end

    it 'vouches for a skill whose bytes match HEAD' do
      assert_equal [], unreviewed
    end

    it 'lists a skill changed since HEAD' do
      write('.claude/skills/cop/SKILL.md', "---\nname: cop\n---\nnew body\n")
      assert_equal ['.claude/skills/cop/SKILL.md'], unreviewed
    end

    it 'lists an untracked skill and its sidecar' do
      write('.claude/skills/helpful/SKILL.md', "---\nname: helpful\n---\n")
      write('.claude/skills/helpful/scripts/run.sh', "echo hi\n")
      assert_equal ['.claude/skills/helpful/SKILL.md', '.claude/skills/helpful/scripts/run.sh'], unreviewed
    end

    it 'lists a gitignored skill, which no commit can vouch for' do
      write('.gitignore', ".claude/skills/hidden/\n")
      commit_all
      write('.claude/skills/hidden/SKILL.md', "---\nname: hidden\n---\n")
      assert_equal ['.claude/skills/hidden/SKILL.md'], unreviewed
    end

    it 'lists a symlink even when it is committed' do
      File.symlink('/etc/hostname', skills + 'cop/ref.txt')
      commit_all
      assert_equal ['.claude/skills/cop/ref.txt'], unreviewed
    end

    it 'runs no clean filter the repository configures' do
      marker = dir + 'filter-ran'
      sh('git', 'config', 'filter.evil.clean', "touch #{marker}; cat")
      write('.gitattributes', "*.md filter=evil\n")
      write('.claude/skills/cop/SKILL.md', "---\nname: cop\n---\nchanged\n")
      unreviewed
      refute marker.exist?, 'a clean filter ran during the review'
    end
  end

  it 'lists every file when nothing is committed yet' do
    sh('git', 'init', '-q')
    write('.claude/skills/cop/SKILL.md', "x\n")
    assert_equal ['.claude/skills/cop/SKILL.md'], unreviewed
  end

  it 'answers nil outside a git work tree' do
    write('.claude/skills/cop/SKILL.md', "x\n")
    assert_nil unreviewed
  end
end
