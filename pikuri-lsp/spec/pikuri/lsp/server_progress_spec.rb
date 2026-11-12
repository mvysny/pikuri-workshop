# frozen_string_literal: true

describe Pikuri::Lsp::ServerProgress do
  it 'needs only the two fields every $/progress payload carries' do
    progress = described_class.new(server_id: 'java', title: 'Initialize Workspace')

    assert_nil progress.message
    assert_nil progress.percentage
    refute progress.done
  end

  it 'carries a fraction when the server sent one, and the terminal edge' do
    reporting = described_class.new(server_id: 'ruby', title: 'Indexing files',
                                   message: '3200/4096 files', percentage: 78)
    finished = reporting.with(message: nil, percentage: nil, done: true)

    assert_equal 78, reporting.percentage
    assert finished.done
    assert_equal 'Indexing files', finished.title
  end

  it 'is a frozen value, so a listener may keep it' do
    assert described_class.new(server_id: 'ruby', title: 'x').frozen?
  end
end
