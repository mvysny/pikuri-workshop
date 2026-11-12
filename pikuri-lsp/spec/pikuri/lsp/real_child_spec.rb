# frozen_string_literal: true

require 'rbconfig'
require 'tmpdir'

# The spawn leg, against a real child process that really speaks LSP.
#
# {Pikuri::Lsp::Testing::FakeServer} covers framing, demux and the value types
# in-process over +IO.pipe+, and cannot cover any of this: argv/env/cwd actually
# reaching a child, a real handshake, a real pid, a real death, a real process
# group, a real reap. That is the whole reason
# {Pikuri::Lsp::ClientWrapper} is a documented +Subprocess+ seam exception — and
# the dummy is ours, so it can be *told* to die, which no real server can.
describe 'Pikuri::Lsp::ClientWrapper over a real child' do
  server = File.expand_path('../../support/fake_lsp_server', __dir__)

  entry = lambda do |flags: [], env: {}, id: 'fake'|
    Pikuri::Lsp::Registry::StdioEntry.new(
      id: id, command: [RbConfig.ruby, server, *flags], files: %w[*.rb], env: env
    )
  end

  spawned = lambda do |the_entry = entry.call, root: Dir.pwd, &block|
    client = Pikuri::Lsp::ClientWrapper.spawn(the_entry, root: root)
    begin
      Timeout.timeout(20) { block.call(client) }
    ensure
      client.close
    end
  end

  it 'hand-shakes with a real process and reads the capabilities off it' do
    spawned.call do |client|
      assert client.supports?('definitionProvider')
      refute client.supports?('typeHierarchyProvider')
      assert_equal 'utf-8', client.position_encoding
      assert client.pid.positive?
    end
  end

  it 'hands the child its cwd and its env, which only a real spawn can prove' do
    Dir.mktmpdir('pikuri-lsp-child-') do |root|
      real_root = File.realpath(root)
      spawned.call(entry.call(env: { 'PIKURI_FAKE_MARKER' => 'from-the-entry' }),
                   root: real_root) do |client|
        answer = client.request('pikuri/environment', {})

        assert_equal real_root, answer['cwd']
        assert_equal 'from-the-entry', answer['marker']
      end
    end
  end

  it 'de-bundlerizes the child, or ruby-lsp resolves out of pikuri\'s own bundle' do
    skip 'not running under bundler' unless ENV['BUNDLE_GEMFILE']

    spawned.call do |client|
      assert_nil client.request('pikuri/environment', {})['bundle_gemfile']
    end
  end

  it 'lets the entry\'s own env win over the de-bundlerizing correction' do
    skip 'not running under bundler' unless ENV['BUNDLE_GEMFILE']

    spawned.call(entry.call(env: { 'BUNDLE_GEMFILE' => '/mine/Gemfile' })) do |client|
      assert_equal '/mine/Gemfile', client.request('pikuri/environment', {})['bundle_gemfile']
    end
  end

  it 'carries a request and its reply across the pipe pair' do
    spawned.call do |client|
      uri = 'file:///tmp/read.rb'
      answer = client.request('textDocument/definition', { textDocument: { uri: uri } })

      assert_equal uri, answer['uri']
      assert_equal 6, answer.dig('range', 'start', 'character')
    end
  end

  it 'relays a real server refusal rather than treating it as an answer' do
    spawned.call do |client|
      assert_raises(Pikuri::Lsp::Connection::ServerError) { client.request('textDocument/rename', {}) }
    end
  end

  it 'respawns a genuinely dead child and retries the call on the new process' do
    Dir.mktmpdir('pikuri-lsp-die-') do |dir|
      # Only the first generation dies, and it dies instead of answering the
      # call below — so what is asserted is a *successful* retry.
      flags = ['--die-once', File.join(dir, 'died')]
      spawned.call(entry.call(flags: flags)) do |client|
        first_pid = client.pid

        answer = client.request('pikuri/environment', {})

        refute_nil answer
        refute_equal first_pid, client.pid, 'a restart means a new process, not a reconnect'
        assert_raises(Errno::ESRCH) { Process.kill(0, first_pid) }
      end
    end
  end

  it 'reports a child that dies with its own last words on stderr' do
    the_entry = entry.call(flags: ['--die-after', '2', '--stderr', 'fake: out of memory'])
    client = Pikuri::Lsp::ClientWrapper.spawn(the_entry, root: Dir.pwd,
                                              cancellable: nil)
    begin
      # Every respawn dies the same way, so the retries are spent and the last
      # death is reported.
      error = assert_raises(Pikuri::Lsp::ClientWrapper::ServerDied) do
        Timeout.timeout(20) { client.request('pikuri/environment', {}) }
      end

      assert_includes error.message, 'fake: out of memory'
    ensure
      client.close
    end
  end

  it 'reaps the child on close, so nothing is left behind' do
    client = Pikuri::Lsp::ClientWrapper.spawn(entry.call, root: Dir.pwd)
    pid = client.pid
    client.close

    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  it 'takes a forked helper down with the process group' do
    Dir.mktmpdir('pikuri-lsp-helper-') do |dir|
      # The helper reports its own pid: a plain kill on the leader would leave it
      # running, and the process group is what +pgroup: true+ bought.
      pid_file = File.join(dir, 'helper.pid')
      client = Pikuri::Lsp::ClientWrapper.spawn(entry.call(flags: ['--fork-helper', pid_file]),
                                                root: Dir.pwd)
      helper = Integer(File.read(pid_file))

      assert alive?(helper), 'the dummy was asked to fork a helper'
      client.close

      assert wait_until { !alive?(helper) }, "helper #{helper} outlived the group"
    end
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # SIGTERM delivery is asynchronous, so the assertion polls rather than sleeps.
  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      return true if yield

      sleep 0.05
    end
    false
  end
end
