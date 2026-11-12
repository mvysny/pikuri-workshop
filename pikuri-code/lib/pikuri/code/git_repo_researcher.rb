# frozen_string_literal: true

module Pikuri
  module Code
    # Bundled "clone-and-dig" persona. Where {Pikuri::SubAgent::RESEARCHER}
    # answers "look up one fact online", +GIT_REPO_RESEARCHER+ answers "explore
    # that repo's source for how it does X". Toolset is +git_clone+ +
    # +file_list+/+read+/+grep+/+glob+ (rebuilt onto the fresh workspace by
    # {Pikuri::SubAgent::SubAgentTool}) + the RESEARCHER network reads
    # (+web_search+/+web_scrape+/+fetch+). No +bash+/+edit+/+write+/+agent+.
    #
    # It signals +needs_temp_workspace: true+ and nothing more;
    # {Pikuri::SubAgent::SubAgentTool} owns the temp-dir lifecycle. That view is
    # *disjoint* from the parent's, so a path a cloned repo exfiltrates through
    # the persona's reply is inert (the parent's containment check rejects it).
    #
    # Trifecta-wise, same shape as {Pikuri::SubAgent::RESEARCHER}: leg (a)
    # private data is near-zero (only the temp workspace + what it downloaded),
    # so legs (b)/(c) — untrusted content + egress — are harmless. The one
    # wrinkle is the historical RCE class on +git clone+ itself, addressed by
    # {GitClone}'s HTTPS-only + no-submodules + Bubblewrap sandbox.
    #
    # @return [Pikuri::SubAgent::Persona]
    GIT_REPO_RESEARCHER = Pikuri::SubAgent::Persona.new(
      name: 'git_repo_researcher',
      description: 'Clone a public git repo and explore it with file_list/read/grep/glob. ' \
                   'Use when you need to dig through a repository\'s actual source, ' \
                   'not just a page about it. Also has web_search/web_scrape/fetch. ' \
                   'Returns one paragraph + citations.',
      tool_names: %w[git_clone file_list read grep glob web_search web_scrape fetch].freeze,
      system_prompt: Pikuri.prompt('persona-git-repo-researcher'),
      needs_temp_workspace: true
    )
  end
end
