# frozen_string_literal: true

require 'pikuri/testing'

require 'pathname'

RSpec.describe Pikuri::Os::Extension do
  let(:filesystem) { Pikuri::Code::WholeDisk.new(project_root: Dir.pwd) }
  let(:human) { Pikuri::Workspace::Confirmer::AutoApprove.new }

  # Deterministic stand-ins so the spec doesn't depend on inxi / a real
  # MACHINE.md / a file index for the prompt assertions.
  let(:system_info) do
    Object.new.tap { |o| o.define_singleton_method(:prompt_section) { "# This machine\n\n- OS: TestOS" } }
  end
  let(:memory) do
    Object.new.tap do |o|
      o.define_singleton_method(:prompt_section) { nil } # nothing recorded → affordance path
      o.define_singleton_method(:path) { Pathname.new('/cfg/pikuri/MACHINE.md') }
    end
  end

  # A file-index backend satisfying the duck type the fileindex tools need,
  # without spawning any real indexer.
  def stub_backend(available:, label: 'stub')
    Module.new do
      define_singleton_method(:unavailable_reason) { available ? nil : "#{label} is not ready" }
      define_singleton_method(:limitations)        { 'STUB LIMITS' }
      define_singleton_method(:label)              { label }
    end
  end

  def build_configurator = Pikuri::Testing.configurator

  def with_singleton(obj, name)
    original = obj.method(name)
    yield original
  ensure
    obj.define_singleton_method(name, original)
  end

  def configure!(c, plan_mode: nil, backends: [stub_backend(available: true)])
    ext = described_class.new(
      filesystem: filesystem, confirmer: human, plan_mode: plan_mode,
      memory: memory, system_info: system_info, file_index_backends: backends
    )
    ext.configure(c)
    ext
  end

  it 'is an Agent::Extension by composition' do
    assert_kind_of Pikuri::Agent::Extension,
                   described_class.new(filesystem: filesystem, confirmer: human)
  end

  describe '#configure when a file-index backend is usable' do
    it 'wires the file tools, bash, and both file-index tools' do
      c = build_configurator
      configure!(c)

      names = c.tools.map(&:name)
      %w[read write edit grep glob bash fileindex_search fileindex_read].each do |t|
        assert_includes names, t
      end
    end

    it 'picks the first usable backend in priority order' do
      second = stub_backend(available: true, label: 'second')
      with_singleton(Pikuri::Os::FileindexSearch, :new) do |orig|
        chosen = nil
        Pikuri::Os::FileindexSearch.define_singleton_method(:new) do |**kwargs|
          chosen = kwargs[:backend]
          orig.call(**kwargs)
        end

        configure!(build_configurator, backends: [stub_backend(available: false), second])
        assert_same second, chosen, 'should skip the unready backend and use the next one'
      end
    end

    it 'contributes the machine facts and the memory affordance via system_prompt_snippets' do
      c = build_configurator
      ext = configure!(c)

      additions = ext.system_prompt_snippets.join("\n")
      assert_includes additions, '# This machine'
      assert_includes additions, '- OS: TestOS'
      # memory.prompt_section was nil → affordance naming the path
      assert_includes additions, '/cfg/pikuri/MACHINE.md'
    end

    it 'gives Bash the human confirmer plus a PassiveCommandDetector with allow_git on (Write keeps the human one)' do
      with_singleton(Pikuri::Code::Bash, :new) do |orig|
        captured_confirmer = nil
        captured_approver = nil
        Pikuri::Code::Bash.define_singleton_method(:new) do |**kwargs|
          captured_confirmer = kwargs[:confirmer]
          captured_approver  = kwargs[:passive_detector]
          orig.call(**kwargs)
        end

        configure!(build_configurator)
        assert_same human, captured_confirmer,
                    'Bash should get the bare human confirmer, not a wrapper'
        assert_instance_of Pikuri::Code::Bash::PassiveCommandDetector, captured_approver
        assert captured_approver.passive?('git status'),
               'pikuri-os enables allow_git: true, so read-only git skips the prompt ' \
               '(backed by Bash env hardening)'
      end
    end

    it 'wires the file tools with confirm_all_writes: true (full-disk confirm-all posture)' do
      with_singleton(Pikuri::Workspace::Extension, :new) do |orig|
        captured = nil
        Pikuri::Workspace::Extension.define_singleton_method(:new) do |**kwargs|
          captured = kwargs
          orig.call(**kwargs)
        end

        configure!(build_configurator)
        assert_equal true, captured[:confirm_all_writes],
                     'pikuri-os wires Write/Edit to confirm every writable write'
      end
    end
  end

  describe 'plan-mode propagation through the composite' do
    # Os::Extension guards Workspace::Extension's filesystem with the flag and
    # hands it to Code::Extension. A flag handed to Os::Extension must
    # therefore light up the enter/exit tools transitively — this guards
    # against a refactor silently dropping that propagation.
    it 'wires the enter/exit tools when plan mode is present' do
      c = build_configurator
      configure!(c, plan_mode: Pikuri::Code::PlanMode.new)

      names = c.tools.map(&:name)
      assert_includes names, 'enter_plan_mode'
      assert_includes names, 'exit_plan_mode'
    end

    it 'omits the plan-mode tools when no flag is wired' do
      c = build_configurator
      configure!(c) # plan_mode: nil

      names = c.tools.map(&:name)
      refute_includes names, 'enter_plan_mode'
      refute_includes names, 'exit_plan_mode'
    end
  end

  describe '#configure when no file-index backend is usable' do
    it 'omits the file-index tools but still wires file tools + bash' do
      c = build_configurator
      configure!(c, backends: [stub_backend(available: false)])

      names = c.tools.map(&:name)
      assert_includes names, 'bash'
      assert_includes names, 'read'
      refute_includes names, 'fileindex_search'
      refute_includes names, 'fileindex_read'
    end

    it "logs each backend's reason" do
      logger = described_class::LOGGER
      warnings = []
      with_singleton(logger, :warn) do
        logger.define_singleton_method(:warn) { |message| warnings << message }
        configure!(build_configurator, backends: [stub_backend(available: false, label: 'localsearch'),
                                                  stub_backend(available: false, label: 'recoll')])
      end

      assert_equal 1, warnings.size
      assert_includes warnings.first, '- localsearch: localsearch is not ready'
      assert_includes warnings.first, '- recoll: recoll is not ready'
    end
  end
end
