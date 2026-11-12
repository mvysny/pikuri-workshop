# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

RSpec.describe Pikuri::Command::Extension do
  def registry_over(trusted:, &)
    Dir.mktmpdir('pikuri-commands') do |root|
      FileUtils.mkdir_p(File.join(root, '.claude/commands'))
      File.write(File.join(root, '.claude/commands/wh.md'), 'Body.')
      yield described_class.new(
        registry: Pikuri::Command::Registry.new(
          search_bases: [Pikuri::Bundle::Base.new(dir: root, trusted: trusted)]
        )
      )
    end
  end

  it 'declares the untrusted leg under its own report row' do
    registry_over(trusted: false) do |extension|
      contribution = extension.trifecta_contribution([])

      assert_equal '(commands)', contribution.label
      assert_equal :hard, contribution.legs.untrusted
      refute contribution.legs.private
      refute contribution.legs.egress?
      assert_equal [], contribution.children
    end
  end

  it 'contributes nothing when the host vouched for every source' do
    registry_over(trusted: true) do |extension|
      assert_nil extension.trifecta_contribution([])
    end
  end

  it 'adds no row to the report it is not wired into' do
    Dir.mktmpdir('pikuri-commands') do |root|
      extension = described_class.new(registry: Pikuri::Command::Registry.new(search_bases: [root]))

      assert_nil extension.trifecta_contribution([])
    end
  end
end
