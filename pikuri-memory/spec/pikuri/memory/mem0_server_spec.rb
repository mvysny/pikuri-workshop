# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'fileutils'
require 'json'
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
  # Mirrors pikuri-vectordb's qdrant_spec. `terminated` records
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

  # Faraday stub for the embedder probe; answers a 3-wide vector unless a
  # test plans otherwise. `probes` records each request's headers.
  let(:probes) { [] }
  let(:probe_reply) { [200, { 'data' => [{ 'embedding' => [0.1, 0.2, 0.3] }] }] }
  let(:router_stubs) do
    probes_ref = probes
    reply = probe_reply
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('/v1/embeddings') do |env|
        probes_ref << { headers: env.request_headers, body: JSON.parse(env.request_body) }
        [reply[0], {}, JSON.generate(reply[1])]
      end
    end
  end
  let(:router_conn) do
    Faraday.new(url: 'http://router:8080/v1') { |f| f.adapter :test, router_stubs }
  end

  def build_server(**overrides)
    server = Pikuri::Memory::Mem0Server.new(
      router_url: 'http://router:8080/v1',
      extraction_model: described_class::ExtractionModel.new(
        name: 'qwen2.5-7b', params: { chat_template_kwargs: { enable_thinking: false } }
      ),
      embedder_model: 'nomic',
      cache_dir: cache_dir,
      healthcheck_timeout: 1,
      connection: health_conn,
      router_connection: router_conn,
      runtime: 'docker',
      **overrides
    )
    built << server
    server
  end

  # Planned subprocess results for a fresh-checkout boot, in FIFO order.
  let(:fresh_boot_plan) do
    [
      [0, ''],   # git init
      [0, ''],   # git remote add origin
      [0, ''],   # git fetch --depth 1 origin <ref>
      [0, ''],   # git checkout --detach FETCH_HEAD
      [1, ''],   # git apply --reverse --check qdrant patch -> not yet applied
      [0, ''],   # git apply qdrant patch
      [1, ''],   # git apply --reverse --check extra-body patch -> not yet applied
      [0, ''],   # git apply extra-body patch
      [0, ''],   # socat relay (daemon — result unused)
      [0, '']    # docker compose up -d --build
    ]
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
      # Neither gem depends on the other; the spec reaches vectordb through
      # the monorepo's top-level Gemfile.
      require 'pikuri-vectordb'

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
      assert_equal '{"chat_template_kwargs":{"enable_thinking":false}}', env['PIKURI_LLM_EXTRA_BODY']
      assert_equal 'nomic', env['PIKURI_EMBEDDER_MODEL']
      assert_equal Pikuri::Memory::Mem0Server::NO_API_KEY, env['PIKURI_ROUTER_API_KEY']
    end

    it 'applies both shipped patches, the extra-body one last' do
      planned.replace(fresh_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!

      build_server.ensure_running!

      applied = calls.map { |c| c[:argv] }.select { |a| a[0, 2] == %w[git apply] && a[2] != '--reverse' }
      assert_equal %w[qdrant-default-config.patch llm-extra-body.patch], applied.map { |a| File.basename(a.last) }
    end

    it 'sends no extra body for an extraction model without params' do
      planned.replace(fresh_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!

      build_server(extraction_model: described_class::ExtractionModel.new(name: 'qwen2.5-7b')).ensure_running!

      up = calls.find { |c| c[:argv].include?('up') }
      assert_equal '', up[:env]['PIKURI_LLM_EXTRA_BODY']
    end

    it "sizes the collection from the embedder's own vector" do
      planned.replace(fresh_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!

      build_server.ensure_running!

      assert_equal 1, probes.size
      assert_equal 'nomic', probes.first[:body]['model']
      refute probes.first[:headers].key?('Authorization'), 'no key, no Authorization header'
      up = calls.find { |c| c[:argv].include?('up') }
      assert_equal '3', up[:env]['PIKURI_EMBEDDING_DIMS']
    end

    it 'sends the router key with the probe and into the stack' do
      planned.replace(fresh_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!

      build_server(api_key: 'sk-local-1234').ensure_running!

      assert_equal 'Bearer sk-local-1234', probes.first[:headers]['Authorization']
      up = calls.find { |c| c[:argv].include?('up') }
      assert_equal 'sk-local-1234', up[:env]['PIKURI_ROUTER_API_KEY']
    end

    it 'skips the probe when embedding_dims is given' do
      planned.replace(fresh_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!

      build_server(embedding_dims: 1024).ensure_running!

      assert_empty probes
      up = calls.find { |c| c[:argv].include?('up') }
      assert_equal '1024', up[:env]['PIKURI_EMBEDDING_DIMS']
    end

    describe 'when the router refuses the probe' do
      let(:probe_reply) { [401, { 'error' => { 'message' => 'Invalid API Key' } }] }

      it 'raises with the reply, before touching git or docker' do
        err = assert_raises(RuntimeError) { build_server.ensure_running! }
        assert_match(/probing embedder "nomic".*HTTP 401.*Invalid API Key/, err.message)
        assert_empty calls
      end
    end

    it 'raises when the stored collection was embedded at another size' do
      dir = File.join(cache_dir, 'data', 'qdrant', 'collections', 'pikuri_memory')
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'config.json'), JSON.generate('params' => { 'vectors' => { 'size' => 768 } }))

      err = assert_raises(RuntimeError) { build_server.ensure_running! }
      assert_match(/embedded 768 wide, but "nomic" embeds 3 wide/, err.message)
      assert_empty calls
    end

    it 'boots over a stored collection of the same size' do
      dir = File.join(cache_dir, 'data', 'qdrant', 'collections', 'pikuri_memory')
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'config.json'), JSON.generate('params' => { 'vectors' => { 'size' => 3 } }))
      planned.replace(fresh_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!

      build_server.ensure_running!

      assert(calls.any? { |c| c[:argv].include?('up') })
    end

    it 'raises a socat install hint when socat is missing' do
      planned.replace([[0, ''], [0, ''], [0, ''], [0, ''], [1, ''], [0, ''], [1, ''], [0, ''], :enoent])

      err = assert_raises(RuntimeError) { build_server.ensure_running! }
      assert_match(/socat.*not found/, err.message)
    end

    it 'skips cloning when the checkout is already at the pinned ref' do
      FileUtils.mkdir_p(File.join(cache_dir, 'temp', 'git', '.git'))
      planned.replace([
                        [0, Pikuri::Memory::Mem0Server::MEM0_REF], # git rev-parse HEAD
                        [0, ''],                                   # qdrant patch: already applied
                        [0, ''],                                   # extra-body patch: already applied
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

  describe 'on podman' do
    # The (stubbed-out) podman service would have bound its socket.
    def fake_podman_socket!
      dir = File.join(cache_dir, 'podman')
      FileUtils.mkdir_p(dir)
      @podman_sock = UNIXServer.new(File.join(dir, 'podman.sock'))
    end
    after { @podman_sock&.close }

    let(:podman_boot_plan) { fresh_boot_plan.insert(-2, [0, '']) } # podman service, before compose up

    it 'runs a private podman service and points compose at it' do
      planned.replace(podman_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!
      fake_podman_socket!

      build_server(runtime: 'podman').ensure_running!

      argvs = calls.map { |c| c[:argv] }
      sock = File.join(cache_dir, 'podman', 'podman.sock')
      assert_includes argvs, ['podman', 'system', 'service', '--time=0', "unix://#{sock}"]
      up = argvs.find { |a| a.include?('up') }
      assert_equal ['podman', '--url', "unix://#{sock}", 'compose', '-p', 'pikuri-internal-mem0'], up[0, 6]
    end

    it 'keeps the podman socket out of the directory containers mount' do
      server = build_server(runtime: 'podman')
      refute_equal server.sock_dir, server.podman_dir
      refute server.podman_dir.to_s.start_with?("#{server.sock_dir}/")
    end

    it 'stops the podman service after compose down' do
      planned.replace(podman_boot_plan)
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      fake_relay_socket!
      fake_podman_socket!
      server = build_server(runtime: 'podman')
      server.ensure_running!

      planned.replace([[0, '']]) # podman compose down
      server.close

      down = calls.find { |c| c[:argv].include?('down') }
      assert_equal %w[podman --url], down[:argv][0, 2]
      assert_equal 2, terminated.size, 'close must stop the podman service and the relay'
    end

    it 'stops the podman service and the relay when the stack never comes up' do
      planned.replace(podman_boot_plan)
      health_stubs.get('/docs') { [503, {}, 'starting'] }
      fake_relay_socket!
      fake_podman_socket!

      assert_raises(RuntimeError) { build_server(runtime: 'podman').ensure_running! }
      assert_equal 2, terminated.size, 'no daemon may be left as a stray'
    end
  end

  describe 'ExtractionModel' do
    it 'rejects params that are not a Hash' do
      err = assert_raises(ArgumentError) do
        described_class::ExtractionModel.new(name: 'm', params: 'enable_thinking=false')
      end
      assert_match(/params must be a Hash, got String/, err.message)
    end
  end

  describe '#initialize relay guard' do
    it 'rejects a non-http router_url' do
      err = assert_raises(ArgumentError) { build_server(router_url: 'https://router:8443/v1') }
      assert_match(/must be http/, err.message)
    end
  end

  describe '#close' do
    it 'runs docker compose down, stops the relay, and is idempotent' do
      planned.replace(fresh_boot_plan)
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
