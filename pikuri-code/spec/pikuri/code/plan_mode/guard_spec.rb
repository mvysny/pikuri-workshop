# frozen_string_literal: true

require 'tmpdir'
require 'pikuri/testing'

RSpec.describe Pikuri::Code::PlanMode::Guard do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-guard-')).realpath }
  let(:plan_mode) { Pikuri::Code::PlanMode.new }
  let(:fs)        { plan_mode.guard(Pikuri::Workspace::Filesystem.new(project_root: root)) }

  after { FileUtils.remove_entry(root) }

  it 'resolves writes while plan mode is off' do
    assert_equal root + 'a.rb', fs.resolve_for_write('a.rb')
  end

  it 'refuses every write while plan mode is on, naming the way out' do
    plan_mode.activate!
    err = assert_raises(Pikuri::Workspace::Filesystem::Error) { fs.resolve_for_write('a.rb') }
    assert_includes err.message, 'a.rb'
    assert_includes err.message, 'exit_plan_mode'
  end

  it 'keeps reads open while plan mode is on' do
    plan_mode.activate!
    assert_equal root + 'a.rb', fs.resolve_for_read('a.rb')
  end

  # The refusal reaches the model only if write and edit turn the error into
  # their observation; this is the seam pikuri promises.
  it 'reaches the model through the real write and edit tools' do
    File.write(root + 'a.rb', "x = 1\n")
    c = Pikuri::Testing.configurator
    Pikuri::Workspace::Extension.new(filesystem: fs, confirmer: Pikuri::Workspace::Confirmer::AUTO_APPROVE).configure(c)
    write = c.tools.find { _1.name == 'write' }
    edit = c.tools.find { _1.name == 'edit' }
    plan_mode.activate!

    assert_includes write.run('path' => 'b.rb', 'content' => 'y').to_s, 'plan mode'
    assert_includes edit.run('path' => 'a.rb', 'old_string' => 'x', 'new_string' => 'z').to_s, 'plan mode'
    refute_predicate root + 'b.rb', :exist?
    assert_equal "x = 1\n", File.read(root + 'a.rb')
  end
end
