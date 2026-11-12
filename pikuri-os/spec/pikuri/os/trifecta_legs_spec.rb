# frozen_string_literal: true

RSpec.describe 'file-index tool trifecta legs' do
  # A backend stub: the constructors probe for the search binary and splice its
  # limitations into the description, neither of which these assertions care
  # about.
  let(:backend) do
    Module.new do
      def self.check_binaries!; end
      def self.limitations = ''
    end
  end

  it 'fixes both inbound legs — whole-machine reach is the AllowAll case by construction' do
    [Pikuri::Os::FileindexSearch.new(backend: backend),
     Pikuri::Os::FileindexRead.new(backend: backend)].each do |tool|
      assert tool.trifecta_legs.private, tool.name
      assert_equal :hard, tool.trifecta_legs.untrusted, tool.name
      assert_equal :no_egress, tool.trifecta_legs.egress_payload_review, tool.name
    end
  end
end
