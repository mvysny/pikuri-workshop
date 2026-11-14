# frozen_string_literal: true

require 'pikuri-core'

module Pikuri
  # Hosting many conversations, the part pikuri leaves to its hosts: an
  # {Pikuri::Agent} is one synchronous, thread-unsafe conversation that pikuri
  # never writes to disk. This is the list of live ones — each its own agent,
  # its turns on threads of their own — and the folder they are saved in:
  #
  #   store = Pikuri::Conversations::Store.new(root: dir, shell: 'my-chat')
  #   entries = {}   # id => Store::Entry; store.find sees only saved ones
  #   convs = Pikuri::Conversations.new(
  #     system_prompt: 'You are a helpful assistant.',
  #     configure: ->(c, conv) { c.add_tool(Pikuri::Tool::CALCULATOR) },
  #     on_turn_end: ->(conv, history) { store.save(entries[conv.id], history, model:, server:) }
  #   )
  #   entry = store.find(id) || store.create   # resume, or start one
  #   entries[entry.id] = entry
  #   conv = convs.open(id: entry.id, transport:, listener:, history: store.history(entry))
  #   conv.submit('how do I keep an avocado?')   # => :started; events reach +listener+
  #   convs.shutdown(timeout: 5)
  #
  # {Conversation} is one live conversation and its turn state; {Throttle}
  # bounds the requests in flight against each server, sized from what {Probe}
  # learns at a turn's start; {Titler} names a conversation after its first
  # turn; {RateLimitedListener} paces a streamed reply for a renderer;
  # {HistoryFile} is the stored format of an
  # {Pikuri::Agent::History}; {Store} keeps one folder per conversation. A list
  # never touches a store: the host joins them in +on_turn_end+.
  #
  # Thread-safe.
  class Conversations
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-conversations'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load

    include Enumerable

    # @param system_prompt [String, #call] the agents' system prompt, or
    #   +(conversation)+ → one per conversation
    # @param configure [#call, nil] +(configurator, conversation)+ — the
    #   +Agent.new+ block: tools, extensions, more listeners. The conversation's
    #   cancel token, history, listener and {Throttle} are wired already.
    # @param on_turn_end [#call, nil] +(conversation, history)+ after every turn
    #   — completed, cancelled or failed — on the turn's thread, before the
    #   conversation goes idle, so "idle" means "saved". Not called once the
    #   conversation is closing.
    # @param streaming [Boolean] the agents' +streaming:+
    # @param priority [Integer] the turn threads' +Thread#priority+; a GUI host
    #   lowers it to keep its main loop responsive
    # @param titler [Titler, nil] names the conversations opened +untitled: true+
    def initialize(system_prompt:, configure: nil, on_turn_end: nil, streaming: true, priority: 0, titler: nil)
      @system_prompt = system_prompt
      @configure = configure
      @on_turn_end = on_turn_end
      @titler = titler
      @streaming = streaming
      @priority = priority
      @lock = Mutex.new
      @conversations = {}
    end

    # Open a conversation, booting its agent on a thread of its own unless
    # +boot: false+, which leaves it +:new+ until {Conversation#boot} or the
    # first message.
    #
    # The listener hears events before this returns: {Event::Booting} on the
    # caller's thread, then the boot's own from its thread. A listener that
    # reads the conversation back boots it once the host holds it:
    #
    #   @live = convs.open(id:, transport:, listener: self, history:, boot: false)
    #   @live.boot
    #
    # @param id [String] unique among the open conversations
    # @param transport [Pikuri::Agent::ChatTransport] the model it starts on
    # @param listener [Pikuri::Agent::Listener::Base] hears the agent's events
    #   and the conversation's {Event}s
    # @param history [Pikuri::Agent::History, nil] a conversation to resume
    # @param boot [Boolean]
    # @param untitled [Boolean] whether it still wants a name — a resumed one
    #   still carrying its start stamp included: the list's {Titler} names it
    #   once a turn has ended ({Event::Titled}). Ignored without a titler.
    # @return [Conversation]
    # @raise [ArgumentError] if a conversation with +id+ is open
    def open(id:, transport:, listener:, history: nil, boot: true, untitled: false)
      conv = Conversation.new(id:, transport:, listener:, history:, build: method(:build_agent),
                              on_turn_end: @on_turn_end, on_closed: method(:forget), priority: @priority,
                              titler: untitled ? @titler : nil)
      @lock.synchronize do
        raise ArgumentError, "conversation #{id.inspect} is already open" if @conversations.key?(id)

        @conversations[id] = conv
      end
      conv.boot if boot
      conv
    end

    # @param id [String]
    # @return [Conversation, nil] the open conversation with +id+; a closed one
    #   is gone once its agent is released
    def [](id)
      @lock.synchronize { @conversations[id] }
    end

    # @yieldparam conversation [Conversation] each open conversation, from a
    #   snapshot of the list
    # @return [Enumerator, self]
    def each(&block)
      return enum_for(:each) unless block

      @lock.synchronize { @conversations.values }.each(&block)
      self
    end

    # Close every conversation, cancelling running turns; each turn unwinds on
    # its own thread and releases its agent.
    #
    #   convs.shutdown                # returns at once — a Puma +:state+ hook
    #   convs.shutdown(timeout: 5)    # waits up to 5 s in all
    #
    # @param timeout [Numeric] seconds to wait for the agents to be released
    # @return [Boolean] whether every agent was released in time
    def shutdown(timeout: 0)
      convs = to_a
      convs.each { |c| c.close(force: true) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      convs.all? { |c| c.wait_closed([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max) }
    end

    private

    def build_agent(conv, transport, history, cancellable)
      prompt = @system_prompt.respond_to?(:call) ? @system_prompt.call(conv) : @system_prompt
      Pikuri::Agent.new(transport:, system_prompt: prompt, cancellable:, streaming: @streaming, history:,
                        around_request: Throttle) do |c|
        c.add_listener(conv.listener)
        @configure&.call(c, conv)
      end
    end

    def forget(conv)
      @lock.synchronize { @conversations.delete(conv.id) if @conversations[conv.id].equal?(conv) }
    end
  end
end
