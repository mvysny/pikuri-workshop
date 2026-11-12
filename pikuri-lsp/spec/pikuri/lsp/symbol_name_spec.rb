# frozen_string_literal: true

describe Pikuri::Lsp::SymbolName do
  describe '.last_segment' do
    it 'takes the member half of every spelling a server uses' do
      assert_equal 'Read', described_class.last_segment('Pikuri::Workspace::Read')
      assert_equal 'resolve_for_read', described_class.last_segment('Read#resolve_for_read')
      assert_equal 'greet', described_class.last_segment('Greeter.greet')
      assert_equal 'greet', described_class.last_segment('greet(String)')
      assert_equal 'Inner', described_class.last_segment('Outer$Inner')
    end

    it 'answers empty for a nameless row rather than raising' do
      assert_equal '', described_class.last_segment(nil)
    end
  end

  describe '.matches?' do
    it 'accepts the qualified name a server reports for a bare query' do
      assert described_class.matches?('Pikuri::Tool', 'Tool')
      assert described_class.matches?('Pikuri::Workspace::Read', 'Pikuri::Workspace::Read')
    end

    it 'rejects a fuzzy near-match, which the server has already supplied plenty of' do
      refute described_class.matches?('resolve_for_write', 'resolve_for_read')
      refute described_class.matches?('@confirmer', 'Confirmer')
    end

    it 'rejects a nameless row' do
      refute described_class.matches?(nil, 'Read')
      refute described_class.matches?('', 'Read')
    end
  end
end
