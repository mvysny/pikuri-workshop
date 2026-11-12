# frozen_string_literal: true

require 'pathname'

module Pikuri
  module Skill
    # Watches the tool stream for a file the model is about to touch, and
    # promotes the +paths:+-gated skills that file fires:
    #
    #   listener = PathActivationListener.new(
    #     activation: activation,
    #     root: project_root,
    #     on_promote: ->(skills, path) { ext.announce(skills, path) }
    #   )
    #
    # Nothing fires twice: {Activation#activate} answers with the skills that
    # were not already in play, and +on_promote+ is called only when that list
    # is non-empty.
    #
    # == Implementation details
    #
    # {TOUCH_TOOLS} is an allowlist of tools, not a convention about argument
    # names. +read+, +write+ and +edit+ agree on +path+ — but so do +grep+ and
    # +glob+, whose +path+ is a search *root*, and one repo-root +grep+ would
    # otherwise activate half the catalog at once. That is the same
    # supplied-vs-walked line the **Denylist seam** draws for the credential
    # denylist, from the other direction.
    #
    # Activation reads the model's *arguments*, at +before_tool_call+, so a
    # read of a path that does not exist, or a write the human then rejects,
    # promotes anyway. Deliberate: over-firing costs a few hundred bytes,
    # under-firing withholds the skill at the moment it was wanted. It is also
    # what buys the in-turn landing — an enqueue here drains as soon as the
    # running tool batch is answered, with no extra round-trip.
    #
    # The path is model-supplied, so it is resolved against +root+ *lexically*
    # — no +realpath+, or a +write+ to a file that does not exist yet would
    # never match — and anything landing outside the root is dropped rather
    # than matched against the wrong tree.
    class PathActivationListener < Pikuri::Agent::Listener::Base
      # Tools whose +path+ argument names a file the model means to touch.
      TOUCH_TOOLS = %w[read write edit].freeze

      # @param activation [Activation] the conversation's gate state; also the
      #   source of the catalog to match against
      # @param root [Pathname] absolute workspace root
      # @param on_promote [Proc] called as +(skills, path)+ with the newly
      #   activated skills and the workspace-relative path that fired them
      def initialize(activation:, root:, on_promote:)
        super()
        @activation = activation
        @root = root
        @on_promote = on_promote
      end

      # @param event [Pikuri::Agent::Event::ToolCall, Object] anything else is
      #   ignored
      # @return [void]
      def on_event(event)
        return unless event.is_a?(Pikuri::Agent::Event::ToolCall)
        return unless TOUCH_TOOLS.include?(event.name)

        path = workspace_relative(event.arguments['path'] || event.arguments[:path])
        return if path.nil?

        fired = @activation.catalog.list.select { |skill| PathMatcher.match?(skill.paths, path) }
        promoted = @activation.activate(fired)
        @on_promote.call(promoted, path) unless promoted.empty?
        nil
      end

      # A sub-agent must never run this: it holds the *parent's* activation, so
      # a child reading a file would mutate the parent's gate state and enqueue
      # onto the parent's interloper. Sub-agents get no promotions at all —
      # {Activation::Sealed} is the other half of that.
      #
      # @return [nil] always, opting out of the sub-agent listener list
      def for_sub_agent(**) = nil

      private

      # @return [String, nil] +nil+ when there is no usable path, or it points
      #   outside the workspace
      def workspace_relative(raw)
        return nil if raw.nil? || raw.to_s.strip.empty?

        relative = Pathname.new(raw.to_s).expand_path(@root).relative_path_from(@root).to_s
        return nil if relative == '..' || relative.start_with?('../')

        relative
      end
    end
  end
end
