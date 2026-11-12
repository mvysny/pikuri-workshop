# frozen_string_literal: true

# bin/pikuri-os and bin/pikuri-computer declare their AllowAll workspace
# `private: true`, because the disk they reach is the user's actual machine.
# The file-index tools already hardcode that leg on the same reasoning
# (see trifecta_legs_spec.rb); these assertions keep the *file* tools from
# drifting back to disagreeing with them about the very same disk.
RSpec.describe 'whole-machine workspace is private' do
  def allow_all(**flags)
    Pikuri::Workspace::Filesystem::AllowAll.new(project_root: Dir.pwd, denylist: [], **flags)
  end

  it 'marks reads over a declared-private AllowAll as touching private data' do
    ws = Pikuri::Workspace::Workspace.new(filesystem: allow_all(private: true))
    legs = Pikuri::Workspace::Read.new(workspace: ws).trifecta_legs

    assert legs.private, 'read over the whole machine must carry the private leg'
    assert_equal :hard, legs.untrusted, 'AllowAll cannot be vouched for'
  end

  it 'agrees with what the file-index tools already declare about the same disk' do
    backend = Module.new do
      def self.check_binaries!; end
      def self.limitations = ''
    end
    ws = Pikuri::Workspace::Workspace.new(filesystem: allow_all(private: true))

    assert_equal Pikuri::Os::FileindexSearch.new(backend: backend).trifecta_legs.private,
                 Pikuri::Workspace::Read.new(workspace: ws).trifecta_legs.private
  end

  it 'still refuses trusted: on AllowAll — a whole-machine root cannot be vouched for' do
    assert_raises(ArgumentError) { allow_all(private: true, trusted: true) }
  end

  it 'leaves the verdicts alone — this was an attribution fix, not a severity one' do
    # fileindex already supplied the private leg, so declaring the workspace
    # private changes *who is named*, not what is concluded. Pinned so a future
    # reader does not mistake the declaration for a severity change.
    backend = Module.new do
      def self.check_binaries!; end
      def self.limitations = ''
    end
    verdicts = [false, true].map do |declared|
      ws = Pikuri::Workspace::Workspace.new(filesystem: allow_all(private: declared))
      tools = { 'read' => Pikuri::Workspace::Read.new(workspace: ws).trifecta_legs,
                'fileindex_search' => Pikuri::Os::FileindexSearch.new(backend: backend).trifecta_legs }
      Pikuri::Trifecta.walk(
        Pikuri::Trifecta::Node.new(label: 'pikuri-os', tool_legs: tools)
      ).tree_verdict
    end

    assert_equal %i[silent silent], verdicts, 'no egress leg: silent either way'
  end
end
