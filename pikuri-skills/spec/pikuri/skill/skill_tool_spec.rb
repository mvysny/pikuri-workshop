# frozen_string_literal: true

RSpec.describe Pikuri::Skill::SkillTool do
  FIXTURE_VALID_BASE = File.expand_path('../../fixtures/skills/valid-tree', __dir__)
  FIXTURE_VALID_SKILL_DIR = File.join(FIXTURE_VALID_BASE, '.pikuri/skills')

  let(:catalog) { Pikuri::Skill::Catalog::Bundled.new(search_bases: [FIXTURE_VALID_BASE]) }
  let(:activation) { Pikuri::Skill::Activation.new(catalog: catalog) }

  describe 'tool shape' do
    it 'is named "skill" and exposes a required `name` string parameter' do
      tool = described_class.new(activation: activation)

      assert_kind_of Pikuri::Tool, tool
      assert_equal 'skill', tool.name
      schema = tool.parameters.to_openai
      assert_equal ['name'], schema[:required]
      assert_equal 'string', schema[:properties][:name][:type]
    end

    it "uses a static description that points to the system prompt's catalog" do
      tool = described_class.new(activation: activation)
      assert tool.description.include?('available_skills'),
             "expected static description to point the LLM at the prompt's catalog, got: #{tool.description}"
    end

    # A persona naming `skill` in tool_names: inherits the tool but not the
    # Extension that contributes <available_skills>, so a description promising
    # that section would send it looking for a block its prompt never carries.
    it 'never asserts the prompt carries that catalog, for the sub-agent case' do
      tool = described_class.new(activation: activation)
      text = "#{tool.description} #{tool.parameters.to_openai[:properties][:name][:description]}"

      refute_match(/(is|are) listed in your system prompt/, text)
      refute_match(/Must match a name listed under/, text)
      assert text.include?('when it carries that section'),
             "expected the description to hedge on the catalog's presence, got: #{text}"
    end
  end

  describe 'execution' do
    it 'returns the skill body wrapped with the base directory when the name resolves' do
      tool = described_class.new(activation: activation)
      out = tool.run('name' => 'pdf-tools').to_s

      assert out.include?('<skill name="pdf-tools"'), out
      assert out.include?('pdftotext'), out
      assert out.include?(File.join(FIXTURE_VALID_SKILL_DIR, 'pdf-tools')), out
      assert out.include?('</skill>'), out
    end

    it 'reports the loaded size as its display line, never a slice of the body' do
      tool = described_class.new(activation: activation)
      result = tool.run('name' => 'pdf-tools')

      assert_match(/\ALoaded \d+(\.\d+)? (B|kB|MB)\z/, result.summary)
      refute_includes result.summary, 'pdftotext'
    end

    it 'returns an LLM-actionable Error: string for an unknown name, listing what is available' do
      tool = described_class.new(activation: activation)
      out = tool.run('name' => 'no-such-skill').to_s

      assert out.start_with?('Error:'), out
      assert out.include?("'no-such-skill'"), out
      # The hint must enumerate every skill the catalog knows about so
      # the LLM can recover on the next turn without guessing.
      assert out.include?('pdf-tools'), out
      assert out.include?('data-viz'), out
    end

    it 'returns an Error: string mentioning "none" when the catalog is empty' do
      tool = described_class.new(activation: Pikuri::Skill::Activation.new(catalog: Pikuri::Skill::Catalog::EMPTY))
      out = tool.run('name' => 'anything').to_s

      assert out.start_with?('Error:'), out
      assert out.include?('none'), out
    end

    it 'reports a validation error for the wrong argument shape (not raised, not crashed)' do
      tool = described_class.new(activation: activation)
      out = tool.run({})

      assert out.error?, out.inspect
      assert out.content.include?('name'), out.content
    end
  end

  describe '#for_sub_agent' do
    it 'hands the child a sealed view of the same catalog' do
      child = described_class.new(activation: activation).for_sub_agent

      assert_kind_of Pikuri::Skill::Activation::Sealed, child.activation
      assert_same catalog, child.activation.catalog
    end

    it 'is a distinct tool, so the parent keeps its own activation' do
      parent = described_class.new(activation: activation)
      child = parent.for_sub_agent

      refute_same parent, child
      assert_same activation, parent.activation
    end

    it 'still resolves the ungated skills the persona was told about' do
      child = described_class.new(activation: activation).for_sub_agent
      out = child.run('name' => 'pdf-tools').to_s

      assert out.include?('<skill name="pdf-tools"'), out
    end

    it 'is idempotent, so a re-seal is harmless' do
      twice = described_class.new(activation: activation).for_sub_agent.for_sub_agent

      assert_kind_of Pikuri::Skill::Activation::Sealed, twice.activation
      assert_same catalog, twice.activation.catalog
    end
  end
end
