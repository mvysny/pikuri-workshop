# frozen_string_literal: true

# The LocalSearch backend against a real localsearch indexer on a private
# bus (see PrivateLocalSearch); skipped on hosts without one, CI included.
RSpec.describe Pikuri::Os::LocalSearch, 'against a private index' do
  # Odd folder names pin LocalSearch.file_uri to GLib's escaping: a mismatch
  # makes a folder filter or a read silently find nothing.
  ODD = "üml #;x'(1)"

  before(:all) do
    next unless PrivateLocalSearch.usable?

    @index = PrivateLocalSearch.new(
      'alpha/a.txt' => "The quick zebra jumps over the lazy dog near Prague.\nSecond line.\n",
      'beta/b.md' => 'A zebra, a mouse, and "quoted, commas" here.',
      'beta2/e.txt' => 'A zebra in the sibling folder whose name extends beta.',
      "#{ODD}/d.txt" => "A zebra in an oddly named folder.\nIts second line.\n",
      'rank/many.txt' => 'otter otter otter otter otter',
      'rank/one.txt' => "One otter among #{'many other plain words ' * 40}."
    ).start
  end

  after(:all) { @index&.stop }

  before { skip 'no localsearch-3 / dbus-daemon / tinysparql on this host' unless @index }

  def search(query, folder: nil, limit: 25)
    described_class.search(query: query, limit: limit, folder: folder)
  end

  def relative(hits) = hits.map { |hit| hit[:path].delete_prefix("#{@index.corpus}/") }.sort

  it 'finds a word across the whole index, snippets intact' do
    hits = search('zebra')
    assert_equal ['alpha/a.txt', 'beta/b.md', 'beta2/e.txt', "#{ODD}/d.txt"], relative(hits)
    b = hits.find { |hit| hit[:path].end_with?('/b.md') }
    assert_equal 'A >>zebra<<, a mouse, and "quoted, commas" here.', b[:snippet]
  end

  it 'limits a search to one folder, by whole path components' do
    assert_equal ['beta/b.md'], relative(search('zebra', folder: "#{@index.corpus}/beta"))
  end

  it 'limits a search to a folder whose name needs escaping' do
    assert_equal ["#{ODD}/d.txt"], relative(search('zebra', folder: "#{@index.corpus}/#{ODD}"))
  end

  it 'ranks the better match first, before the limit applies' do
    hits = search('otter', limit: 1)
    assert_equal ['rank/many.txt'], relative(hits)
  end

  it 'cuts a long text to a snippet of SNIPPET_WORDS words around the match' do
    one = search('otter').find { |hit| hit[:path].end_with?('/one.txt') }
    assert one[:snippet].start_with?('One >>otter<< among many'), one[:snippet]
    assert one[:snippet].end_with?('…'), one[:snippet]
    assert_equal described_class::SNIPPET_WORDS, one[:snippet].delete_suffix('…').split.size
  end

  it 'matches word stems' do
    assert_equal ['alpha/a.txt'], relative(search('jumping'))
  end

  it 'reads the full stored text, newlines included, of an oddly named file' do
    assert_equal "A zebra in an oddly named folder.\nIts second line.\n",
                 described_class.read_text("#{@index.corpus}/#{ODD}/d.txt")
  end

  it 'reads nil for a path the index does not hold' do
    assert_nil described_class.read_text("#{@index.corpus}/nope.txt")
  end

  it 'serves the fileindex_search tool end to end' do
    out = Pikuri::Os::FileindexSearch.search(query: 'zebra', folder: "#{@index.corpus}/alpha",
                                             backend: described_class).to_s
    assert_includes out, "#{@index.corpus}/alpha/a.txt\n  The quick >>zebra<< jumps"
    assert_includes out, 'Found 1 file'
  end
end
