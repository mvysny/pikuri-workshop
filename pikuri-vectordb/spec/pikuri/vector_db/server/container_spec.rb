# frozen_string_literal: true

require 'spec_helper'
require 'faraday'

# The generic container-lifecycle behaviour — reuse-or-recreate,
# healthcheck polling, loud boot / quiet teardown — is tested here
# once, against arbitrary engine parameters. The Server::Qdrant spec
# only covers its engine-specific wiring.
describe Pikuri::VectorDb::Server::Container do
  include_context 'container stub'

  HEADERS = { 'Content-Type' => 'application/json' }.freeze

  def build_container(**overrides)
    Pikuri::VectorDb::Server::Container.new(
      name: 'pikuri-internal-test',
      image: 'example/engine:1.2.3',
      label: 'pikuri.internal=true',
      host_port: 4567,
      container_port: 7654,
      volume: '/host/data:/container/data',
      health_path: '/health',
      healthcheck_timeout: 1,
      connection: heartbeat_conn,
      **overrides
    )
  end

  describe '#endpoint' do
    it 'is built from the host port' do
      assert_equal 'http://localhost:4567', build_container.endpoint
    end
  end

  describe '#ensure_running!' do
    it 'creates the container when missing, then heartbeats' do
      planned_results.replace([
                                [1, ''],                 # docker inspect → missing
                                [0, 'container-id-abc']  # docker run → ok
                              ])
      heartbeat_stubs.get('/health') { [200, HEADERS, '{}'] }

      build_container.ensure_running!

      inspect_argv, run_argv = docker_calls
      assert_equal %w[docker inspect --format], inspect_argv[0..2]
      assert_equal 'pikuri-internal-test', inspect_argv.last
      assert_equal 'docker', run_argv[0]
      assert_equal 'run',    run_argv[1]
      assert_includes run_argv, '-d'
      assert_includes run_argv, 'example/engine:1.2.3'
      assert_includes run_argv, '--label'
      assert_includes run_argv, 'pikuri.internal=true'
      # 127.0.0.1 binding, not the docker default 0.0.0.0 — the
      # publish string is built here, the single enforcement point.
      port_publish = run_argv[run_argv.index('-p') + 1]
      assert_equal '127.0.0.1:4567:7654', port_publish
      volume_arg = run_argv[run_argv.index('-v') + 1]
      assert_equal '/host/data:/container/data', volume_arg
    end

    it 'removes and recreates a pre-existing stopped container' do
      # The container is disposable; the data lives on the volume.
      # A stopped container is nuked and recreated, not adopted.
      planned_results.replace([
                                [0, "false\n"],          # inspect → stopped
                                [0, ''],                 # docker rm -f
                                [0, 'container-id-new']  # docker run
                              ])
      heartbeat_stubs.get('/health') { [200, HEADERS, '{}'] }

      build_container.ensure_running!

      assert_equal %w[inspect rm run], docker_calls.map { |c| c[1] }
    end

    it 'reclaims a pre-existing running container instead of adopting it' do
      # A container found running that this instance did not start is
      # not trusted: remove and recreate against the persistent volume.
      planned_results.replace([
                                [0, "true\n"],          # inspect → running (not ours)
                                [0, ''],                # docker rm -f
                                [0, 'container-id-new'] # docker run
                              ])
      heartbeat_stubs.get('/health') { [200, HEADERS, '{}'] }

      build_container.ensure_running!

      assert_equal %w[inspect rm run], docker_calls.map { |c| c[1] }
    end

    it 'does not recreate a container it started earlier in the same process' do
      # First call creates it; the second sees it running and, because
      # this instance now owns it, reuses it (no rm/run).
      planned_results.replace([
                                [1, ''],                 # inspect → missing
                                [0, 'container-id-abc'], # docker run
                                [0, "true\n"]            # inspect → running (ours)
                              ])
      heartbeat_stubs.get('/health') { [200, HEADERS, '{}'] }

      container = build_container
      container.ensure_running!
      container.ensure_running!

      assert_equal %w[inspect run inspect], docker_calls.map { |c| c[1] }
    end

    it 'raises a clear error when docker is not on PATH' do
      planned_results.replace([:enoent])

      err = assert_raises(RuntimeError) { build_container.ensure_running! }
      assert_match(/neither `podman` nor `docker` found on PATH/, err.message)
    end

    it 'raises with the docker output when `docker run` fails' do
      planned_results.replace([
                                [1, ''],
                                [125, "docker: Error response from daemon: port already allocated\n"]
                              ])

      err = assert_raises(RuntimeError) { build_container.ensure_running! }
      assert_match(/pikuri-internal-test: docker run failed/, err.message)
      assert_match(/port already allocated/, err.message)
    end

    it 'raises when heartbeat never returns 200 within the timeout' do
      planned_results.replace([
                                [1, ''],   # inspect → missing
                                [0, 'cid'] # docker run ok
                              ])
      heartbeat_stubs.get('/health') { [503, HEADERS, '{}'] }

      err = assert_raises(RuntimeError) { build_container.ensure_running! }
      assert_match(/did not become healthy/, err.message)
      assert_match(/HTTP 503/, err.message)
    end

    it 'tolerates Faraday connection errors during the warmup window' do
      planned_results.replace([
                                [1, ''],   # missing
                                [0, 'cid'] # docker run ok
                              ])
      # First call: connection refused; second call: 200. The poll
      # must keep going on a Faraday::Error rather than aborting.
      call_n = 0
      heartbeat_stubs.get('/health') do
        call_n += 1
        call_n == 1 ? raise(Faraday::ConnectionFailed, 'refused') : [200, HEADERS, '{}']
      end

      build_container.ensure_running!
      assert call_n >= 2, 'heartbeat must be polled past the first connection refusal'
    end
  end

  describe '#close' do
    def start_then(*plans)
      planned_results.replace([[1, ''], [0, 'container-id-abc'], *plans]) # missing → run, then ...
      heartbeat_stubs.get('/health') { [200, HEADERS, '{}'] }
      container = build_container
      container.ensure_running!
      container
    end

    it 'docker-removes the container it started' do
      container = start_then([0, ''])
      container.close
      assert_equal %w[inspect run rm], docker_calls.map { |c| c[1] }
      assert_includes docker_calls.last, '-f'
      assert_equal 'pikuri-internal-test', docker_calls.last.last
    end

    it 'is idempotent — a second close issues no further docker rm' do
      container = start_then([0, ''])
      container.close
      container.close
      assert_equal 1, docker_calls.count { |c| c[1] == 'rm' }
    end

    it 'is a no-op when this instance never started a container' do
      build_container.close
      assert_empty docker_calls
    end

    it 'logs rather than raises when docker rm fails' do
      container = start_then([137, 'No such container: pikuri-internal-test'])
      container.close # must not raise even though rm exits non-zero
      assert_equal 'rm', docker_calls.last[1]
    end

    it 'can be reopened: ensure_running! after close re-arms close' do
      container = start_then([0, '']) # rm for the close
      container.close

      planned_results.replace([
                                [1, ''],   # inspect → missing (we removed it)
                                [0, 'cid'], # docker run
                                [0, '']    # rm for the second close
                              ])
      container.ensure_running!
      container.close

      assert_equal 2, docker_calls.count { |c| c[1] == 'rm' }
    end
  end
end
