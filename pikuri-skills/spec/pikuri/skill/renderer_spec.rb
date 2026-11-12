# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

RSpec.describe Pikuri::Skill::Renderer do
  RENDERER_FIXTURE_ROOT = File.expand_path('../../fixtures/skills', __dir__)

  # Build a Catalog::Skill directly, so a render can be exercised without a
  # SKILL.md on disk (used for the metacharacter-escaping cases).
  def skill(name:, location:, description: 'desc', body: 'body')
    Pikuri::Skill::Catalog::Skill.new(
      name: name, description: description, location: location, body: body
    )
  end

  describe '.format_catalog' do
    it 'returns an empty string when there is nothing to advertise' do
      assert_equal '', described_class.format_catalog([])
    end

    it 'emits an <available_skills> block with name/description' do
      catalog = Pikuri::Skill::Catalog::Bundled.new(
        search_bases: [File.join(RENDERER_FIXTURE_ROOT, 'valid-tree')]
      )
      out = described_class.format_catalog(catalog.list)

      assert out.include?('<available_skills>'), out
      assert out.include?('</available_skills>'), out
      assert out.include?('<name>pdf-tools</name>'), out
      assert out.include?('<name>data-viz</name>'), out
      assert out.include?('<description>Extracts text from PDF'), out
    end

    # The path belongs to .format_skill alone — the standard sanctions omitting
    # it here when the activation tool returns the directory, and it is dead
    # weight in a resident block. Guarded, because re-adding it would be
    # invisible in a passing suite.
    it 'omits the skill path, which only the body block carries' do
      catalog = Pikuri::Skill::Catalog::Bundled.new(
        search_bases: [File.join(RENDERER_FIXTURE_ROOT, 'valid-tree')]
      )
      out = described_class.format_catalog(catalog.list)

      refute out.include?('<location>'), out
      refute out.include?('SKILL.md'), out
    end

    it 'escapes XML metacharacters in name/description' do
      Dir.mktmpdir do |base|
        dir = File.join(base, '.pikuri/skills/xml-skill')
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, 'SKILL.md'), <<~MD)
          ---
          name: xml-skill
          description: Watch <out> for "quotes" & ampersands.
          ---
          body
        MD

        catalog = Pikuri::Skill::Catalog::Bundled.new(search_bases: [base])
        out = described_class.format_catalog(catalog.list)
        assert out.include?('&lt;out&gt;'), out
        assert out.include?('&quot;quotes&quot;'), out
        assert out.include?('&amp;'), out
      end
    end
  end

  describe '.format_promotion' do
    def gated(when_to_use:, description: 'Writes rdoc headers. Use when the user edits a .rb file.')
      Pikuri::Skill::Catalog::Skill.new(
        name: 'rdoc-writer', description: description, location: '/s/rdoc-writer/SKILL.md',
        body: 'b', paths: ['**/*.rb'], when_to_use: when_to_use
      )
    end

    it 'reuses the catalog block shape, so the model reads it the same way' do
      out = described_class.format_promotion([gated(when_to_use: nil)])

      assert out.include?('<available_skills>'), out
      assert out.include?('<name>rdoc-writer</name>'), out
      assert out.include?('just became relevant'), out
      # Same shape means the same omission: a promotion is an inventory entry.
      refute out.include?('<location>'), out
    end

    it 'closes with the load instruction, outranking style inferred from nearby code' do
      out = described_class.format_promotion([gated(when_to_use: nil)])

      assert out.include?('load it with the `skill` tool first'), out
      assert out.include?('any convention you infer from the surrounding code'), out
      assert out.include?('If none matches, just proceed normally.'), out
    end

    it 'carries when-to-use, de-duplicated against the description' do
      out = described_class.format_promotion([gated(when_to_use: 'Use when: editing a .rb file.')])

      assert out.include?('<description>Writes rdoc headers</description>'), out
      assert out.include?('<when-to-use>editing a .rb file.</when-to-use>'), out
    end

    it 'keeps the description whole when no when-to-use was declared' do
      out = described_class.format_promotion([gated(when_to_use: nil)])

      assert out.include?('<description>Writes rdoc headers. Use when the user edits a .rb file.</description>'), out
      refute out.include?('<when-to-use>'), out
    end
  end

  describe '.format_catalog vs .format_promotion' do
    it 'leaves when-to-use out of the resident block, which pays on every turn' do
      skill = Pikuri::Skill::Catalog::Skill.new(
        name: 'a', description: 'd', location: '/s/a/SKILL.md', body: 'b',
        when_to_use: 'Use when: never.'
      )

      refute described_class.format_catalog([skill]).include?('<when-to-use>')
    end
  end

  describe '.format_skill' do
    it 'wraps the body with the name, location and sidecar base directory' do
      out = described_class.format_skill(
        skill(name: 'pdf-tools', location: '/repo/.pikuri/skills/pdf-tools/SKILL.md', body: 'run pdftotext')
      )

      assert out.include?('<skill name="pdf-tools" location="/repo/.pikuri/skills/pdf-tools/SKILL.md">'), out
      assert out.include?('relative to /repo/.pikuri/skills/pdf-tools.'), out
      assert out.include?('run pdftotext'), out
      assert out.include?('</skill>'), out
    end

    it 'escapes XML metacharacters in the wrapper name/location attributes' do
      out = described_class.format_skill(
        skill(name: 'weird"<name>', location: '/tmp/a&b/SKILL.md')
      )

      assert out.include?('name="weird&quot;&lt;name&gt;"'), out
      assert out.include?('location="/tmp/a&amp;b/SKILL.md"'), out
    end

    it 'leaves the body verbatim (not XML-escaped)' do
      out = described_class.format_skill(
        skill(name: 'x', location: '/x/SKILL.md', body: 'if a < b && c > d then')
      )

      assert out.include?('if a < b && c > d then'), out
    end
  end
end
