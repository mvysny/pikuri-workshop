# frozen_string_literal: true

describe Pikuri::Lsp::Anchor do
  describe '.locate — the helper every throwaway client grew on its first attempt' do
    it 'finds the symbol\'s own column, not the keyword\'s' do
      assert_equal [7], described_class.locate('class Read < Pikuri::Tool', 'Read')
    end

    it 'is 1-based, like every line number pikuri prints' do
      assert_equal [1], described_class.locate('names = 1', 'names')
    end

    it 'returns every occurrence, so a line mentioning a name twice is queried twice' do
      assert_equal [5, 13], described_class.locate('    names = names.trim', 'names')
    end

    it 'does not match inside a longer identifier' do
      assert_empty described_class.locate('  def greeting(name)', 'greet')
      assert_equal [7], described_class.locate('  def greet(name)', 'greet')
    end

    it 'matches a qualified name or an ivar, whose neighbours are not identifier characters' do
      assert_equal [19], described_class.locate('  include Pikuri::Agent::Extension', 'Agent::Extension')
      assert_equal [5], described_class.locate('    @confirmer = confirmer', '@confirmer')
    end

    it 'answers empty for a symbol that is not on the line, which is a clean error upstream' do
      assert_empty described_class.locate('  def call(path)', 'resolve_for_read')
    end

    it 'counts characters, not bytes or UTF-16 units' do
      # 16 characters in; 20 bytes in, and 17 UTF-16 code units in.
      assert_equal [16], described_class.locate('x = "héllo🎉" + names', 'names')
    end
  end
end
