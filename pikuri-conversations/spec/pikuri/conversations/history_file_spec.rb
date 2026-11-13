# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot

RSpec.describe Pikuri::Conversations::HistoryFile do
  history_class = Pikuri::Agent::History

  # A conversation exercising every branch of the format: a typed user turn, an
  # assistant tool-call turn with thinking + usage, the tool result carrying an
  # image, and an injected reference block.
  let(:png) { (+"\x89PNG\r\n\x1a\n").b + ('payload' * 4).b }
  let(:history) do
    history_class.new(messages: [
                        history_class::Message.new(id: 'm1', role: 'user', content: 'show me a.png'),
                        history_class::Message.new(
                          id: 'm2', role: 'assistant', content: '', model_id: 'qwen3-35b',
                          tool_calls: [history_class::ToolCall.new(id: 'call_1', name: 'read',
                                                                   arguments: { 'path' => 'a.png' },
                                                                   display_name: 'Read', argument: 'a.png')],
                          thinking: history_class::Thinking.new(text: 'ponder', signature: 'SIG=='),
                          tokens: history_class::Tokens.new(input: 100, output: 7, cached: 20,
                                                            cache_creation: nil, thinking: nil)
                        ),
                        history_class::Message.new(
                          id: 'm3', role: 'tool', tool_call_id: 'call_1', content: 'Read image: a.png',
                          summary: 'Read a.png',
                          attachments: [Pikuri::Attachment.new(mime: 'image/png', filename: 'a.png', bytes: png)]
                        ),
                        history_class::Message.new(id: 'm4', role: 'user', kind: 'reference',
                                                   content: '<system-reminder>recalled</system-reminder>')
                      ])
  end

  describe 'round-tripping' do
    it 'survives the self-contained JSON form' do
      assert_equal history, described_class.parse(described_class.to_json(history))
    end

    it 'survives the folder form' do
      Dir.mktmpdir do |dir|
        described_class.save(history, dir)
        assert_equal history, described_class.load(dir)
      end
    end

    it 'converges: both encodings load to the same value' do
      Dir.mktmpdir do |dir|
        described_class.save(history, dir)
        # The property that stops the two encodings drifting into two formats.
        assert_equal described_class.parse(described_class.to_json(history)), described_class.load(dir)
      end
    end

    it 'serializes every Pikuri::Attachment field' do
      # A field pikuri adds to Pikuri::Attachment needs attachment_to_h/from_h
      # too; one with a default would otherwise be dropped on save without a sound.
      assert_equal %i[mime filename bytes], Pikuri::Attachment.members
    end

    it 'serializes every History::Message field' do
      # Same guard, one level up: these are the keys message_to_h writes.
      assert_equal %i[id role kind content attachments tool_calls tool_call_id model_id thinking tokens summary],
                   history_class::Message.members
    end

    it 'loads a pre-summary file with nils rather than refusing it' do
      raw = described_class.to_h(history)
      raw['messages'].each do |m|
        m.delete('summary')
        (m['tool_calls'] || []).each { |c| c.delete('display_name') && c.delete('argument') }
      end

      old = described_class.from_h(raw)

      assert_nil old.messages[1].tool_calls.first.display_name
      assert_nil old.messages[2].summary
      # And an absent string is simply absent again on the way out.
      refute_includes described_class.to_h(old)['messages'][2].keys, 'summary'
    end
  end

  describe 'the folder form' do
    it 'writes history.json plus content-addressed attachments' do
      Dir.mktmpdir do |dir|
        saved = described_class.save(history, dir)
        assert_equal %w[attachments history.json], Dir.children(saved).sort
        stored = Dir.children(saved / 'attachments')
        assert_equal 1, stored.size
        # Digest prefix + sanitized original name.
        assert_match(/\A[0-9a-f]{10}-a\.png\z/, stored.first)
      end
    end

    it 'skips an attachment already present, and never deletes an unreferenced one' do
      Dir.mktmpdir do |dir|
        saved = described_class.save(history, dir)
        orphan = saved / 'attachments' / 'deadbeef00-gone.png'
        orphan.binwrite('stale')

        # Re-saving a shrunken history leaves both the orphan and the still-live file.
        described_class.save(history.with(messages: history.messages.take(2)), dir)

        assert orphan.exist?, 'save must not delete files it did not write'
        assert_equal 2, Dir.children(saved / 'attachments').size
      end
    end

    it 'refuses a history whose attachment is missing from the folder' do
      Dir.mktmpdir do |dir|
        saved = described_class.save(history, dir)
        (saved / 'attachments').children.each(&:delete)

        e = assert_raises(described_class::Error) { described_class.load(dir) }
        assert_match(/is missing from/, e.message)
      end
    end

    it 'refuses an attachment whose bytes no longer match its digest' do
      Dir.mktmpdir do |dir|
        saved = described_class.save(history, dir)
        (saved / 'attachments').children.first.binwrite('tampered')

        e = assert_raises(described_class::Error) { described_class.load(dir) }
        assert_match(/does not match its content digest/, e.message)
      end
    end

    it 'refuses a folder with no history.json' do
      Dir.mktmpdir do |dir|
        e = assert_raises(described_class::Error) { described_class.load(dir) }
        assert_match(/no history\.json/, e.message)
      end
    end
  end

  describe '.stored_name' do
    def named(filename) = Pikuri::Attachment.new(mime: 'image/png', filename: filename, bytes: png)

    it 'is the digest prefix plus the sanitized original name' do
      assert_match(/\A[0-9a-f]{10}-Screen-Shot\.png\z/, described_class.stored_name(named('Screen Shot.png')))
    end

    it 'never yields a path, whatever the filename says' do
      assert_match(/\A[0-9a-f]{10}-passwd\z/, described_class.stored_name(named('../../etc/passwd')))
    end

    it 'names a nameless attachment' do
      assert_match(/\A[0-9a-f]{10}-attachment\z/, described_class.stored_name(named('')))
    end
  end

  describe 'attachment confinement' do
    # The rule: an attachment either lives in this folder or the history does
    # not load. No sanitizing, no rewriting a bad path into a good one.
    def tampered(dir, file)
      raw = JSON.parse((Pathname(dir) / 'history.json').read)
      raw['messages'][2]['attachments'][0]['file'] = file
      raw
    end

    it 'refuses a traversal out of the folder' do
      Dir.mktmpdir do |dir|
        described_class.save(history, dir)
        File.write(File.join(dir, 'secret.txt'), 'ssh-key')

        e = assert_raises(described_class::Error) do
          described_class.from_h(tampered(dir, '../secret.txt'), dir: Pathname(dir))
        end
        assert_match(/must be a bare filename/, e.message)
      end
    end

    it 'refuses an absolute path' do
      Dir.mktmpdir do |dir|
        described_class.save(history, dir)

        e = assert_raises(described_class::Error) do
          described_class.from_h(tampered(dir, '/etc/passwd'), dir: Pathname(dir))
        end
        assert_match(/must be a bare filename/, e.message)
      end
    end

    it 'refuses a symlink that resolves outside the folder' do
      Dir.mktmpdir do |dir|
        saved = described_class.save(history, dir)
        secret = File.join(dir, 'secret.txt')
        File.write(secret, 'ssh-key')
        # Passes every textual check: a bare filename, sitting in attachments/.
        File.symlink(secret, saved / 'attachments' / 'aaaaaaaaaa-evil.png')

        e = assert_raises(described_class::Error) do
          described_class.from_h(tampered(dir, 'aaaaaaaaaa-evil.png'), dir: Pathname(dir))
        end
        assert_match(/outside/, e.message)
      end
    end

    it 'refuses a file-backed attachment when parsed without a folder' do
      Dir.mktmpdir do |dir|
        json = (described_class.save(history, dir) / 'history.json').read

        e = assert_raises(described_class::Error) { described_class.parse(json) }
        assert_match(/use HistoryFile\.load/, e.message)
      end
    end
  end

  describe 'validation' do
    def raw(messages) = { 'version' => 1, 'messages' => messages }

    it 'refuses a version from the future rather than loading it best-effort' do
      e = assert_raises(described_class::Error) { described_class.from_h({ 'version' => 2, 'messages' => [] }) }
      assert_match(/newer than this reader understands/, e.message)
    end

    it 'refuses a missing version' do
      e = assert_raises(described_class::Error) { described_class.from_h({ 'messages' => [] }) }
      assert_match(/missing version/, e.message)
    end

    it 'refuses malformed JSON' do
      assert_raises(described_class::Error) { described_class.parse('{not json') }
    end

    it 'ignores unknown keys, so a file from a newer writer still loads' do
      loaded = described_class.from_h(raw([{ 'id' => 'a', 'role' => 'user', 'content' => 'hi', 'invented_later' => 42 }]))
      assert_equal 1, loaded.messages.size
    end

    it 'defaults an absent kind to user' do
      loaded = described_class.from_h(raw([{ 'id' => 'a', 'role' => 'user', 'content' => 'hi' }]))
      assert_equal 'user', loaded.messages.first.kind
    end

    it 'refuses a system message: the prompt is re-assembled, never replayed' do
      e = assert_raises(described_class::Error) do
        described_class.from_h(raw([{ 'id' => 'a', 'role' => 'system', 'content' => 'x' }]))
      end
      assert_match(%r{role must be one of user/assistant/tool}, e.message)
    end

    it 'refuses a duplicate id' do
      e = assert_raises(described_class::Error) do
        described_class.from_h(raw([{ 'id' => 'a', 'role' => 'user', 'content' => 'x' },
                                    { 'id' => 'a', 'role' => 'user', 'content' => 'y' }]))
      end
      assert_match(/duplicate id a/, e.message)
    end

    it 'refuses a tool result no assistant message asked for' do
      e = assert_raises(described_class::Error) do
        described_class.from_h(raw([{ 'id' => 'a', 'role' => 'tool', 'tool_call_id' => 'ghost', 'content' => 'x' }]))
      end
      assert_match(/was never issued/, e.message)
    end

    it 'refuses one tool call answered twice' do
      e = assert_raises(described_class::Error) do
        described_class.from_h(raw([{ 'id' => 'a', 'role' => 'assistant', 'content' => '',
                                      'tool_calls' => [{ 'id' => 'c1', 'name' => 'read', 'arguments' => {} }] },
                                    { 'id' => 'b', 'role' => 'tool', 'tool_call_id' => 'c1', 'content' => 'x' },
                                    { 'id' => 'c', 'role' => 'tool', 'tool_call_id' => 'c1', 'content' => 'y' }]))
      end
      assert_match(/already answered/, e.message)
    end

    it 'refuses a tool_call_id on a non-tool message' do
      e = assert_raises(described_class::Error) do
        described_class.from_h(raw([{ 'id' => 'a', 'role' => 'user', 'content' => 'x', 'tool_call_id' => 'c1' }]))
      end
      assert_match(/only a tool message/, e.message)
    end

    it 'accepts a tool call with no result: that is what a crash leaves behind' do
      loaded = described_class.from_h(raw([{ 'id' => 'a', 'role' => 'assistant', 'content' => '',
                                             'tool_calls' => [{ 'id' => 'c1', 'name' => 'read',
                                                                'arguments' => {} }] }]))
      assert_equal 1, loaded.messages.size
    end
  end

  # The claim the format has to earn: resuming a stored conversation on a fresh
  # agent produces *no observable change to the model*. Asserted on the bytes
  # on the wire, with pikuri's fake transport, so the whole property is offline.
  describe 'resuming an agent from it' do
    # Records every outbound request body, then serves the scripted replies.
    def recording_transport(captured, &script_block)
      script = Pikuri::Testing::Script.new
      script_block.call(script)
      base = Pikuri::Testing.build_adapter(script.responses)
      recorder = Class.new(base) do
        define_method(:call) do |env|
          captured << JSON.parse(env.body.to_s)
          super(env)
        end
      end
      Pikuri::Agent::ChatTransport.new(
        model: 'fake-model', provider: :openai, assume_model_exists: true,
        api_base: 'http://fake.invalid/v1', api_key: 'not-needed',
        context_window: 8192, faraday_adapter: recorder
      )
    end

    # Runs a tool-using turn, optionally stores and resumes the conversation on
    # a new agent, then runs one more turn; answers that turn's request body.
    def final_body(&store_and_load)
      captured = []
      transport = recording_transport(captured) do |llm|
        llm.tool_call('calculator', expression: '2 + 2')
        llm.reply('The answer is 4.')
        llm.reply('Yes, still 4.')
      end
      wiring = ->(c) { c.add_tool Pikuri::Tool::CALCULATOR }
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent', &wiring)
      agent.run_loop(user_message: 'What is 2 + 2?')
      if store_and_load
        stored = store_and_load.call(agent.export_history)
        agent.close
        agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent', history: stored, &wiring)
      end
      agent.run_loop(user_message: 'Are you sure?')
      captured.last
    ensure
      agent&.close
    end

    it 'sends byte-identical requests after the JSON form' do
      assert_equal final_body, final_body { |h| described_class.parse(described_class.to_json(h)) }
    end

    it 'sends byte-identical requests after the folder form' do
      Dir.mktmpdir do |dir|
        assert_equal final_body, final_body { |h| described_class.load(described_class.save(h, dir)) }
      end
    end

    it 'keeps the display strings, which nothing could recompute on resume' do
      captured = []
      transport = recording_transport(captured) do |llm|
        llm.tool_call('calculator', expression: '2 + 2')
        llm.reply('The answer is 4.')
      end
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent') do |c|
        c.add_tool Pikuri::Tool::CALCULATOR
      end
      agent.run_loop(user_message: 'What is 2 + 2?')

      again = described_class.parse(described_class.to_json(agent.export_history))

      assert_equal 'Calculator', again.messages[1].tool_calls.first.display_name
      assert_equal '2 + 2', again.messages[1].tool_calls.first.argument
      assert_equal '4', again.messages[2].summary
    ensure
      agent&.close
    end

    it 'sends a stored image again, byte for byte' do
      image = Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: png)
      bodies = lambda do |&store_and_load|
        captured = []
        transport = recording_transport(captured) do |llm|
          llm.reply('Red on the left, blue on the right.')
          llm.reply('Yes.')
        end
        agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
        agent.run_loop(user_message: "What's in it?", attachments: [image])
        if store_and_load
          stored = store_and_load.call(agent.export_history)
          agent.close
          agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent', history: stored)
        end
        agent.run_loop(user_message: 'Are you sure?')
        captured.last
      ensure
        agent&.close
      end

      Dir.mktmpdir do |dir|
        assert_equal bodies.call, bodies.call { |h| described_class.load(described_class.save(h, dir)) }
      end
    end
  end
end
