# frozen_string_literal: true

module Pikuri
  module Tasks
    # The +task_in_progress+ tool: mark the item with the given +id+ as
    # +in_progress+. The status is baked into the tool name, not a
    # parameter — one fewer degree of freedom for the LLM (no
    # +"in-progress"+/+"inprogress"+ typos) at the cost of one tool class.
    #
    # Items are addressed by numeric +#id+, not content string (regression
    # guard: an earlier content-as-id design locked the LLM out of its own
    # list on one near-miss byte — a stray quote or trailing comma; an id
    # is two digits it just read back). Returns {List#render}; a bad id
    # returns +"Error: no such task id"+ plus the current list.
    #
    # Sharing: +P_one_agent+ — closes over one agent's {List}; see its
    # +== Sharing+.
    class InProgress < Pikuri::Tool
      # @return [String]
      DESCRIPTION = <<~DESC
        Mark a task as `in_progress` immediately before you start working on it.

        Usage:
        - Pass the task's numeric `id` as shown in the rendered list (`- #3 [pending] ...` → id 3).
        - Keep exactly one task `in_progress` at a time. Finish (or revert) the current one before starting another.
        - On `Error: no such task id: ...` the call did nothing — the error includes the current list; pick the right id from it.
        - On success the full current list is returned for you to read back.
      DESC

      # @param list [List]
      # @return [InProgress]
      def initialize(list:)
        # Kept, not only closed over: {#describe_call} looks the task's title up.
        @list = list
        super(
          name: 'task_in_progress',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_integer :id,
                               'Numeric id of the existing task to mark as ' \
                               'in_progress, as shown in the rendered list, e.g. 3.'
          },
          execute: lambda { |id:|
            InProgress.execute(list: list, id: id)
          },
          # No legs; see {Create}.
          trifecta_legs: Pikuri::Tool::TrifectaLegs::NONE
        )
      end

      # The task's title rather than the integer id the model passes —
      # +TaskInProgress(3)+ names nothing a reader recognizes.
      #
      # @param arguments [Hash] raw tool-call arguments
      # @return [String]
      def describe_call(arguments)
        Pikuri::Tool.one_line(@list.label_for(arguments['id'] || arguments[:id]))
      end

      # @param list [List]
      # @param id [Integer]
      # @return [Pikuri::Tool::Result] the rendered list (+"3 tasks, 1 done"+),
      #   or {Pikuri::Tool::Result.error} for an id the list does not hold
      def self.execute(list:, id:)
        list.set_status(id: id, status: 'in_progress')
        Pikuri::Tool::Result.new(content: list.render, summary: list.summary)
      rescue ItemNotFound
        Pikuri::Tool::Result.error("no such task id: #{id}. Current list:\n#{list.render}")
      end
    end
  end
end
