# frozen_string_literal: true

# The untrusted leg is graded by the catalog, so these run against real
# fixture trees rather than a stubbed catalog: the interesting rules —
# union, shadowing, empty bases — are all properties of an actual scan.
RSpec.describe 'skill tool trifecta legs' do
  TRIFECTA_FIXTURE_ROOT = File.expand_path('../../fixtures/skills', __dir__)

  def base(name, **flags)
    Pikuri::Bundle::Base.new(dir: File.join(TRIFECTA_FIXTURE_ROOT, name), **flags)
  end

  def untrusted_leg(*search_bases)
    catalog = Pikuri::Skill::Catalog::Bundled.new(search_bases: search_bases)
    Pikuri::Skill::SkillTool.new(activation: Pikuri::Skill::Activation.new(catalog: catalog)).trifecta_legs.untrusted
  end

  describe 'the untrusted leg' do
    it 'is hard over a base nobody vouched for' do
      assert_equal :hard, untrusted_leg(base('valid-tree'))
    end

    it 'drops when every stored skill came from a vouched base' do
      assert_equal :none, untrusted_leg(base('valid-tree', trusted: true))
    end

    it 'treats a bare path as untrusted, so saying nothing buys the pessimistic value' do
      assert_equal :hard, untrusted_leg(File.join(TRIFECTA_FIXTURE_ROOT, 'valid-tree'))
    end

    it 'unions across bases — one unvouched skill takes the whole catalog' do
      assert_equal :hard, untrusted_leg(base('valid-tree', trusted: true), base('name-mismatch-tree'))
    end

    it 'ignores a skill an earlier base shadowed — it was never loaded' do
      # collision-b holds nothing but a pdf-tools that loses to collision-a's.
      assert_equal :none, untrusted_leg(base('collision-a', trusted: true), base('collision-b'))
    end

    it 'costs nothing for an unvouched base that stores no skill' do
      # The wiring a host cannot avoid: Dir.home goes in untrusted because
      # nobody knows what is there, and the user who has no ~/.claude/skills
      # still gets the quiet reading. Scanned-but-stored-nothing counts the
      # same as absent — missing-description-tree's one skill is discarded.
      assert_equal :none, untrusted_leg(base('valid-tree', trusted: true), base('missing-description-tree'))
      assert_equal :none, untrusted_leg(base('valid-tree', trusted: true),
                                        Pikuri::Bundle::Base.new(dir: '/definitely/does/not/exist'))
    end

    it 'is hard for a catalog subclass that makes no claim' do
      assert_equal :hard, Pikuri::Skill::Catalog.new.untrusted_level
    end

    it 'is none for the empty catalog — the union over zero skills' do
      assert_equal :none, Pikuri::Skill::Catalog::EMPTY.untrusted_level
    end
  end

  it 'has no egress leg and claims no private pool' do
    tool = Pikuri::Skill::SkillTool.new(activation: Pikuri::Skill::Activation.new(catalog: Pikuri::Skill::Catalog::EMPTY))
    assert_equal :no_egress, tool.trifecta_legs.egress_payload_review
    refute tool.trifecta_legs.private
  end
end
