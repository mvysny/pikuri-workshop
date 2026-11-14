# frozen_string_literal: true

module Pikuri
  class Conversations
    # Coalesces streaming deltas into at most +fps+ events a second before they
    # reach +inner+, so a Markdown renderer re-renders 15 times a second rather
    # than once per token of a fast llama.cpp:
    #
    #   listener = Pikuri::Conversations::RateLimitedListener.new(renderer, fps: 15)
    #   convs.open(id:, transport:, listener:)   # the conversation's events too
    #
    # A buffered delta is dropped at its own bookend (+Assistant+ / +Thinking+),
    # which carries the whole text; any other agent event flushes the buffers
    # ahead of itself, so the stream reaches +inner+ whole and in order. A
    # conversation's own events ({Event::ALL}) pass straight through, except
    # {Event::TurnEnded}, which flushes first. A host that routes the
    # conversation's events elsewhere still hands this one +TurnEnded+.
    #
    # +inner+ is called from more than one thread — the turn's, and whichever
    # one submits or cancels — so it must take that, as a listener that
    # marshals onto its UI thread and returns does.
    #
    # == Implementation details
    #
    # Only the agent's thread touches the buffers, so there is no lock. A
    # conversation event may come from any thread and so bypasses them; a lock
    # instead would have to span +inner+'s call — a lock around the buffers
    # alone lets a flush from the submitting thread hand +inner+ an earlier
    # chunk after a later one the turn thread already emitted — and would then
    # sit outside whatever lock +inner+ takes.
    #
    # +TurnEnded+ can't bypass: a turn that fails mid-stream emits no agent
    # event after its last delta, so its tail would wait for the next turn's
    # +UserTurn+ and show after the new user message. It may touch the buffers
    # because it comes on the turn's thread, after the agent's last event (its
    # own doc promises so). The tail is flushed, not dropped: no bookend comes
    # to show that text whole, and the host's failure notice follows it.
    #
    # A sub-agent's limiter ({#for_sub_agent}) never sees a +TurnEnded+, so a
    # sub-agent failing mid-stream would leave its tail in a limiter nobody
    # calls again. Its parent flushes it instead, ahead of the parent's next
    # event — +TurnEnded+ at the latest, which also forgets the turn's
    # sub-agents.
    #
    # No timer: the tick schedule advances only when an event arrives, so a
    # model that pauses mid-reply leaves up to one period's text unshown until
    # its next delta or bookend. The schedule is anchored at construction, so
    # the first delta flushes at once, and after a flush it advances by whole
    # periods, so a long-idle stream doesn't backlog ticks.
    class RateLimitedListener < Pikuri::Agent::Listener::Base
      # @param inner [Pikuri::Agent::Listener::Base] where the coalesced stream goes
      # @param fps [Integer, Float] the cap on delta events a second; positive
      # @param clock [Proc] zero-arg → monotonic seconds as a +Float+; a spec's seam
      # @raise [ArgumentError] if +fps+ is not positive
      def initialize(inner, fps:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        super()
        raise ArgumentError, "fps must be positive, got #{fps.inspect}" unless fps.positive?

        @inner = inner
        @fps = fps
        @period = 1.0 / fps
        @clock = clock
        @next_tick_at = clock.call
        @assistant_buffer = String.new
        @thinking_buffer = String.new
        @sub_agents = []
      end

      # @param event [Data] an agent event, a conversation's, or an extension's own
      # @return [void]
      def on_event(event)
        case event
        when Pikuri::Agent::Event::AssistantDelta
          @assistant_buffer << event.content
          tick
        when Pikuri::Agent::Event::ThinkingDelta
          @thinking_buffer << event.content
          tick
        when Pikuri::Agent::Event::Assistant
          flush_thinking
          @assistant_buffer.clear
          @inner.on_event(event)
        when Pikuri::Agent::Event::Thinking
          @thinking_buffer.clear
          flush_assistant
          @inner.on_event(event)
        when Event::TurnEnded
          flush
          @sub_agents.clear
          @inner.on_event(event)
        when *Event::ALL
          @inner.on_event(event)
        else
          flush
          @inner.on_event(event)
        end
      end

      # Wraps the inner listener's sub-agent variant in a fresh limiter of the
      # same +fps+, which this one flushes ahead of its own events. A sub-agent
      # runs on its parent's turn thread, so the new limiter's buffers stay
      # single-threaded too.
      #
      # @param params [Hash{Symbol => Object}] forwarded to the inner's +for_sub_agent+
      # @return [RateLimitedListener, nil] +nil+ when the inner one opts out
      def for_sub_agent(**params)
        inner_sub = @inner.respond_to?(:for_sub_agent) ? @inner.for_sub_agent(**params) : @inner
        return nil if inner_sub.nil?

        sub = self.class.new(inner_sub, fps: @fps, clock: @clock)
        @sub_agents << sub
        sub
      end

      # @return [String] e.g. +"RateLimited(15fps, Listener)"+
      def to_s = "RateLimited(#{@fps}fps, #{@inner})"

      protected

      # Sub-agents first: whatever they still hold came before this agent's
      # buffered text, which only started once their tool call returned.
      #
      # @return [void]
      def flush
        @sub_agents.each { |sub| sub.flush } # not &:flush, which can't call a protected method
        flush_thinking
        flush_assistant
      end

      private

      # @return [void]
      def tick
        now = @clock.call
        return if now < @next_tick_at

        flush
        missed = ((now - @next_tick_at) / @period).floor + 1
        @next_tick_at += missed * @period
      end

      # @return [void]
      def flush_assistant
        return if @assistant_buffer.empty?

        @inner.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: @assistant_buffer.dup))
        @assistant_buffer.clear
      end

      # @return [void]
      def flush_thinking
        return if @thinking_buffer.empty?

        @inner.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: @thinking_buffer.dup))
        @thinking_buffer.clear
      end
    end
  end
end
