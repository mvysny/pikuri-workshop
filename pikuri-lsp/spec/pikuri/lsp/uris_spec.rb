# frozen_string_literal: true

describe Pikuri::Lsp::Uris do
  describe '.for_path' do
    it 'percent-encodes what would otherwise truncate the URI' do
      assert_equal 'file:///home/m/my%20repo/a%23b%3Fc.rb',
                   described_class.for_path('/home/m/my repo/a#b?c.rb')
    end

    it 'encodes non-ASCII and accepts a Pathname' do
      assert_equal 'file:///home/m/h%C3%A9llo.rb',
                   described_class.for_path(Pathname('/home/m/héllo.rb'))
    end

    it 'refuses a relative path, which a server would resolve against nothing' do
      assert_raises(ArgumentError) { described_class.for_path('lib/pikuri.rb') }
    end
  end

  describe '.to_path' do
    it 'round-trips a path with hostile characters' do
      path = '/home/m/my repo/a#b?c héllo.rb'

      assert_equal path, described_class.to_path(described_class.for_path(path))
    end

    it 'accepts an empty and a localhost authority' do
      assert_equal '/a/b.rb', described_class.to_path('file:///a/b.rb')
      assert_equal '/a/b.rb', described_class.to_path('file://localhost/a/b.rb')
    end

    it 'answers nil for anything pikuri cannot read as a local file' do
      assert_nil described_class.to_path('jdt://contents/rt.jar/java.lang/String.class?=x')
      assert_nil described_class.to_path('https://example.com/a.rb')
      assert_nil described_class.to_path('file://otherhost/share/a.rb')
      assert_nil described_class.to_path('untitled:Untitled-1')
    end

    it 'leaves a plus sign alone, unlike form decoding' do
      assert_equal '/a/b+c.rb', described_class.to_path('file:///a/b+c.rb')
    end
  end

  describe '.scheme' do
    it 'lowercases and tolerates the punctuation a scheme may contain' do
      assert_equal 'file', described_class.scheme('FILE:///a.rb')
      assert_equal 'jdt', described_class.scheme('jdt://contents/x')
      assert_equal 'vscode-notebook-cell', described_class.scheme('vscode-notebook-cell:/a')
    end

    it 'answers nil for a bare path' do
      assert_nil described_class.scheme('/home/m/a.rb')
    end
  end
end
