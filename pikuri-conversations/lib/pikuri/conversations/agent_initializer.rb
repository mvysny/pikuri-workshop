# frozen_string_literal: true

module Pikuri
  class Conversations
    # What a host tells {Conversations} about each conversation's agent: its
    # system prompt and its tools. Include it and override:
    #
    #   class Chat
    #     include Pikuri::Conversations::AgentInitializer
    #
    #     def system_prompt(_conversation) = "You are a helpful assistant. Today is #{Time.now.strftime('%A, %-d %B %Y')}."
    #     def configure(configurator, _conversation) = configurator.add_tool(Pikuri::Tool::CALCULATOR)
    #   end
    #
    #   convs = Pikuri::Conversations.new(initializer: Chat.new)
    #
    # Called on the boot's thread, once per agent built — a conversation's
    # first boot, and again after every clear or failed boot.
    module AgentInitializer
      # @param conversation [Conversation] the one whose agent is being built
      # @return [String] the agent's system prompt
      # @raise [NotImplementedError] unless overridden
      def system_prompt(conversation)
        raise NotImplementedError, "#{self.class} must implement system_prompt(conversation)"
      end

      # Add tools, extensions and more listeners: the +Agent.new+ block. The
      # conversation's cancel token, history, listener and {Throttle} are wired
      # already. Does nothing unless overridden.
      #
      # A raise fails the boot ({Event::BootFailed}); the next submit boots again.
      #
      # @param configurator [Pikuri::Agent::Configurator] the agent being built
      # @param conversation [Conversation] the one whose agent it is
      # @return [void]
      def configure(configurator, conversation); end
    end
  end
end
