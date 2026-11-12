# frozen_string_literal: true

RSpec.describe Pikuri::Skill::Activation do
  # A minimal in-memory Catalog: this spec is about the session view over a
  # catalog, not about scanning one off disk.
  let(:fake_catalog_class) do
    Class.new(Pikuri::Skill::Catalog) do
      def initialize(skills)
        super()
        @skills = skills
      end

      def list = @skills
      def get(name) = @skills.find { |s| s.name == name }
      def roots = []
    end
  end

  def skill(name, paths: Pikuri::Skill::PathMatcher::UNCONDITIONAL)
    Pikuri::Skill::Catalog::Skill.new(
      name: name,
      description: "#{name} description.",
      location: "/skills/#{name}/SKILL.md",
      body: "#{name} body.",
      paths: paths
    )
  end

  let(:ungated) { skill('data-viz') }
  let(:gated) { skill('rdoc-writer', paths: ['**/*.rb']) }
  let(:activation) { described_class.new(catalog: fake_catalog_class.new([ungated, gated])) }

  describe 'an ungated skill' do
    it 'is in play from the start' do
      assert activation.in_play?('data-viz')
      assert_equal ungated, activation.get('data-viz')
    end
  end

  describe 'a gated skill' do
    it 'is withheld until its path fires' do
      refute activation.in_play?('rdoc-writer')
      assert_nil activation.get('rdoc-writer')
      assert_equal ['data-viz'], activation.names
    end

    it 'is in play once activated' do
      activation.activate([gated])

      assert activation.in_play?('rdoc-writer')
      assert_equal gated, activation.get('rdoc-writer')
      assert_equal %w[data-viz rdoc-writer], activation.names
    end
  end

  describe '#activate' do
    it 'answers with the skills that were not already activated' do
      assert_equal [gated], activation.activate([gated])
      assert_equal [], activation.activate([gated])
    end

    it 'reports only the newcomers out of a mixed batch' do
      other = skill('tuile', paths: ['**/*.rb'])
      activation.activate([gated])

      assert_equal [other], activation.activate([gated, other])
    end

    it 'preserves the given order' do
      other = skill('tuile', paths: ['**/*.rb'])
      assert_equal [other, gated], activation.activate([other, gated])
    end
  end

  describe '#reset' do
    it 're-hides an activated skill, so the next touch announces it again' do
      activation.activate([gated])
      activation.reset

      refute activation.in_play?('rdoc-writer')
      assert_nil activation.get('rdoc-writer')
      assert_equal [gated], activation.activate([gated])
    end

    it 'leaves ungated skills alone' do
      activation.reset

      assert activation.in_play?('data-viz')
    end
  end

  describe 'an unknown name' do
    it 'is refused exactly as a withheld one is' do
      refute activation.in_play?('no-such-skill')
      assert_nil activation.get('no-such-skill')
    end
  end

  it 'exposes the unfiltered catalog, which keeps reporting what is installed' do
    assert_equal %w[data-viz rdoc-writer], activation.catalog.list.map(&:name)
  end

  describe Pikuri::Skill::Activation::Sealed do
    let(:sealed) { described_class.new(catalog: fake_catalog_class.new([ungated, gated])) }

    it 'still loads the ungated skills' do
      assert sealed.in_play?('data-viz')
      assert_equal ungated, sealed.get('data-viz')
      assert_equal ['data-viz'], sealed.names
    end

    it 'withholds a gated skill with no way to change that' do
      refute sealed.in_play?('rdoc-writer')
      assert_nil sealed.get('rdoc-writer')
    end

    it 'raises on an attempt to promote, naming the skills' do
      err = assert_raises(RuntimeError) { sealed.activate([gated]) }
      assert_match(/rdoc-writer/, err.message)
      assert_match(/sub-agent/, err.message)
    end

    it 'refuses an unknown name exactly as a withheld one' do
      refute sealed.in_play?('no-such-skill')
      assert_nil sealed.get('no-such-skill')
    end

    it 'tolerates a reset, since a host may clear a conversation it holds' do
      assert_nil sealed.reset
    end
  end
end
