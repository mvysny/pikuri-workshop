# frozen_string_literal: true

module Pikuri
  class Conversations
    # A frozen snapshot of a {Conversation}, taken in one critical section so
    # its fields agree with each other — what a status bar renders:
    #
    #   s = conversation.status
    #   s.state                    # => :running
    #   s.pending                  # => 1
    #   s.next_model.model         # => "qwen3.6" — what the next turn reaches
    #   s.next_model.modalities    # => {vision: true, ...} when the transport states them
    #   s.busy?                    # => true — show "working"
    #
    # A transport rather than a model id, because a model id alone cannot tell
    # two servers apart, and because the transport carries its stated
    # +context_window+ and +modalities+ along.
    #
    # @!attribute [r] state
    #   @return [Symbol] +:new+, +:booting+, +:idle+, +:running+ or +:closed+
    # @!attribute [r] pending
    #   @return [Integer] messages waiting for the agent: queued during a boot,
    #     or injected into a turn and not yet delivered
    # @!attribute [r] model
    #   @return [Pikuri::Agent::ChatTransport] the transport the agent is on —
    #     or will be built with, before a boot
    # @!attribute [r] next_model
    #   @return [Pikuri::Agent::ChatTransport] the transport the next turn will
    #     use: a pending {Conversation#switch_model} pick, else {#model}
    Status = Data.define(:state, :pending, :model, :next_model) do
      # Whether work the user asked for is under way: a turn runs, or a boot
      # has a message waiting to become one. Re-read it on every {Event}
      # rather than pairing {Event::TurnStarted} with {Event::TurnEnded}: a
      # boot cancelled before its turn started ends in {Event::Ready} alone.
      #
      # @return [Boolean]
      def busy? = state == :running || (state == :booting && pending.positive?)
    end
  end
end
