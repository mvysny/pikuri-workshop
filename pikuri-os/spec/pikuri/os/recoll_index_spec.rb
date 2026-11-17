# frozen_string_literal: true

require 'open3'
require 'tmpdir'

# Recoll.unavailable_reason against real recoll indexes built in a temp
# config dir; skipped on hosts without recoll, CI included.
RSpec.describe Pikuri::Os::Recoll, 'against a real index' do
  around do |example|
    next skip('no recollq / recollindex on this host') unless PrivateLocalSearch.on_path?('recollindex')

    Dir.mktmpdir do |confdir|
      @confdir = confdir
      original = ENV['RECOLL_CONFDIR']
      ENV['RECOLL_CONFDIR'] = confdir
      begin
        example.run
      ensure
        ENV['RECOLL_CONFDIR'] = original
      end
    end
  end

  # Index +files+ (relative path => text) under a fresh topdirs folder.
  def build_index(files)
    docs = File.join(@confdir, 'docs')
    Dir.mkdir(docs)
    files.each { |rel, text| File.write(File.join(docs, rel), text) }
    File.write(File.join(@confdir, 'recoll.conf'), "topdirs = #{docs}\n")
    _, status = Open3.capture2e('recollindex', '-c', @confdir)
    raise "recollindex failed in #{@confdir}" unless status.success?
  end

  it 'is ready once the index holds a document' do
    build_index('a.txt' => 'hello lease agreement')
    assert_nil described_class.unavailable_reason
  end

  it 'is not ready over an index of an empty folder' do
    build_index({})
    assert_includes described_class.unavailable_reason, "the index in #{@confdir} holds no documents"
  end

  it 'is not ready before recollindex ever ran' do
    assert_equal "no index in #{@confdir} yet. Build one with `recollindex`.", described_class.unavailable_reason
  end
end
