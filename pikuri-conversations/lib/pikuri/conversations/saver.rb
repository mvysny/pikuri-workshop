# frozen_string_literal: true

module Pikuri
  class Conversations
    # Where a host keeps a conversation after every turn — completed, cancelled
    # or failed, one a forced close cut short included. The list never touches a
    # {Store}; a saver joins the two:
    #
    #   class Saving
    #     include Pikuri::Conversations::Saver
    #
    #     def initialize(store, entries) = (@store, @entries = store, entries)
    #     def save(conversation, history) = @store.save(@entries[conversation.id], history, model:, server:)
    #   end
    #
    #   convs = Pikuri::Conversations.new(initializer:, saver: Saving.new(store, entries))
    module Saver
      # Runs on the turn's thread, before the conversation goes idle, so "idle"
      # means "saved". A raise is logged and the conversation goes idle anyway.
      #
      # @param conversation [Conversation] +conversation.status.model+ is the
      #   model the turn ran on
      # @param history [Pikuri::Agent::History] a snapshot taken as the turn ended
      # @return [void]
      # @raise [NotImplementedError] unless overridden
      def save(conversation, history)
        raise NotImplementedError, "#{self.class} must implement save(conversation, history)"
      end
    end
  end
end
