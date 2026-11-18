# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'fileutils'
require 'tmpdir'

# Engine-specific wiring only — the generic container lifecycle
# (reuse-or-recreate, healthcheck polling, close semantics) is
# covered once in the Server::Container spec.
describe Pikuri::VectorDb::Server::Qdrant do
  include_context 'container stub'

  # Qdrant's /healthz answers text/plain, not JSON — the heartbeat
  # stubs mirror that so the json response middleware is exercised
  # against the real content type.
  TEXT_HEADERS = { 'Content-Type' => 'text/plain; charset=utf-8' }.freeze

  let(:data_dir) { Dir.mktmpdir('pikuri-qdrant-server-spec-') }
  after { FileUtils.remove_entry(data_dir) }

  # Unregister built servers from the process-global Finalizers
  # after each example.
  let(:built_servers) { [] }
  after { built_servers.each { |s| Pikuri::Finalizers.unregister(s) } }

  def build_server(**overrides)
    server = Pikuri::VectorDb::Server::Qdrant.new(
      data_dir: data_dir,
      port: 6333,
      healthcheck_timeout: 1,
      connection: heartbeat_conn,
      **overrides
    )
    built_servers << server
    server
  end

  describe '#initialize' do
    it 'expands data_dir' do
      server = Pikuri::VectorDb::Server::Qdrant.new(data_dir: '~/x', port: 6333)
      assert_equal File.expand_path('~/x'), server.data_dir.to_s
    end

    it 'derives default data_dir under XDG_CACHE_HOME / pikuri / qdrant' do
      server = Pikuri::VectorDb::Server::Qdrant.new
      assert_match(%r{/pikuri/qdrant\z}, server.default_data_dir)
    end

    it 'exposes endpoint built from port' do
      server = Pikuri::VectorDb::Server::Qdrant.new(port: 9999)
      assert_equal 'http://localhost:9999', server.endpoint
    end
  end

  describe '#client' do
    it 'returns a Backend::Qdrant pointed at this server' do
      server = Pikuri::VectorDb::Server::Qdrant.new(port: 9876)
      client = server.client(collection: 'guide')
      assert_kind_of Pikuri::VectorDb::Backend::Qdrant, client
    end
  end

  describe '#ensure_running!' do
    it 'wires qdrant identity into the docker run and polls /healthz' do
      planned_results.replace([
                                [1, ''],                 # docker inspect → missing
                                [0, 'container-id-abc']  # docker run → ok
                              ])
      heartbeat_calls = 0
      heartbeat_stubs.get('/healthz') do
        heartbeat_calls += 1
        [200, TEXT_HEADERS, 'healthz check passed']
      end

      build_server.ensure_running!

      inspect_argv, run_argv = docker_calls
      assert_equal Pikuri::VectorDb::Server::Qdrant::CONTAINER_NAME, inspect_argv.last
      assert_includes run_argv, Pikuri::VectorDb::Server::Qdrant::IMAGE
      assert_includes run_argv, Pikuri::VectorDb::Server::Qdrant::LABEL
      # Qdrant's native REST port, bound to 127.0.0.1
      port_publish = run_argv[run_argv.index('-p') + 1]
      assert_equal '127.0.0.1:6333:6333', port_publish
      # Bind-mount → /qdrant/storage (the image's storage root)
      volume_arg = run_argv[run_argv.index('-v') + 1]
      assert_equal "#{data_dir}:#{Pikuri::VectorDb::Server::Qdrant::CONTAINER_PERSIST_DIR}",
                   volume_arg
      assert heartbeat_calls >= 1, 'must heartbeat-poll the qdrant health path'
    end

    it 'registers itself once with Pikuri::Finalizers across repeated ensure_running!' do
      saved = Pikuri::Finalizers.instance_variable_get(:@registered)
      Pikuri::Finalizers.instance_variable_set(:@registered, [])
      begin
        planned_results.replace([
                                  [1, ''], [0, 'cid'], # 1st ensure: missing → run
                                  [0, "true\n"]        # 2nd ensure: running (ours)
                                ])
        heartbeat_stubs.get('/healthz') { [200, TEXT_HEADERS, 'healthz check passed'] }

        server = build_server
        server.ensure_running!
        server.ensure_running!

        registered = Pikuri::Finalizers.instance_variable_get(:@registered)
        assert_equal [server], registered
      ensure
        Pikuri::Finalizers.instance_variable_set(:@registered, saved)
      end
    end
  end

  describe '#close' do
    it 'docker-removes the container it started' do
      planned_results.replace([[1, ''], [0, 'container-id-abc'], [0, '']])
      heartbeat_stubs.get('/healthz') { [200, TEXT_HEADERS, 'healthz check passed'] }

      server = build_server
      server.ensure_running!
      server.close

      assert_equal %w[inspect run rm], docker_calls.map { |c| c[1] }
      assert_includes docker_calls.last, '-f'
      assert_equal Pikuri::VectorDb::Server::Qdrant::CONTAINER_NAME, docker_calls.last.last
    end
  end
end
