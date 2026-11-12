# frozen_string_literal: true

require 'tmpdir'

# The detector's verdict table for this gem's wirings, checked against real
# tool objects rather than by hand. Nodes are assembled from actual
# constructors and the real SubAgent::Extension contribution, so a wiring
# change that moves a verdict fails here.
#
# Don't simplify that to stubbed legs: hand-graded rows are how the by-hand
# version of this table produced a bug that wasn't there, and a stub agrees
# with whatever you assumed.
#
# The pikuri-computer rows need pikuri-thunderbird, which this gem does not
# depend on; they live in pikuri-thunderbird's own spec.
RSpec.describe 'trifecta dry run: pikuri-code' do
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-dryrun-')).realpath }

  after { FileUtils.remove_entry(root) if root.exist? }

  def filesystem(**flags) = Pikuri::Workspace::Filesystem.new(project_root: root, **flags)

  # Stands in for Bubblewrap, bin/pikuri-code's default: contains the
  # filesystem, keeps the network (gem/bundle/mvn need it). Stubbed so these
  # run without bwrap; the real object's own answers are asserted in
  # bash/sandbox_spec.rb.
  def bubblewrap_shaped
    Class.new do
      def self.wrap(argv) = argv
      def self.egress? = true
      def self.confined_to_workspace? = true
    end
  end

  # The parent's own tools, as bin/pikuri-code wires them: the file tools
  # over the workspace, plus bash. The web tools are deliberately absent — they
  # live on the sub-agent personas.
  #
  # The skill tool is absent too, for a different reason: its untrusted leg is
  # graded by its catalog, but read and bash hold that leg here regardless, so
  # no answer to the skills question can move a row in this table. Both of its
  # readings are pinned in pikuri-skills' own trifecta_legs_spec.
  #
  # Note the trusted: true rows below model a workspace whose reachable set is
  # the project root. The real binary's is not — ToolchainPaths puts dependency
  # caches in readable: — which is why it never passes that flag.
  def parent_tools(sandbox: bubblewrap_shaped, **flags)
    fs = filesystem(**flags)
    ws = Pikuri::Workspace::Workspace.new(filesystem: fs)
    [Pikuri::Workspace::Read.new(workspace: ws),
     Pikuri::Workspace::Search::Grep.new(workspace: ws),
     Pikuri::Workspace::Search::Glob.new(workspace: ws),
     Pikuri::Workspace::Edit.new(workspace: ws),
     Pikuri::Code::Bash.new(filesystem: fs,
                            confirmer: Pikuri::Workspace::Confirmer::AUTO_APPROVE,
                            sandbox: sandbox)]
  end

  # RESEARCHER and FILE_MINER, quarantined behind the sub-agent boundary.
  def web_tools
    hard = Pikuri::Tool::TrifectaLegs.new(private: false, untrusted: :hard, egress_payload_review: :unreviewed)
    %w[web_search web_scrape fetch].map do |name|
      Pikuri::Tool.new(name: name, description: 'x',
                       parameters: Pikuri::Tool::Parameters.build { |_p| },
                       execute: ->(**) { '' }, trifecta_legs: hard)
    end
  end

  def report(**flags)
    own = parent_tools(**flags)
    children = Pikuri::SubAgent::Extension
               .new(personas: [Pikuri::SubAgent::RESEARCHER], confirmer: nil)
               .trifecta_contribution(own + web_tools).children
    node = Pikuri::Trifecta::Node.new(
      label: 'pikuri-code',
      tool_legs: own.to_h { |t| [t.name, t.trifecta_legs] },
      children: children
    )
    Pikuri::Trifecta.walk(node)
  end

  it 'is silent over a public checkout — the private leg is never declared' do
    assert_equal :silent, report.tree_verdict
  end

  it 'is loud over an untrusted private repo — the one loud verdict in the repo' do
    # bash shares the network (gem/bundle/mvn need it), so the parent egresses
    # directly: quarantining the web tools buys context hygiene, not an egress
    # break.
    r = report(private: true)
    assert_equal :loud, r.tree_verdict
    assert_equal %i[private untrusted_hard egress], r.legs.to_tags
  end

  it 'softens over a *trusted* private repo — untrusted survives only via delegation' do
    r = report(private: true, trusted: true)
    assert_equal :soft, r.tree_verdict
    assert_equal :weakened, r.legs.untrusted, 'the web tools are sub-agent-only'
  end

  it 'gives one binary three verdicts, on two declarations' do
    assert_equal %i[silent loud soft],
                 [report.tree_verdict,
                  report(private: true).tree_verdict,
                  report(private: true, trusted: true).tree_verdict]
  end

  it 're-hardens the trusted repo to loud under --no-sandbox' do
    # The trusted: declaration covers what the *workspace* reaches; an
    # unsandboxed bash reads ~/Downloads regardless, so the claim stops being
    # honest and the untrusted leg comes back hard.
    r = report(private: true, trusted: true, sandbox: Pikuri::Code::Bash::Sandbox::NONE)
    assert_equal :hard, r.legs.untrusted
    assert_equal :loud, r.tree_verdict
  end

  describe 'the advisory line' do
    it 'names the leg to break rather than only the severity' do
      line = report(private: true).advisory
      assert_includes line, '[TRIFECTA: HARD]'
      assert_includes line, 'bash'
      assert_includes line, 'sever egress'
    end

    it 'reports the finding instead of claiming safety when nothing fires' do
      line = report.advisory
      refute_includes line, 'No trifecta'
      assert_includes line, '2 of 3 legs'
      assert_includes line, 'no private leg found'
    end
  end
end
