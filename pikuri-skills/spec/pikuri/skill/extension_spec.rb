# frozen_string_literal: true

require 'pikuri/testing'

RSpec.describe Pikuri::Skill::Extension do
  # Minimal stand-in for a non-empty catalog — same shape used in
  # agent_spec.rb's skill_catalog wiring section, lifted here so
  # these specs don't need on-disk skill files.
  let(:fake_catalog_class) do
    Class.new(Pikuri::Skill::Catalog) do
      def initialize(skills)
        super()
        @skills = skills
      end

      def list
        @skills
      end

      def get(name)
        @skills.find { |s| s.name == name }
      end
    end
  end

  let(:sample_skill) do
    Pikuri::Skill::Catalog::Skill.new(
      name: 'sample',
      description: 'Sample skill description.',
      location: '/tmp/sample/SKILL.md',
      body: 'do the thing.'
    )
  end

  let(:gated_skill) do
    Pikuri::Skill::Catalog::Skill.new(
      name: 'gated',
      description: 'Gated skill description.',
      location: '/tmp/gated/SKILL.md',
      body: 'do the gated thing.',
      paths: ['**/*.rb']
    )
  end

  let(:non_empty_catalog) { fake_catalog_class.new([sample_skill]) }
  let(:empty_catalog) { Pikuri::Skill::Catalog::EMPTY }
  let(:non_empty_activation) { Pikuri::Skill::Activation.new(catalog: non_empty_catalog) }
  let(:root) { Pathname.new(Dir.pwd) }
  let(:configurator) { Pikuri::Testing.configurator }
  let(:interloper) { configurator.agent.interloper }

  # An extension over a catalog holding one ungated and one gated skill —
  # everything the gate has an opinion about.
  let(:gated_extension) do
    described_class.new(catalog: fake_catalog_class.new([sample_skill, gated_skill]), root: root)
  end

  # The listeners +configure+ adds, recorded on the way to the agent.
  def recording_listeners(c)
    added = []
    real_add = c.method(:add_listener)
    c.define_singleton_method(:add_listener) { |l| (added << l) && real_add.call(l) }
    added
  end

  it 'is an Agent::Extension by composition' do
    ext = described_class.new(catalog: non_empty_catalog, root: root)
    assert_kind_of Pikuri::Agent::Extension, ext
  end

  describe '#configure / #system_prompt_snippets' do
    it 'contributes the catalog block and registers Skill::SkillTool (non-empty catalog)' do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      ext.configure(configurator)

      assert_equal 1, ext.system_prompt_snippets.size
      snippet = ext.system_prompt_snippets.first
      # The snippet itself must not start with blank lines — the
      # Agent handles the separator at assembly time.
      refute snippet.start_with?("\n"), 'snippet should be lstripped'
      assert snippet.include?('<available_skills>'), snippet
      assert snippet.include?('<name>sample</name>'), snippet

      assert_equal 1, configurator.tools.size
      tool = configurator.tools.first
      assert_kind_of Pikuri::Skill::SkillTool, tool
    end

    it 'is a no-op when the catalog is empty' do
      ext = described_class.new(catalog: empty_catalog, root: root)
      ext.configure(configurator)

      assert_equal [], ext.system_prompt_snippets
      assert_equal [], configurator.tools
    end

    it 'raises if Pikuri::Skill::SkillTool was already pre-registered via c.add_tool' do
      configurator.add_tool(Pikuri::Skill::SkillTool.new(activation: non_empty_activation))
      ext = described_class.new(catalog: non_empty_catalog, root: root)

      err = assert_raises(RuntimeError) { ext.configure(configurator) }
      assert_match(/auto-registers/, err.message)
    end
  end

  describe '#schedule_load_skill' do
    it "enqueues a :system skill block on the agent's interloper" do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      ext.configure(configurator)

      returned = ext.schedule_load_skill('sample')

      assert_same sample_skill, returned
      pending = interloper.drain!
      assert_equal 1, pending.size
      assert_equal :system, pending.first.kind
      assert pending.first.content.include?('<skill name="sample"'), pending.first.content
      assert pending.first.content.include?('do the thing.'), pending.first.content
    end

    it 'raises KeyError for a name absent from the catalog, enqueuing nothing' do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      ext.configure(configurator)

      assert_raises(KeyError) { ext.schedule_load_skill('no-such-skill') }
      assert_equal [], interloper.drain!
    end
  end

  describe '#catalog / #root' do
    it 'exposes the catalog passed at construction' do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      assert_same non_empty_catalog, ext.catalog
    end

    it 'exposes the workspace root passed at construction' do
      ext = described_class.new(catalog: non_empty_catalog, root: root)
      assert_equal root, ext.root
    end

    it 'refuses a root that is not a Pathname' do
      err = assert_raises(ArgumentError) { described_class.new(catalog: non_empty_catalog, root: Dir.pwd) }
      assert_match(/absolute Pathname/, err.message)
    end

    it 'refuses a relative root, since a model-supplied path resolves against it' do
      err = assert_raises(ArgumentError) do
        described_class.new(catalog: non_empty_catalog, root: Pathname.new('lib'))
      end
      assert_match(/absolute Pathname/, err.message)
    end
  end

  describe '#activation' do
    let(:ext) { gated_extension }

    it 'is a view over the same catalog, withholding the gated skills' do
      assert_same ext.catalog, ext.activation.catalog
      assert_equal ['sample'], ext.activation.names
    end
  end

  describe 'the gate' do
    it 'withholds a gated skill from the prompt block, with no hint it exists' do
      ext = gated_extension
      ext.configure(configurator)

      snippet = ext.system_prompt_snippets.first
      assert snippet.include?('<name>sample</name>'), snippet
      refute snippet.include?('gated'), snippet
    end

    it 'refuses a withheld name through the skill tool, listing only what is in play' do
      ext = gated_extension
      ext.configure(configurator)
      tool = configurator.tools.first

      out = tool.run('name' => 'gated').to_s
      assert out.start_with?('Error:'), out
      refute out.include?('Available skills: gated'), out
      assert out.include?('sample'), out
    end

    it 'loads the same name once its path has fired' do
      ext = gated_extension
      ext.configure(configurator)
      ext.activation.activate([gated_skill])

      out = configurator.tools.first.run('name' => 'gated').to_s
      assert out.include?('do the gated thing.'), out
    end

    it 'refuses a withheld name to the host too, and allows it once fired' do
      ext = gated_extension
      ext.configure(configurator)

      assert_raises(KeyError) { ext.schedule_load_skill('gated') }
      ext.activation.activate([gated_skill])
      assert_equal gated_skill, ext.schedule_load_skill('gated')
    end

    it 'registers the activation listener when there is somewhere to promote to' do
      added = recording_listeners(configurator)
      gated_extension.configure(configurator)

      assert added.any?(Pikuri::Skill::PathActivationListener)
    end

    it 'registers no listener when nothing is gated' do
      added = recording_listeners(configurator)
      described_class.new(catalog: non_empty_catalog, root: root).configure(configurator)

      assert_equal [], added
    end
  end

  describe '#announce' do
    it 'injects the promotion and emits Skill::Promoted' do
      ext = gated_extension
      recorder = Pikuri::Agent::Listener::InMemoryEventList.new
      configurator.add_listener(recorder)
      ext.configure(configurator)

      ext.announce([gated_skill], 'lib/a.rb')

      pending = interloper.drain!
      assert_equal 1, pending.size
      assert_equal :system, pending.first.kind
      assert pending.first.content.include?('<name>gated</name>'), pending.first.content

      event = recorder.events.first
      assert_kind_of Pikuri::Skill::Promoted, event
      assert_equal 'lib/a.rb', event.path
      assert_equal 'skills available: gated (matched lib/a.rb)', event.to_s
    end

    it 'injects nothing when nothing was newly promoted' do
      ext = gated_extension
      ext.configure(configurator)

      ext.announce([], 'lib/a.rb')

      assert_equal [], interloper.drain!
    end
  end
end
