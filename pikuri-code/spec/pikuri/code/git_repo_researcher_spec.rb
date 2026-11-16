# frozen_string_literal: true

require 'tmpdir'
require 'pikuri/testing'

RSpec.describe Pikuri::Code::GitRepoResearcher do
  def web_tools
    %w[web_search web_scrape fetch].map do |name|
      Pikuri::Tool.new(name: name, description: 'x',
                       parameters: Pikuri::Tool::Parameters.build { |_p| },
                       execute: ->(**) { '' },
                       trifecta_legs: Pikuri::Tool::TrifectaLegs.new(
                         private: false, untrusted: :hard, egress_payload_review: :unreviewed
                       ))
    end
  end

  describe '#configure' do
    let(:c) { Pikuri::Testing.configurator }

    it 'registers git_repo_research when the web tools are there' do
      web_tools.each { |t| c.add_sub_agent_tool(t) }
      described_class.new.configure(c)
      assert_includes c.tools.map(&:name), 'git_repo_research'
    end

    it 'raises, naming the missing web tool, when one is not registered yet' do
      web_tools.drop(1).each { |t| c.add_sub_agent_tool(t) }
      err = assert_raises(ArgumentError) { described_class.new.configure(c) }
      assert_match(/web_search/, err.message)
    end
  end

  describe 'a call' do
    let(:project) { Pathname.new(Dir.mktmpdir('pikuri-grr-project-')).realpath }
    let(:secret)  { project + 'secret.txt' }
    let(:events)  { [] }
    let(:spy) do
      out = events
      Class.new do
        define_method(:on_event) { |e| out << e }
        def for_sub_agent(**) = self
      end.new
    end

    before do
      File.write(secret, 'TOP SECRET')
      @minted = []
      minted = @minted
      @new_temp = Pikuri::Paths.method(:new_temp)
      original = @new_temp
      Pikuri::Paths.define_singleton_method(:new_temp) { original.call.tap { minted << _1 } }
    end

    after do
      original = @new_temp
      Pikuri::Paths.define_singleton_method(:new_temp) { original.call }
      FileUtils.remove_entry(project)
    end

    def run_parent(transport, around_request: nil)
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test',
                                around_request: around_request) do |c|
        c.add_listener spy
        web_tools.each { |t| c.add_sub_agent_tool(t) }
        c.add_extension described_class.new
      end
      agent.run_loop(user_message: 'go')
      agent.close
    end

    it "answers with the child's reply, from a folder that cannot see the parent's project" do
      path = secret.to_s
      transport = Pikuri::Testing.fake_transport do |llm|
        llm.tool_call('git_repo_research', task: 'look around')   # parent
        llm.tool_call('read', path: path)                         # child
        llm.reply('child answer')                                 # child
        llm.reply('done')                                         # parent
      end
      run_parent(transport)

      results = events.grep(Pikuri::Agent::Event::ToolResult)
      read = results.find { _1.name == 'read' }
      refute_includes read.content, 'TOP SECRET'
      assert_equal 'child answer', results.find { _1.name == 'git_repo_research' }.content
    end

    it 'deletes its folder once the call returns' do
      transport = Pikuri::Testing.fake_transport do |llm|
        llm.tool_call('git_repo_research', task: 'look around')
        llm.reply('child answer')
        llm.reply('done')
      end
      run_parent(transport)

      assert_equal 1, @minted.size
      refute_predicate @minted.first, :exist?
    end

    it "answers the child's context overflow as a tool error, and the parent carries on" do
      transport = Pikuri::Testing.fake_transport do |llm|
        llm.tool_call('git_repo_research', task: 'read the whole kernel')   # parent
        llm.reply('done')                                                   # parent
      end
      requests = 0
      # The second request is the child's first; it overflows.
      overflow = lambda do |_api_base, _cancellable, &request|
        requests += 1
        raise RubyLLM::ContextLengthExceededError if requests == 2

        request.call
      end
      run_parent(transport, around_request: overflow)

      result = events.grep(Pikuri::Agent::Event::ToolResult).find { _1.name == 'git_repo_research' }
      assert_match(/\AError: .*ran out of context.*narrower task/, result.content)
      assert_equal 'done', events.grep(Pikuri::Agent::Event::Assistant).last.content
      refute_predicate @minted.first, :exist?
    end
  end

  it "draws its child's tools as one node behind an unreviewed channel" do
    contribution = described_class.new.trifecta_contribution(web_tools)
    node = contribution.children.first
    assert_equal 'git_repo_research', node.label
    assert_equal %w[fetch file_list git_clone glob grep read web_scrape web_search], node.tool_legs.keys.sort
  end
end
