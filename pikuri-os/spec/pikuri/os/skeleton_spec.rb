# frozen_string_literal: true

# Skeleton smoke test: the gem requires cleanly, defines its namespace,
# and pulls its sibling dependencies. Real per-component specs land
# alongside each piece as it's added (LocalSearch tool, MACHINE.md
# memory, boot grounding).
describe 'pikuri-os skeleton' do
  it 'defines the Pikuri::Os namespace' do
    assert defined?(Pikuri::Os), 'Pikuri::Os should be defined after require'
    assert_kind_of Module, Pikuri::Os
  end

  it 'mounts its own Zeitwerk loader tagged pikuri-os' do
    assert_equal 'pikuri-os', Pikuri::Os::LOADER.tag
  end

  it 'loads its sibling dependencies into the shared namespace' do
    # pikuri-code (Bash + sandbox) is the load-bearing dependency that
    # distinguishes this gem from a bare pikuri-core agent.
    assert defined?(Pikuri::Code::Bash), 'pikuri-code should be required'
    assert defined?(Pikuri::Workspace), 'pikuri-workspace should be required'
  end
end
