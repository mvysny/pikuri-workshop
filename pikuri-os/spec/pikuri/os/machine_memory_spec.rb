# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Os::MachineMemory do
  describe '.default_path' do
    around do |example|
      original = ENV['XDG_CONFIG_HOME']
      example.run
    ensure
      ENV['XDG_CONFIG_HOME'] = original
    end

    it 'uses $XDG_CONFIG_HOME when set' do
      ENV['XDG_CONFIG_HOME'] = '/custom/cfg'
      assert_equal '/custom/cfg/pikuri/MACHINE.md', described_class.default_path
    end

    it 'falls back to ~/.config when XDG_CONFIG_HOME is unset' do
      ENV['XDG_CONFIG_HOME'] = nil
      assert_equal File.join(Dir.home, '.config', 'pikuri', 'MACHINE.md'), described_class.default_path
    end
  end

  describe 'reading content' do
    let(:dir)  { Pathname.new(Dir.mktmpdir('pikuri-mm-')) }
    let(:path) { dir + 'MACHINE.md' }

    after { FileUtils.rm_rf(dir) }

    it 'returns empty string when the file is absent' do
      assert_equal '', described_class.new(path: path).content
    end

    it 'returns the file content when present' do
      path.write("Music lives in ~/Music.\nDocs synced via Syncthing.")
      assert_equal "Music lives in ~/Music.\nDocs synced via Syncthing.",
                   described_class.new(path: path).content
    end

    it 'flags oversized content' do
      path.write('x' * (described_class::OVERSIZE_BYTES + 1))
      assert described_class.new(path: path).oversized?
    end

    it 'does not flag small content' do
      path.write('a tiny note')
      refute described_class.new(path: path).oversized?
    end

    it 'reads fresh on each call, so an edit surfaces without a new instance' do
      path.write('first note')
      mem = described_class.new(path: path)
      assert_equal 'first note', mem.content

      # Same instance, file edited mid-session (the /clear re-pull case).
      path.write('edited note')
      assert_equal 'edited note', mem.content
    end
  end

  describe '#prompt_section' do
    let(:dir)  { Pathname.new(Dir.mktmpdir('pikuri-mm-')) }
    let(:path) { dir + 'MACHINE.md' }

    after { FileUtils.rm_rf(dir) }

    it 'is nil when there is nothing recorded' do
      assert_nil described_class.new(path: path).prompt_section
    end

    it 'is nil when the file is whitespace only' do
      path.write("\n  \n")
      assert_nil described_class.new(path: path).prompt_section
    end

    it 'renders a labeled block naming the path and carrying the notes' do
      path.write('Work folder is ~/work.')
      section = described_class.new(path: path).prompt_section
      assert_includes section, '# Notes about this machine'
      assert_includes section, path.to_s
      assert_includes section, 'Work folder is ~/work.'
    end
  end
end
