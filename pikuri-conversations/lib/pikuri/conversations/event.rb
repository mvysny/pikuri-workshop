# frozen_string_literal: true

module Pikuri
  class Conversations
    # What a {Conversation} says about itself, beside what its agent says. Both
    # reach the one listener the conversation was opened with, through the same
    # +on_event+:
    #
    #   def on_event(event)
    #     case event
    #     in Pikuri::Conversations::Event::TurnEnded(outcome: :failed, error:) then show(error)
    #     in Pikuri::Agent::Event::Assistant(content:)                         then render(content)
    #     else
    #     end
    #   end
    #
    # The agent's events narrate a turn from inside it; these narrate the
    # conversation around the turns — booting, a turn starting and ending, the
    # pending count, a model picked for later, the context window learnt. Never emitted under the
    # conversation's lock, so a listener may take its host's own lock, and may
    # call back into the conversation.
    #
    # Each variant's +to_s+ is a one-line rendering, so a generic listener (the
    # +Terminal+ one prints any event it does not know by its +to_s+) shows
    # something legible.
    module Event
      # The agent is being built, on a thread of its own — an MCP connection
      # may take seconds.
      Booting = Data.define do
        # @return [String]
        def to_s = 'Booting the agent'
      end

      # The agent is built; turns can run.
      #
      # @!attribute [r] trifecta
      #   @return [Pikuri::Agent::Trifecta::Report] the agent's lethal-trifecta
      #     picture, computed once on the booting thread
      Ready = Data.define(:trifecta) do
        # @return [String]
        def to_s = 'Agent ready'
      end

      # Building the agent raised. The conversation is back in +:new+, with its
      # pending messages kept; the next {Conversation#submit} boots again.
      #
      # @!attribute [r] error
      #   @return [StandardError] what +Agent.new+ raised — a
      #     +Pikuri::Agent::Control::Cancellable::Cancelled+ when a
      #     {Conversation#cancel} reached an extension that checks the token
      BootFailed = Data.define(:error) do
        # @return [String]
        def to_s = "Agent failed to boot: #{error.class}: #{error.message}"
      end

      # The context window the conversation's turns run against: once at boot,
      # then whenever it changes — learnt by a turn's {Probe}, or a different
      # model picked. Precedes the turn's first +Tokens+, so a readout of
      # +used/cap+ never pairs a count with a stale cap.
      #
      # @!attribute [r] cap
      #   @return [Integer, nil] in tokens; +nil+ when neither the transport
      #     states one nor the server told
      ContextCap = Data.define(:cap) do
        # @return [String]
        def to_s = cap ? "Context window: #{cap} tokens" : 'Context window unknown'
      end

      # A turn is starting. Emitted before the agent's own +UserTurn+.
      #
      # @!attribute [r] user_message
      #   @return [String, nil] the message the turn runs with; +nil+ for a bare
      #     turn — the first after a boot, a restart that delivers leftover
      #     injections, a system injection's turn
      # @!attribute [r] attachments
      #   @return [Array<Pikuri::Attachment>]
      TurnStarted = Data.define(:user_message, :attachments) do
        # @return [String]
        def to_s = user_message ? "Turn started: #{user_message}" : 'Turn started'
      end

      # The number of messages waiting for the agent changed — queued while it
      # booted, or injected into a running turn and not yet delivered.
      #
      # @!attribute [r] count
      #   @return [Integer]
      PendingChanged = Data.define(:count) do
        # @return [String]
        def to_s = "#{count} pending"
      end

      # A model was picked for the next turn, or the pick was undone.
      #
      # @!attribute [r] transport
      #   @return [Pikuri::Agent::ChatTransport, nil] the transport the next turn
      #     will use; +nil+ when re-picking the current model cleared the pick
      ModelPending = Data.define(:transport) do
        # @return [String]
        def to_s = transport ? "Next turn on #{transport.model}" : 'Model pick cleared'
      end

      # {Conversation#cancel} reached a running turn or a boot. The turn ends
      # with {TurnEnded} once it unwinds, which may take a moment — a tool
      # notices the token only at its next check.
      CancelRequested = Data.define do
        # @return [String]
        def to_s = 'Cancelling'
      end

      # A turn ended, after the host's +on_turn_end+ ran.
      #
      # @!attribute [r] outcome
      #   @return [Symbol] +:completed+, +:cancelled+ or +:failed+
      # @!attribute [r] error
      #   @return [StandardError, nil] what the turn raised, for +:failed+ —
      #     +Pikuri::Agent::EmptyTurnError+, +Pikuri::Agent::UnsupportedAttachmentError+,
      #     a +RubyLLM::Error+, anything a tool let escape
      # @!attribute [r] restarting
      #   @return [Boolean] whether a bare turn follows at once, to deliver what
      #     was injected too late for this one
      TurnEnded = Data.define(:outcome, :error, :restarting) do
        # @return [String]
        def to_s = error ? "Turn #{outcome}: #{error.class}: #{error.message}" : "Turn #{outcome}"
      end

      # The {Titler} named a conversation opened +untitled: true+. Store it
      # yourself — +Store#retitle+ — since the conversation never touches a
      # store. Comes at most once, after the first turn whose history holds a
      # user message, and never once the conversation is closing.
      #
      # @!attribute [r] title
      #   @return [String] one sanitized line of at most {Titler::MAX_WORDS} words
      Titled = Data.define(:title) do
        # @return [String]
        def to_s = "Titled: #{title}"
      end

      # The conversation is closed and its agent released; it takes no more
      # messages.
      Closed = Data.define do
        # @return [String]
        def to_s = 'Conversation closed'
      end
    end
  end
end
