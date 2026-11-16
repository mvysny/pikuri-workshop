# frozen_string_literal: true

require 'pikuri-core'

module Pikuri
  # Hosting many conversations, the part pikuri leaves to its hosts: an
  # {Pikuri::Agent} is one synchronous, thread-unsafe conversation that pikuri
  # never writes to disk. This is the list of live ones — each its own agent,
  # its turns on threads of their own — and the folder they are saved in:
  #
  #   class Chat
  #     include Pikuri::Conversations::AgentInitializer
  #     include Pikuri::Conversations::Saver
  #
  #     def initialize(store, entries) = (@store, @entries = store, entries)
  #     def system_prompt(_conv) = 'You are a helpful assistant.'
  #     def configure(c, _conv) = c.add_tool(Pikuri::Tool::CALCULATOR)
  #     def save(conv, history) = @store.save(@entries[conv.id], history, model:, server:)
  #   end
  #
  #   store = Pikuri::Conversations::Store.new(root: dir, shell: 'my-chat')
  #   entries = {}   # id => Store::Entry; store.find sees only saved ones
  #   chat = Chat.new(store, entries)
  #   convs = Pikuri::Conversations.new
  #   entry = store.find(id) || store.create   # resume, or start one
  #   entries[entry.id] = entry
  #   conv = convs.open(id: entry.id, transport:, listener:, initializer: chat, saver: chat,
  #                     history: store.history(entry))
  #   conv.submit('how do I keep an avocado?')   # => :started; events reach +listener+
  #   convs.shutdown(timeout: 5)
  #
  # {Conversation} is one live conversation and its turn state; {Throttle}
  # bounds the requests in flight against each server, sized from what {Probe}
  # learns at a turn's start; {Titler} names a conversation after its first
  # turn; {RateLimitedListener} paces a streamed reply for a renderer;
  # {HistoryFile} is the stored format of an
  # {Pikuri::Agent::History}; {Store} keeps one folder per conversation. A list
  # never touches a store: each conversation's {Saver} joins them, and its
  # {AgentInitializer} gives its agent the prompt and the tools.
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

    # @param streaming [Boolean] the agents' +streaming:+
    # @param priority [Integer] the turn threads' +Thread#priority+; a GUI host
    #   lowers it to keep its main loop responsive
    # @param titler [Titler, nil] names the conversations opened +untitled: true+
    def initialize(streaming: true, priority: 0, titler: nil)
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
    # caller's thread, then the boot's own from its thread. A host object that
    # is all three of a conversation's hooks, and reads the conversation back,
    # boots it once it holds it:
    #
    #   @live = convs.open(id:, transport:, listener: self, initializer: self, saver: self,
    #                      history:, boot: false)
    #   @live.boot
    #
    # @param id [String] unique among the open conversations
    # @param transport [Pikuri::Agent::ChatTransport] the model it starts on
    # @param listener [Pikuri::Agent::Listener::Base] hears the agent's events
    #   and the conversation's {Event}s; a +Pikuri::Agent::ListenerList+ hands
    #   them to several, one per pane
    # @param initializer [AgentInitializer] its agent's system prompt and tools
    # @param saver [Saver, nil] keeps it after every turn; +nil+ keeps nothing
    # @param history [Pikuri::Agent::History, nil] a conversation to resume
    # @param boot [Boolean]
    # @param untitled [Boolean] whether it still wants a name — a resumed one
    #   still carrying its start stamp included: the list's {Titler} names it
    #   once a turn has ended ({Event::Titled}). Ignored without a titler.
    # @return [Conversation]
    # @raise [ArgumentError] if a conversation with +id+ is open
    def open(id:, transport:, listener:, initializer:, saver: nil, history: nil, boot: true, untitled: false)
      build = ->(conv, model, resumed, cancellable) { build_agent(initializer, conv, model, resumed, cancellable) }
      conv = Conversation.new(id:, transport:, listener:, history:, build:,
                              saver:, on_closed: method(:forget), priority: @priority,
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
    # its own thread, saves through the {Saver} and releases its agent.
    #
    #   convs.shutdown                # returns at once — a Puma +:state+ hook
    #   convs.shutdown(timeout: 5)    # waits up to 5 s in all, the saves included
    #
    # @param timeout [Numeric] seconds to wait for every conversation's
    #   {Event::Closed} to be heard
    # @return [Boolean] whether every conversation closed in time — true means
    #   no event reaches a listener afterwards, false that a turn may still be
    #   saving
    def shutdown(timeout: 0)
      convs = to_a
      convs.each { |c| c.close(force: true) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      convs.all? { |c| c.wait_closed([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max) }
    end

    private

    def build_agent(initializer, conv, transport, history, cancellable)
      Pikuri::Agent.new(transport:, system_prompt: initializer.system_prompt(conv), cancellable:,
                        streaming: @streaming, history:, around_request: Throttle) do |c|
        c.add_listener(conv.listener)
        initializer.configure(c, conv)
      end
    end

    def forget(conv)
      @lock.synchronize { @conversations.delete(conv.id) if @conversations[conv.id].equal?(conv) }
    end
  end
end
