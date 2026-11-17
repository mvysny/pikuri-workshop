# frozen_string_literal: true

RSpec.describe 'file-index tool trifecta legs' do
  # A backend stub: the constructor splices its limitations into the
  # description, which these assertions don't care about.
  let(:backend) do
    Module.new do
      def self.limitations = ''
    end
  end

  it 'fixes both inbound legs — whole-machine reach is the whole-disk case by construction' do
    [Pikuri::Os::FileindexSearch.new(backend: backend),
     Pikuri::Os::FileindexRead.new(backend: backend)].each do |tool|
      assert tool.trifecta_legs.private, tool.name
      assert_equal :hard, tool.trifecta_legs.untrusted, tool.name
      assert_equal :no_egress, tool.trifecta_legs.egress_payload_review, tool.name
    end
  end
end
