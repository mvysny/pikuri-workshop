# frozen_string_literal: true

module Pikuri
  module Skill
    # Emitted when a touched file brings +paths:+-gated skills into play, so a
    # UI can say why a skill it never listed suddenly exists:
    #
    #   Promoted.new(skills: [rdoc], path: 'lib/pikuri/agent.rb').to_s
    #   # => "skills available: writing-rdoc (matched lib/pikuri/agent.rb)"
    #
    # +path+ is load-bearing rather than decoration: activation deliberately
    # over-fires (a coarse glob costs a few hundred bytes, a missed one costs
    # the skill), so a human *will* see a skill appear for no visible reason,
    # and without the trigger, diagnosing it means guessing which glob matched.
    #
    # This fires *before* the tool result the touch produced: the listener
    # decides at +before_tool_call+, while the injection itself waits for the
    # tool batch to be answered. "We decided" and "the model saw it" are
    # genuinely different moments; {Pikuri::Agent::Event::SystemInjected} marks
    # the second one.
    Promoted = Data.define(:skills, :path) do
      # @return [String] one line, for a renderer with no case arm of its own
      def to_s = "skills available: #{skills.map(&:name).join(', ')} (matched #{path})"
    end
  end
end
