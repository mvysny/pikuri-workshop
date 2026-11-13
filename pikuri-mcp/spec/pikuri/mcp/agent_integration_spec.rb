# frozen_string_literal: true

require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot

# End to end: a real Pikuri::Agent on a scripted fake LLM, wired to the in-tree
# MCP fixture through one shared Catalog. The fixture's +counter+ tool answers
# how often *its process* was called, which is what tells a shared process
# from an own one.
RSpec.describe 'Pikuri::Mcp::Extension on a real agent' do
  def agent(history: nil, &script)
    Pikuri::Agent.new(transport: Pikuri::Testing.fake_transport(&script),
                      system_prompt: 'test agent', history: history) do |c|
      c.add_extension Pikuri::Mcp::Extension.new(catalog: TestServer.catalog)
    end
  end

  def tool_results(agent)
    agent.export_history.messages.select { |m| m.role == 'tool' }.map(&:content)
  end

  it 'gives each conversation its own server process' do
    a = agent do |llm|
      llm.tool_call('mcp_connect', id: 'test')
      llm.tool_call('test__counter')
      llm.tool_call('test__counter')
      llm.reply('done')
    end
    b = agent do |llm|
      llm.tool_call('mcp_connect', id: 'test')
      llm.tool_call('test__counter')
      llm.reply('done')
    end
    a.run_loop(user_message: 'count twice')
    b.run_loop(user_message: 'count once')

    assert_equal '2', tool_results(a).last
    assert_equal '1', tool_results(b).last, 'B must not see the state A built up'
  ensure
    a&.close
    b&.close
  end

  it "gives a resumed conversation its connected servers' tools back, on a fresh process" do
    first = agent do |llm|
      llm.tool_call('mcp_connect', id: 'test')
      llm.tool_call('test__counter')
      llm.reply('done')
    end
    first.run_loop(user_message: 'count')
    history = first.export_history
    first.close

    resumed = agent(history: history) do |llm|
      llm.tool_call('test__counter') # no mcp_connect this time
      llm.tool_call('mcp_connect', id: 'test')
      llm.reply('done')
    end
    resumed.run_loop(user_message: 'count again')

    counter, reconnect = tool_results(resumed).last(2)
    assert_equal '1', counter, 'the old process died with the old agent'
    assert_match(/already connected/, reconnect)
  ensure
    first&.close
    resumed&.close
  end

  it "closes the agent's server process on Agent#close" do
    closed = 0
    original_close = Pikuri::Mcp::ClientWrapper.instance_method(:close)
    Pikuri::Mcp::ClientWrapper.define_method(:close) do
      closed += 1
      original_close.bind_call(self)
    end
    a = agent do |llm|
      llm.tool_call('mcp_connect', id: 'test')
      llm.tool_call('test__counter')
      llm.reply('done')
    end
    a.run_loop(user_message: 'count')
    a.close
    a.close
    assert_equal 1, closed
  ensure
    Pikuri::Mcp::ClientWrapper.define_method(:close, original_close)
  end
end
