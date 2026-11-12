# frozen_string_literal: true

require 'tmpdir'

# The legs Bash derives from its collaborators. Each sandbox's own posture
# predicates are asserted in sandbox_spec.rb, which owns the bwrap
# availability gate; here they are stubbed, so these run anywhere.
RSpec.describe 'Bash trifecta legs' do
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-posture-')).realpath }

  def filesystem(**flags) = Pikuri::Workspace::Filesystem.new(project_root: root, **flags)

  after { FileUtils.remove_entry(root) if root.exist? }

  describe 'Bash legs' do
    def bash(sandbox:, **flags)
      Pikuri::Code::Bash.new(filesystem: filesystem(**flags),
                             confirmer: Pikuri::Workspace::Confirmer::AUTO_APPROVE,
                             sandbox: sandbox)
    end

    let(:none) { Pikuri::Code::Bash::Sandbox::NONE }

    it 'takes egress from the sandbox posture, not from the tool name' do
      assert_equal :unreviewed, bash(sandbox: none).trifecta_legs.egress_payload_review
    end

    it 'severs the egress leg when the sandbox answers no' do
      severed = Class.new do
        def self.wrap(argv) = argv
        def self.egress? = false
        def self.confined_to_workspace? = true
      end
      assert_equal :no_egress, bash(sandbox: severed).trifecta_legs.egress_payload_review
    end

    it 'inherits the private leg from the workspace declaration' do
      assert bash(sandbox: none, private: true).trifecta_legs.private
      refute bash(sandbox: none).trifecta_legs.private
    end

    it 'stays hard-untrusted over a trusted workspace when the sandbox is not confined' do
      # The silent failure the sandbox axis exists to prevent: scoping and
      # vouching for the workspace buys nothing while bash can still read
      # ~/Downloads.
      assert_equal :hard, bash(sandbox: none, trusted: true).trifecta_legs.untrusted
    end

    it 'drops the untrusted leg only when the sandbox confines AND the workspace is vouched for' do
      confined = Class.new do
        def self.wrap(argv) = argv
        def self.egress? = true
        def self.confined_to_workspace? = true
      end
      assert_equal :none, bash(sandbox: confined, trusted: true).trifecta_legs.untrusted
      assert_equal :hard, bash(sandbox: confined).trifecta_legs.untrusted
    end

    it 'never claims the approver seat, though it holds a Confirmer' do
      # Payload visibility fails: the human approves a program, not a payload.
      # This is what keeps a coding agent over a private repo loud.
      legs = bash(sandbox: none, private: true).trifecta_legs
      assert_equal :unreviewed, legs.egress_payload_review
      refute_equal :human_reviewed, legs.egress_payload_review
    end

    it 'is a full hard trifecta over a private repo — the one loud verdict in the repo' do
      node = Pikuri::Trifecta::Node.new(
        label: 'pikuri-code',
        tool_legs: { 'bash' => bash(sandbox: none, private: true).trifecta_legs }
      )
      assert_equal :loud, Pikuri::Trifecta.walk(node).verdict
    end

    it 'goes silent over a public checkout, with the same wiring' do
      node = Pikuri::Trifecta::Node.new(
        label: 'pikuri-code',
        tool_legs: { 'bash' => bash(sandbox: none).trifecta_legs }
      )
      assert_equal :silent, Pikuri::Trifecta.walk(node).verdict
    end
  end
end
