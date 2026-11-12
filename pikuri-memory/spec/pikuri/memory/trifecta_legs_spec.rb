# frozen_string_literal: true

RSpec.describe 'recall trifecta legs' do
  let(:tool) { Pikuri::Memory::Recall.new(client: nil, user_id: 'u') }

  it 'is private by domain — durable memories about the user are sensitive by what they are' do
    assert tool.trifecta_legs.private
  end

  it 'is hard untrusted, because a memory is a stored injection with a delay fuse' do
    # Memories are captured from earlier turns: whatever an injection got the
    # agent to believe last week returns as trusted-looking recall today.
    assert_equal :hard, tool.trifecta_legs.untrusted
  end

  it 'has no egress leg' do
    assert_equal :no_egress, tool.trifecta_legs.egress_payload_review
  end
end
