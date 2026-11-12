# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'fileutils'
require 'socket'
require 'stringio'
require 'tmpdir'

describe Pikuri::Memory::Mem0Server do
  let(:cache_dir) { Dir.mktmpdir('pikuri-mem0-server-spec-') }
  after do
    @relay_sock&.close
    FileUtils.remove_entry(cache_dir)
  end

  # Stub the subprocess seam: capture every git/docker/socat invocation
  # (argv + env), return planned [exit, stdout] results in FIFO order.
  # Mirrors pikuri-vectordb's chroma_server_spec. `terminated` records
  # handles whose #terminate was called (the relay teardown path).
  let(:calls) { [] }
  let(:planned) { [] }
  let(:terminated) { [] }

  # The relay path polls File.socket? for the socket the (stubbed-out)
  # socat would have bound — bind a real one so ensure_running! proceeds.
  def fake_relay_socket!
    dir = File.join(cache_dir, 'sock')
    FileUtils.mkdir_p(dir)
    @relay_sock = UNIXServer.new(File.join(dir, 'router.sock'))
  end

  # Faraday stub for the /docs heartbeat poll.
  let(:health_stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:health_conn) do
    Faraday.new { |f| f.adapter :test, health_stubs }
  end

  before do
    calls_ref = calls
    plans_ref = planned
    term_ref = terminated

    fake_proc = Class.new do
      attr_reader :io

      def initialize(exit_status, output, term_ref)
        @exit_status = exit_status
        @output = output
        @term_ref = term_ref
        # Daemon children (the relay) hand io to a drain thread instead
        # of calling #wait; an empty StringIO EOFs the drain immediately.
        @io = StringIO.new('')
      end

      def wait
        status = Struct.new(:exitstatus) do
          def success? = exitstatus.zero?
        end.new(@exit_status)
        Struct.new(:output, :status).new(@output, status)
      end

      def terminate
        @term_ref << self
      end
    end

    Pikuri::Subprocess.singleton_class.send(:alias_method, :__orig_spawn, :spawn)
    Pikuri::Subprocess.define_singleton_method(:spawn) do |*argv, **kw|
      calls_ref << { argv: argv, env: kw[:env] || {} }
      plan = plans_ref.shift
      raise Errno::ENOENT, argv.first if plan == :enoent

      exit_status, output = plan
      fake_proc.new(exit_status, output, term_ref)
    end
  end

  after do
    Pikuri::Subprocess.singleton_class.send(:alias_method, :spawn, :__orig_spawn)
    Pikuri::Subprocess.singleton_class.send(:remove_method, :__orig_spawn)
  end

  # Track servers so the suite doesn't leave any registered with the
  # process-global Finalizers (which would fire a real `docker compose
  # down` at process exit against the unstubbed seam).
  let(:built) { [] }
  after { built.each { |s| Pikuri::Finalizers.unregister(s) } }

  def build_server(**overrides)
    server = Pikuri::Memory::Mem0Server.new(
      router_url: 'http://router:8080/v1',
      llm_model: 'qwen2.5-7b',
      embedder_model: 'nomic',
      cache_dir: cache_dir,
      healthcheck_timeout: 1,
      connection: health_conn,
      **overrides
    )
    built << server
    server
  end

  describe '#initialize / accessors' do
    it 'exposes endpoint from the port' do
      assert_equal 'http://localhost:8888', build_server.endpoint
      assert_equal 'http://localhost:9000', build_server(port: 9000).endpoint
    end

    it 'roots the checkout under <cache>/temp/git and data under <cache>/data' do
      server = build_server
      assert_equal File.join(cache_dir, 'temp', 'git'), server.checkout_dir.to_s
      assert_equal File.join(cache_dir, 'data'), server.data_dir.to_s
    end

    it 'derives a default cache dir under XDG_CACHE_HOME / pikuri / mem0' do
      assert_match(%r{/pikuri/mem0\z}, build_server.default_cache_dir)
    end
  end

  describe 'DEFAULT_QDRANT_IMAGE' do
    it "matches pikuri-vectordb's Qdrant::IMAGE, so a host running both keeps one image" do
      # The gems don't depend on each other; this guard lives on the workshop
      # side because the workshop may see pikuri, never the other way round.
      begin
        require 'pikuri-vectordb'
      rescue LoadError
        skip 'pikuri-vectordb not in this bundle'
      end

      assert_equal Pikuri::VectorDb::Server::Qdrant::IMAGE,
                   Pikuri::Memory::Mem0Server::DEFAULT_QDRANT_IMAGE
    end
  end

  describe '#client' do
    it 'returns a Mem0Client pointed at this server' do
      client = build_server(port: 9876).client
      assert_kind_of Pikuri::Memory::Mem0Client, client
      assert_equal 'http://localhost:9876', client.endpoint
    end
  end

  describe '#ensure_running!' do
    # Planned subprocess results for a fresh-checkout boot, in FIFO order.
    let(:fresh_boot_plan) do
      [
        [0, ''],   # git init
        [0, ''],   # git remote add origin
        [0, ''],   # git fetch --depth 1 origin <ref>
        [0, ''],   # git checkout --detach FETCH_HEAD
        [1, ''],   # git apply --reverse --check -> not yet applied
        [0, ''],   # git apply <patch>
        [0, ''],   # socat relay (daemon — result unused)
        [0, '']    # docker compose up -d --build
      ]
    end

    it 'clones+patches a fresh checkout, starts the relay, brings the stack up, then heartbeats' do
      planned.replace(fresh_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!

      build_server.ensure_running!

      argvs = calls.map { |c| c[:argv] }
      assert(argvs.any? { |a| a[0] == 'git' && a[1] == 'fetch' })
      assert(argvs.any? { |a| a[0] == 'git' && a[1] == 'apply' && a.last.end_with?('.patch') })
      up = argvs.find { |a| a[0] == 'docker' && a.include?('up') }
      refute_nil up
      assert_equal %w[docker compose -p pikuri-internal-mem0 -f], up[0, 5]
      assert_equal %w[up -d --build], up.last(3)
    end

    it 'spawns the host-side socat relay against router_url host:port' do
      planned.replace(fresh_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!

      build_server.ensure_running!

      socat = calls.map { |c| c[:argv] }.find { |a| a[0] == 'socat' }
      refute_nil socat
      assert_match(%r{\AUNIX-LISTEN:#{Regexp.escape(File.join(cache_dir, 'sock', 'router.sock'))},fork,unlink-early}, socat[1])
      assert_equal 'TCP:router:8080', socat[2]
    end

    it 'passes the checkout path + relay + model wiring as compose env' do
      planned.replace(fresh_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!

      build_server.ensure_running!

      up = calls.find { |c| c[:argv].include?('up') }
      env = up[:env]
      assert_equal File.join(cache_dir, 'temp', 'git'), env['PIKURI_MEM0_SRC']
      assert_equal File.join(cache_dir, 'data'), env['PIKURI_DATA_DIR']
      assert_equal File.join(cache_dir, 'sock'), env['PIKURI_SOCK_DIR']
      assert_equal Pikuri::Memory::Mem0Server::SOCAT_IMAGE, env['PIKURI_SOCAT_IMAGE']
      # The container-visible URL: the relay sidecar, with /v1 carried over.
      assert_equal 'http://router-proxy:8080/v1', env['PIKURI_ROUTER_URL']
      assert_equal 'qwen2.5-7b', env['PIKURI_LLM_MODEL']
      assert_equal 'nomic', env['PIKURI_EMBEDDER_MODEL']
      assert_equal '768', env['PIKURI_EMBEDDING_DIMS']
    end

    it 'skips the relay and uses container_router_url verbatim when given' do
      # No socat plan entry: the relay must not be spawned.
      planned.replace([[0, ''], [0, ''], [0, ''], [0, ''], [1, ''], [0, ''], [0, '']])
      health_stubs.get('/docs') { [200, {}, 'ok'] }

      build_server(container_router_url: 'http://host.docker.internal:8080/v1').ensure_running!

      refute(calls.map { |c| c[:argv] }.any? { |a| a[0] == 'socat' }, 'relay must not spawn')
      up = calls.find { |c| c[:argv].include?('up') }
      assert_equal 'http://host.docker.internal:8080/v1', up[:env]['PIKURI_ROUTER_URL']
    end

    it 'raises a socat install hint when socat is missing' do
      planned.replace([[0, ''], [0, ''], [0, ''], [0, ''], [1, ''], [0, ''], :enoent])

      err = assert_raises(RuntimeError) { build_server.ensure_running! }
      assert_match(/socat.*not found/, err.message)
    end

    it 'skips cloning when the checkout is already at the pinned ref' do
      FileUtils.mkdir_p(File.join(cache_dir, 'temp', 'git', '.git'))
      planned.replace([
                        [0, Pikuri::Memory::Mem0Server::MEM0_REF], # git rev-parse HEAD
                        [0, ''],                                   # git apply --reverse --check -> already applied
                        [0, ''],                                   # socat relay
                        [0, '']                                    # docker compose up
                      ])
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!

      build_server.ensure_running!

      argvs = calls.map { |c| c[:argv] }
      refute(argvs.any? { |a| a[0] == 'git' && a[1] == 'fetch' }, 'should not re-fetch an up-to-date checkout')
      assert(argvs.any? { |a| a[0] == 'docker' && a.include?('up') })
    end

    it 'raises fail-loud when the patch neither applies nor is present' do
      planned.replace([
                        [0, ''], [0, ''], [0, ''], [0, ''], # clone steps
                        [1, ''],                            # reverse --check -> not applied
                        [1, 'patch does not apply']         # git apply -> fails
                      ])

      err = assert_raises(RuntimeError) { build_server.ensure_running! }
      assert_match(/failed to apply/, err.message)
    end

    it 'raises on healthcheck timeout and self-heals the relay' do
      planned.replace(fresh_boot_plan)
      health_stubs.get('/docs') { [503, {}, 'starting'] }
      fake_relay_socket!

      err = assert_raises(RuntimeError) { build_server.ensure_running! }
      assert_match(/did not become healthy/, err.message)
      assert_equal 1, terminated.size, 'the relay must not be left as a stray'
    end
  end

  describe '#initialize relay guard' do
    it 'rejects a non-http router_url without container_router_url' do
      err = assert_raises(ArgumentError) { build_server(router_url: 'https://router:8443/v1') }
      assert_match(/must be http/, err.message)
    end

    it 'accepts a non-http router_url when container_router_url is given' do
      build_server(router_url: 'https://router:8443/v1',
                   container_router_url: 'https://router:8443/v1')
    end
  end

  describe '#close' do
    it 'runs docker compose down, stops the relay, and is idempotent' do
      planned.replace([[0, ''], [0, ''], [0, ''], [0, ''], [1, ''], [0, ''], [0, ''], [0, '']])
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!
      server = build_server
      server.ensure_running!

      planned.replace([[0, '']]) # docker compose down
      server.close
      server.close # no second down

      downs = calls.select { |c| c[:argv].include?('down') }
      assert_equal 1, downs.size
      assert_equal %w[docker compose], downs.first[:argv][0, 2]
      assert_equal 1, terminated.size, 'close must terminate the relay exactly once'
    end
  end
end
