# frozen_string_literal: true

module Pikuri
  module Mcp
    # One-shot LLM pass for the MCP boot-time checks ({Synthesizer},
    # {Verifier}): {#call} takes a self-contained prompt and returns the model's
    # reply as a String. Each call builds a fresh tools-free {Pikuri::Agent},
    # runs the prompt as its single turn, and closes it — fresh per call so
    # per-server prompts don't accumulate in one chat and cross-contaminate
    # (construction cost is noise next to the round-trip, and {Cache}
    # short-circuits before {#call} fires anyway). No listeners, no step limit.
    #
    # +cancellable+ is checked once before each call (the gentle-cancel
    # semantic: a flag flipped between calls raises promptly; the in-flight HTTP
    # is not interrupted). Deliberately NOT passed into the one-shot agent —
    # +Agent#run_loop+ resets its cancellable at the turn boundary, which would
    # erase a pending Ctrl+C. Provider errors propagate verbatim; how each
    # consumer then handles them is the cancel/degrade policy in
    # +pikuri-mcp/design/architecture.md+.
    class Thinker
      # System prompt for the one-shot agents. The real
      # instructions (synthesis framing, verification rubric) live
      # in the prompt {Synthesizer} / {Verifier} build and send as
      # the user turn, so this stays generic.
      SYSTEM_PROMPT =
        'You are a one-shot analysis pass inside an agent boot sequence. ' \
        'Follow the instructions in the user message exactly and reply ' \
        'with only what they ask for — no preamble.'

      # @param transport [Pikuri::Agent::ChatTransport] the
      #   model-resolution triple every one-shot agent is
      #   constructed with — typically the host agent's own, so
      #   boot passes run against the same model.
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil]
      #   when set, checked before each {#call} so a boot-time
      #   Ctrl+C aborts startup on the next pass.
      # @raise [ArgumentError] when +transport+ is +nil+
      def initialize(transport:, cancellable: nil)
        raise ArgumentError, 'transport must not be nil' if transport.nil?

        @transport = transport
        @cancellable = cancellable
      end

      # Run one prompt through a fresh tools-free agent.
      #
      # @param prompt [String] self-contained instructions + data,
      #   sent as the single user turn
      # @return [String] the assistant's reply content (+""+ when
      #   the provider produced no assistant message)
      # @raise [Pikuri::Agent::Control::Cancellable::Cancelled]
      #   when the +cancellable+ flag was tripped at the pre-call
      #   check
      def call(prompt)
        @cancellable&.check!
        agent = Pikuri::Agent.new(transport: @transport, system_prompt: SYSTEM_PROMPT)
        begin
          agent.run_loop(user_message: prompt)
          agent.last_assistant_content.to_s
        ensure
          agent.close
        end
      end
    end
  end
end
