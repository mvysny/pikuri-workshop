# frozen_string_literal: true

require 'pikuri-web'

RSpec.describe Pikuri::Code::GIT_REPO_RESEARCHER do
  it 'is a Persona record named "git_repo_researcher"' do
    assert_kind_of Pikuri::SubAgent::Persona, described_class
    assert_equal 'git_repo_researcher', described_class.name
  end

  it 'declares clone-and-dig tool_names — git_clone + fs reads + web reads, no shell/mutation/recursion' do
    assert_equal %w[git_clone file_list read grep glob web_search web_scrape fetch],
                 described_class.tool_names
  end

  it 'loads its system prompt from pikuri-code/prompts/persona-git-repo-researcher.txt' do
    refute_predicate described_class.system_prompt, :empty?
    assert_match(/git_repo_researcher sub-agent/i, described_class.system_prompt)
  end

  it 'signals needs_temp_workspace so SubAgentTool mints a fresh Filesystem at spawn' do
    assert_equal true, described_class.needs_temp_workspace
  end

  describe 'integration with Pikuri::SubAgent::Extension' do
    let(:root)       { Pathname.new(Dir.mktmpdir('pikuri-grr-spec-')).realpath }
    let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
    let(:workspace)  { Pikuri::Workspace::Workspace.new(filesystem: filesystem) }

    after { FileUtils.rm_rf(root) }

    let(:tools) do
      [
        Pikuri::Code::GitClone.new(filesystem: filesystem, sandbox: Pikuri::Code::Bash::Sandbox::NONE),
        Pikuri::Workspace::Read.new(workspace: workspace),
        Pikuri::Workspace::Search::Grep.new(workspace: workspace),
        Pikuri::Workspace::Search::Glob.new(workspace: workspace),
        Pikuri::Workspace::FileList.new(workspace: workspace),
        Pikuri::Web::Search.build,
        Pikuri::Web::SCRAPE,
        Pikuri::Web::FETCH
      ]
    end

    let(:configurator) do
      Pikuri::Agent::Configurator.new(
        transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
        system_prompt_base: 'base',
        id: '',
        streaming: false,
        cancellable: nil,
        interloper: nil
      )
    end

    it 'configures cleanly when every persona tool is registered' do
      tools.each { |t| configurator.add_tool(t) }
      ext = Pikuri::SubAgent::Extension.new(personas: [described_class])
      ext.configure(configurator)
      assert_equal ['git_repo_researcher'], ext.personas.keys
    end

    it "raises Extension#configure when one of the persona's tools is missing" do
      # git_clone deliberately missing — the persona's distinguishing tool.
      tools.drop(1).each { |t| configurator.add_tool(t) }
      ext = Pikuri::SubAgent::Extension.new(personas: [described_class])

      err = assert_raises(ArgumentError) { ext.configure(configurator) }
      assert_match(/git_clone/, err.message)
    end
  end
end
