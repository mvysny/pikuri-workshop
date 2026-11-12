# frozen_string_literal: true

require 'pikuri-core'

# End-to-end specs that pin how +Pikuri::Skill::Extension+ wires into
# a real +Pikuri::Agent+ via the +Agent.new+ block. The extension's
# own behaviour is tested directly in +spec/pikuri/skill/
# extension_spec.rb+; these tests verify the integration — the snippet
# ends up in the chat's instructions, the skill tool ends up in the
# chat's tool list, etc.
#
# Self-contained: this spec ships its own minimal fake +RubyLLM::Chat+
# stand-in rather than depending on pikuri-core's test fixtures. The
# inline copy stays small because integration tests exercise only the
# surface +Agent#initialize+ touches (with_instructions, with_provider_options,
# with_tools, after_message / before_tool_call / after_tool_result hooks, ask).
RSpec.describe 'Pikuri::Skill::Extension agent integration' do
  let(:fake_model) { Struct.new(:context_window, :id).new(nil, 'm') }

  let(:fake_chat_class) do
    captured_model = fake_model
    Class.new do
      attr_reader :tools, :instructions

      define_method(:initialize) do
        @tools = []
        @model_info = captured_model
      end

      def model; @model_info; end
      def with_instructions(text); @instructions = text; self; end
      def with_provider_options(_); self; end
      def with_tools(tool); @tools << tool; self; end
      def after_message(&_block); self; end
      def before_tool_call(&_block); self; end
      def after_tool_result(&_block); self; end
      def add_message(_attrs); end
      def ask(_message, &_block); nil; end
    end
  end

  let(:fake_chat) { fake_chat_class.new }
  let(:recorder)  { Pikuri::Agent::Listener::InMemoryEventList.new }
  let(:listeners) { Pikuri::Agent::ListenerList.new([recorder]) }

  # +Context#chat+, not +RubyLLM.chat+: every chat an Agent builds rides a
  # per-transport +RubyLLM::Context+.
  before do
    captured = fake_chat
    @original_context_chat = RubyLLM::Context.instance_method(:chat)
    RubyLLM::Context.define_method(:chat) { |**_| captured }
  end

  after do
    RubyLLM::Context.define_method(:chat, @original_context_chat)
  end

  fake_catalog_class = Class.new(Pikuri::Skill::Catalog) do
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

  let(:sample_skill) do
    Pikuri::Skill::Catalog::Skill.new(
      name: 'sample',
      description: 'Sample skill description.',
      location: '/tmp/sample/SKILL.md',
      body: 'do the thing.'
    )
  end

  let(:non_empty_catalog) { fake_catalog_class.new([sample_skill]) }
  let(:root) { Pathname.new(Dir.pwd) }

  it 'appends the catalog block to the system prompt when the extension is added' do
    agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                              system_prompt: 'base') do |c|
      c.add_listeners(listeners)
      c.add_extension(Pikuri::Skill::Extension.new(catalog: non_empty_catalog, root: root))
    end

    assert agent.system_prompt.start_with?('base'), agent.system_prompt
    assert agent.system_prompt.include?('<available_skills>'), agent.system_prompt
    assert agent.system_prompt.include?('<name>sample</name>'), agent.system_prompt
    # The augmented prompt must be the one actually pushed to the chat,
    # not just the value cached on Pikuri::Agent.
    assert_equal agent.system_prompt, fake_chat.instructions
  end

  it 'auto-registers a Pikuri::Skill::SkillTool bound to the catalog when the extension is added' do
    agent = Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                              system_prompt: 'base') do |c|
      c.add_listeners(listeners)
      c.add_extension(Pikuri::Skill::Extension.new(catalog: non_empty_catalog, root: root))
    end

    skill_tool = agent.tools.find { |t| t.is_a?(Pikuri::Skill::SkillTool) }
    refute_nil skill_tool, 'expected the extension to auto-register a Pikuri::Skill::SkillTool'
    # And it must reach the chat — not just sit on the tools array.
    wired = fake_chat.tools.find { |t| t.name == 'skill' }
    refute_nil wired, 'expected the `skill` tool to be wired on the underlying chat'

    # Verify the bound catalog is the one we passed (the tool resolves
    # the sample skill we put in it).
    result = skill_tool.run('name' => 'sample').to_s
    assert result.include?('do the thing'), result
  end

  it 'binds the real agent interloper so a host can schedule a skill load' do
    interloper = Pikuri::Agent::Control::Interloper.new
    ext = Pikuri::Skill::Extension.new(catalog: non_empty_catalog, root: root)
    Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                      system_prompt: 'base',
                      interloper: interloper) do |c|
      c.add_listeners(listeners)
      c.add_extension(ext)
    end

    ext.schedule_load_skill('sample')

    pending = interloper.peek
    assert_equal 1, pending.size
    assert_equal :system, pending.first.kind
    assert pending.first.content.include?('<skill name="sample"'), pending.first.content
  end

  # The "manual SkillTool added alongside the extension" conflict is
  # intentionally not validated by Skill::Extension: detecting it
  # would require the extension to read the agent's full @tools list,
  # but at +configure+ time only the Configurator's own additions are
  # visible. The block-API conflict detection (c.add_tool followed by
  # c.add_extension) lives in spec/pikuri/skill/extension_spec.rb.
  # Users who call +c.add_tool(SkillTool.new)+ alongside the extension
  # end up with two skill-named tools on the chat — ruby_llm's
  # behavior, not pikuri's.
end
