# frozen_string_literal: true

RSpec.describe Pikuri::Skill::PathActivationListener do
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
      name: name, description: "#{name} description.",
      location: "/skills/#{name}/SKILL.md", body: 'b', paths: paths
    )
  end

  let(:rdoc) { skill('rdoc-writer', paths: ['**/*.rb']) }
  let(:ideas) { skill('ideas-folder', paths: ['ideas']) }
  let(:ungated) { skill('data-viz') }
  let(:activation) { Pikuri::Skill::Activation.new(catalog: fake_catalog_class.new([rdoc, ideas, ungated])) }
  let(:root) { Pathname.new('/repo') }
  let(:promotions) { [] }

  let(:listener) do
    described_class.new(
      activation: activation, root: root,
      on_promote: ->(skills, path) { promotions << [skills.map(&:name), path] }
    )
  end

  def touch(tool, arguments)
    listener.on_event(Pikuri::Agent::Event::ToolCall.new(tool_call_id: 'c1', name: tool, arguments: arguments,
                                                     display_name: Pikuri::Tool.display_name_for(tool),
                                                     argument: ''))
  end

  describe 'which tool calls count' do
    it 'promotes on read, write and edit' do
      %w[read write edit].each_with_index do |tool, i|
        activation.reset
        promotions.clear
        touch(tool, 'path' => "lib/a#{i}.rb")

        assert_equal [[['rdoc-writer'], "lib/a#{i}.rb"]], promotions, tool
      end
    end

    it 'ignores grep and glob, whose path is a search root, not a touched file' do
      touch('grep', 'path' => '.')
      touch('glob', 'path' => 'lib')

      assert_equal [], promotions
    end

    it 'ignores an event that is not a tool call' do
      listener.on_event(Pikuri::Agent::Event::Reset.new)

      assert_equal [], promotions
    end

    it 'reads the path under a symbol key too, since arguments arrive off JSON' do
      touch('read', path: 'lib/a.rb')

      assert_equal [['rdoc-writer'], 'lib/a.rb'], promotions.first
    end

    it 'ignores a call with no usable path' do
      touch('read', {})
      touch('read', 'path' => '   ')

      assert_equal [], promotions
    end
  end

  describe 'resolving the model-supplied path' do
    it 'accepts a path relative to the workspace root' do
      touch('read', 'path' => 'ideas/note.md')

      assert_equal [['ideas-folder'], 'ideas/note.md'], promotions.first
    end

    it 'accepts an absolute path inside the root, and matches on the relative part' do
      touch('read', 'path' => '/repo/ideas/note.md')

      assert_equal [['ideas-folder'], 'ideas/note.md'], promotions.first
    end

    it 'drops a path outside the root rather than matching it against the wrong tree' do
      touch('read', 'path' => '/etc/passwd.rb')
      touch('read', 'path' => '../sibling/a.rb')

      assert_equal [], promotions
    end

    it 'fires for a file that does not exist yet — a write target is the point' do
      touch('write', 'path' => 'lib/brand/new/file.rb')

      assert_equal [['rdoc-writer'], 'lib/brand/new/file.rb'], promotions.first
    end
  end

  describe 'what gets promoted' do
    it 'never promotes an ungated skill, which was never withheld' do
      touch('read', 'path' => 'lib/a.rb')

      assert_equal [['rdoc-writer'], 'lib/a.rb'], promotions.first
    end

    it 'promotes each skill once per conversation, however many files match' do
      touch('read', 'path' => 'lib/a.rb')
      touch('read', 'path' => 'lib/b.rb')
      touch('edit', 'path' => 'spec/c.rb')

      assert_equal 1, promotions.size
    end

    it 'promotes again after the conversation is cleared' do
      touch('read', 'path' => 'lib/a.rb')
      activation.reset
      touch('read', 'path' => 'lib/a.rb')

      assert_equal 2, promotions.size
    end

    it 'promotes several skills in one touch when several match' do
      touch('read', 'path' => 'ideas/note.rb')

      assert_equal [%w[rdoc-writer ideas-folder], 'ideas/note.rb'], promotions.first
    end

    it 'stays silent when nothing matches' do
      touch('read', 'path' => 'README.md')

      assert_equal [], promotions
    end
  end

  describe '#for_sub_agent' do
    it 'opts out, so a child cannot mutate the parent gate or enqueue on its interloper' do
      assert_nil listener.for_sub_agent(id: 'researcher 0')
    end
  end
end
