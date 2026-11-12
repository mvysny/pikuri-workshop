# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::Memory::Extension do
  def record(text, created_at: nil, score: nil)
    Pikuri::Memory::Record.new(
      id: 'r', text: text, score: score, created_at: created_at, metadata: {}, event: nil
    )
  end

  # Fake mem0 client: canned search/get_all results, and a thread-safe
  # capture of #add calls (capture is async).
  let(:fake_client_class) do
    Class.new do
      attr_accessor :search_rows, :all_rows, :search_error, :all_error
      attr_reader :queries

      def initialize
        @search_rows = []
        @all_rows = []
        @search_error = nil
        @all_error = nil
        @adds = Thread::Queue.new
      end

      def search(query:, user_id:, top_k:, threshold:)
        (@queries ||= []) << query
        raise @search_error if @search_error

        @search_rows
      end

      def get_all(user_id:)
        raise @all_error if @all_error

        @all_rows
      end

      def add(content:, user_id:, infer:, prompt:)
        @adds << content
        []
      end

      def await_add(timeout: 2)
        Timeout.timeout(timeout) { @adds.pop }
      end
    end
  end

  # A standalone Configurator (no full Agent needed to test #configure).
  def build_configurator
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base', id: '', streaming: false,
      cancellable: nil, interloper: nil
    )
  end

  # A minimal Agent::ExtensionContext stand-in that records on_close blocks.
  let(:fake_ctx_class) do
    Class.new do
      attr_reader :close_blocks

      def initialize
        @close_blocks = []
      end

      def on_close(&blk)
        @close_blocks << blk
      end
    end
  end

  describe '#configure' do
    it 'registers the recall tool' do
      ext = described_class.new(client: fake_client_class.new, user_id: 'u', resident_persona: false)
      c = build_configurator
      ext.configure(c)

      assert_equal ['recall'], c.tools.map(&:name)
    end

    it 'appends a resident-persona snippet built from the store, framed as the complete set' do
      client = fake_client_class.new
      client.all_rows = [record('lives in Brno'), record('writes Ruby')]
      ext = described_class.new(client: client, user_id: 'u')
      c = build_configurator
      ext.configure(c)

      snippet = ext.system_prompt_snippets.join
      assert_match(/<memory_persona>/, snippet)
      assert_match(/lives in Brno/, snippet)
      assert_match(/writes Ruby/, snippet)
      # Store fits under the cap, so the model is told it has everything —
      # this is what stops redundant recall on an open "what do you know?".
      assert_match(/complete set \(2 facts\)/, snippet)
      assert_match(/nothing beyond this list/, snippet)
    end

    it "singularizes 'fact' and reports the count for a one-memory store" do
      client = fake_client_class.new
      client.all_rows = [record('lives in Brno')]
      ext = described_class.new(client: client, user_id: 'u')
      c = build_configurator
      ext.configure(c)

      assert_match(/complete set \(1 fact\)/, ext.system_prompt_snippets.join)
    end

    it 'frames the persona as partial when the store exceeds resident_limit' do
      client = fake_client_class.new
      client.all_rows = Array.new(5) { |i| record("fact #{i}") }
      ext = described_class.new(client: client, user_id: 'u', resident_limit: 2)
      c = build_configurator
      ext.configure(c)

      snippet = ext.system_prompt_snippets.join
      assert_match(/Showing 2 of 5/, snippet)
      assert_match(/look up anything more specific/, snippet)
      refute_match(/complete set/, snippet)
      # Only the first resident_limit facts are listed.
      assert_match(/- fact 0/, snippet)
      assert_match(/- fact 1/, snippet)
      refute_match(/- fact 2/, snippet)
    end

    it 'appends no persona snippet for an empty store' do
      ext = described_class.new(client: fake_client_class.new, user_id: 'u')
      c = build_configurator
      ext.configure(c)

      assert_equal [], ext.system_prompt_snippets
    end

    it 'survives an unreachable store at boot (no persona, no raise)' do
      client = fake_client_class.new
      client.all_error = RuntimeError.new('mem0 down')
      ext = described_class.new(client: client, user_id: 'u')
      c = build_configurator
      ext.configure(c) # must not raise

      assert_equal [], ext.system_prompt_snippets
    end

    it 'skips the persona entirely when resident_persona: false' do
      client = fake_client_class.new
      client.all_rows = [record('should not be read')]
      ext = described_class.new(client: client, user_id: 'u', resident_persona: false)
      c = build_configurator
      ext.configure(c)

      assert_equal [], ext.system_prompt_snippets
    end

    it 're-queries the store on each call, so the persona refreshes (e.g. on clear)' do
      client = fake_client_class.new
      client.all_rows = [record('lives in Brno')]
      ext = described_class.new(client: client, user_id: 'u')

      first = ext.system_prompt_snippets.join
      assert_match(/lives in Brno/, first)
      refute_match(/writes Ruby/, first)

      # A fact captured during the conversation now exists in the store.
      client.all_rows = [record('lives in Brno'), record('writes Ruby')]

      second = ext.system_prompt_snippets.join
      assert_match(/writes Ruby/, second) # re-fetched, not the cached first pull
    end

    it 'raises if recall was pre-registered' do
      pre = Pikuri::Tool.new(
        name: 'recall', description: 'x',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :topic, 't' },
        execute: ->(topic:) { topic }
      )
      ext = described_class.new(client: fake_client_class.new, user_id: 'u', resident_persona: false)
      c = build_configurator
      c.add_tool(pre)

      assert_raises(RuntimeError) { ext.configure(c) }
    end
  end

  describe '#on_user_message prefetch' do
    it 'returns a system-framed <memory-context> with timestamps' do
      client = fake_client_class.new
      client.search_rows = [record('lives in Brno', created_at: '2026-05-01T17:04:11.884889+00:00', score: 0.8)]
      ext = described_class.new(client: client, user_id: 'u', resident_persona: false)

      block = ext.on_user_message(nil, 'where do I live?', [])

      assert_match(/<memory-context>/, block)
      assert_match(/NOT new user input/, block)
      # created_at is trimmed to whole-second wall-clock — no sub-second / offset noise.
      assert_match(/\(2026-05-01 17:04:11\) lives in Brno/, block)
      assert_match(/recall/, block) # affordance pointing at the tool
    end

    it 'returns nil when search finds nothing' do
      ext = described_class.new(client: fake_client_class.new, user_id: 'u', resident_persona: false)
      assert_nil ext.on_user_message(nil, 'anything', [])
    end

    it 'gates by threshold client-side, dropping low-similarity rows' do
      client = fake_client_class.new
      client.search_rows = [
        record('relevant', score: 0.8),
        record('noise', score: 0.2)
      ]
      ext = described_class.new(client: client, user_id: 'u', threshold: 0.5, resident_persona: false)

      block = ext.on_user_message(nil, 'q', [])

      assert_match(/relevant/, block)
      refute_match(/noise/, block)
    end

    it 'returns nil (no raise) when search fails' do
      client = fake_client_class.new
      client.search_error = RuntimeError.new('mem0 down')
      ext = described_class.new(client: client, user_id: 'u', resident_persona: false)

      assert_nil ext.on_user_message(nil, 'q', [])
    end

    it 'returns nil for blank content' do
      ext = described_class.new(client: fake_client_class.new, user_id: 'u', resident_persona: false)
      assert_nil ext.on_user_message(nil, '   ', [])
    end
  end

  describe '#on_user_message capture + #bind' do
    it 'bind starts the recorder and enqueued turns reach client.add' do
      require 'timeout'
      client = fake_client_class.new
      ext = described_class.new(client: client, user_id: 'martin', resident_persona: false)
      ctx = fake_ctx_class.new

      ext.bind(ctx)
      ext.on_user_message(nil, 'I am vegetarian', [])

      assert_equal 'I am vegetarian', client.await_add
      refute_empty ctx.close_blocks
    ensure
      ext.recorder.close
    end

    describe 'with attachments' do
      let(:png) { Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: 'png') }

      it 'captures a note naming each one after the text, but searches with the text alone' do
        require 'timeout'
        client = fake_client_class.new
        ext = described_class.new(client: client, user_id: 'martin', resident_persona: false)
        ext.bind(fake_ctx_class.new)

        ext.on_user_message(nil, "what's wrong here?", [png])

        assert_equal "what's wrong here?\n[user attached image: shot.png (image/png)]", client.await_add
        assert_equal ["what's wrong here?"], client.queries
      ensure
        ext.recorder.close
      end

      it 'captures an attachment-only turn, and recalls nothing for it' do
        require 'timeout'
        client = fake_client_class.new
        ext = described_class.new(client: client, user_id: 'martin', resident_persona: false)
        ext.bind(fake_ctx_class.new)

        assert_nil ext.on_user_message(nil, '', [png])
        assert_equal '[user attached image: shot.png (image/png)]', client.await_add
        assert_nil client.queries
      ensure
        ext.recorder.close
      end
    end

    it 'the on_close block closes the recorder' do
      client = fake_client_class.new
      ext = described_class.new(client: client, user_id: 'u', resident_persona: false)
      ctx = fake_ctx_class.new
      ext.bind(ctx)

      ctx.close_blocks.each(&:call) # must not raise; recorder stops
    end

    # The recall feedback loop (one hallucinated fact re-extracted into 800
    # copies) is held shut by capture reading its *argument* and never the
    # conversation. That used to be backed up by the role — a recalled block was
    # a :system message — but since `pikuri:D_reference_text_as_user_turn` the block is
    # a :user message like any other, so this is the only thing left holding it.
    # See design/architecture.md §"Retrieval".
    it 'captures the turn it was handed, never the block it returns' do
      require 'timeout'
      client = fake_client_class.new
      client.search_rows = [record('Martin drives a Volvo V70', score: 0.9)]
      ext = described_class.new(client: client, user_id: 'martin', resident_persona: false)
      ext.bind(fake_ctx_class.new)

      block = ext.on_user_message(nil, 'what car do I drive?', [])

      assert_includes block, 'Volvo V70' # the prefetch did fire
      assert_equal 'what car do I drive?', client.await_add
      # A second capture would mean the returned block came back around.
      assert_raises(Timeout::Error) { client.await_add(timeout: 0.4) }
    ensure
      ext.recorder.close
    end
  end
end
