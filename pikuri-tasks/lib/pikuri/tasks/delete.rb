# frozen_string_literal: true

module Pikuri
  module Tasks
    # The +task_delete+ tool: remove the item with the given +id+.
    # Distinct from {Completed} in intent — +completed+ means the work was
    # done, +delete+ means the task shouldn't have been there — a
    # distinction the tool names carry, not the list. A deleted id is never
    # reused ({List#add}). Returns {List#render}; a bad id returns
    # +"Error: no such task id"+ plus the current list.
    #
    # Sharing: +P_one_agent+ — closes over one agent's {List}; see its
    # +== Sharing+.
    class Delete < Pikuri::Tool
      # @return [String]
      DESCRIPTION = <<~DESC
        Remove a task from the list. Use this for items that turn out not to be needed, were created in error, or have been superseded.

        Usage:
        - Pass the task's numeric `id` as shown in the rendered list (`- #3 [pending] ...` → id 3).
        - Use `task_completed` (not this) when the work was actually done.
        - On `Error: no such task id: ...` the call did nothing — the error includes the current list; pick the right id from it.
        - On success the full current list is returned for you to read back.
      DESC

      # @param list [List]
      # @return [Delete]
      def initialize(list:)
        # Kept, not only closed over: {#describe_call} looks the task's title up.
        @list = list
        super(
          name: 'task_delete',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_integer :id,
                               'Numeric id of the existing task to remove, ' \
                               'as shown in the rendered list, e.g. 3.'
          },
          execute: lambda { |id:|
            Delete.execute(list: list, id: id)
          },
          # No legs; see {Create}.
          trifecta_legs: Pikuri::Tool::TrifectaLegs::NONE
        )
      end

      # The task's title rather than the integer id the model passes —
      # +TaskDelete(3)+ names nothing a reader recognizes.
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
        list.delete(id)
        Pikuri::Tool::Result.new(content: list.render, summary: list.summary)
      rescue ItemNotFound
        Pikuri::Tool::Result.error("no such task id: #{id}. Current list:\n#{list.render}")
      end
    end
  end
end
