# frozen_string_literal: true

require 'faraday'

# Shared stubbing for specs exercising the docker-shaped supervisors
# (Server::Container and the engine supervisors composing it).
#
# Stubs the subprocess seam: captures every docker invocation in
# +docker_calls+, returns +planned_results+ in FIFO order. Each
# planned result is +[exit_status, stdout]+ for the next +.wait+;
# +:enoent+ raises +Errno::ENOENT+ to simulate `docker` missing.
# Also provides +heartbeat_conn+, a Faraday test connection for the
# healthcheck poll, with expectations stubbed on +heartbeat_stubs+.
RSpec.shared_context 'container stub' do
  let(:docker_calls) { [] }
  let(:planned_results) { [] }

  let(:heartbeat_stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:heartbeat_conn) do
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter :test, heartbeat_stubs
    end
  end

  before do
    calls_ref = docker_calls
    plans_ref = planned_results

    fake_proc_class = Class.new do
      def initialize(exit_status, output)
        @exit_status = exit_status
        @output = output
      end

      def wait
        status = Struct.new(:exitstatus) do
          def success?
            exitstatus.zero?
          end
        end.new(@exit_status)
        Struct.new(:output, :status).new(@output, status)
      end
    end

    # Pin the CLI so argv assertions hold on a host with podman installed.
    container = Pikuri::VectorDb::Server::Container
    container.singleton_class.send(:alias_method, :__orig_runtime, :runtime)
    container.define_singleton_method(:runtime) { 'docker' }

    Pikuri::Subprocess.singleton_class.send(:alias_method, :__orig_spawn, :spawn)
    Pikuri::Subprocess.define_singleton_method(:spawn) do |*argv, **_kw|
      calls_ref << argv
      plan = plans_ref.shift
      raise Errno::ENOENT, 'docker' if plan == :enoent

      exit_status, output = plan
      fake_proc_class.new(exit_status, output)
    end
  end

  after do
    container = Pikuri::VectorDb::Server::Container
    container.singleton_class.send(:alias_method, :runtime, :__orig_runtime)
    container.singleton_class.send(:remove_method, :__orig_runtime)
    Pikuri::Subprocess.singleton_class.send(:alias_method, :spawn, :__orig_spawn)
    Pikuri::Subprocess.singleton_class.send(:remove_method, :__orig_spawn)
  end
end
