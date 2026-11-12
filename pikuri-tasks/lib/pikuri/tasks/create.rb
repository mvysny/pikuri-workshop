# frozen_string_literal: true

module Pikuri
  module Tasks
    # The +task_create+ tool: mass-create pending items from a JSON array
    # of strings — a native +items+ array parameter, the shape the model's
    # training prior produces unprompted. (Regression guard: don't revert
    # to a newline-separated string. An earlier such design meant to spare
    # small models the bracket-balancing, but models sent JSON arrays
    # anyway and the splitter turned `[`, `"foo",`, `]` into garbage tasks
    # — match the prior, don't fight it.)
    #
    # Atomic: each element is stripped, and a blank or duplicate element
    # (within the batch or already in the list) aborts the *whole* call
    # with an +"Error: ..."+ string and adds nothing — the LLM resends a
    # corrected batch, and never has to reconcile a half-applied list. On
    # success returns {List#render}.
    #
    # Sharing: +P_one_agent+ — closes over one agent's {List}; see its
    # +== Sharing+.
    class Create < Pikuri::Tool
      # @return [String] static description shown to the LLM,
      #   opencode-shape (summary + +Usage:+ bullets).
      DESCRIPTION = <<~DESC
        Create one or more new task items in a single call. All items start as `pending`.

        Usage:
        - Use at the start of a multi-step task to capture the plan.
        - A blank element, a duplicate (within the batch or already on the list), or an empty array aborts the whole call with `Error: ...` and adds nothing — resend a corrected batch.
        - On success the full current list is returned, with each task's `#id` — use that id with `task_in_progress` / `task_completed` / `task_delete`.
      DESC

      # @param list [List] the shared per-Agent list, captured by closure
      #   so every task tool mutates the same instance.
      # @return [Create]
      def initialize(list:)
        super(
          name: 'task_create',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string_array :items,
                                    'Task contents, one task per array element, e.g. ' \
                                    '["Add dark mode toggle", "Write unit tests", "Update README"].'
          },
          execute: lambda { |items:|
            Create.execute(list: list, items: items)
          },
          # No legs: an in-memory, per-agent list. Nothing read from disk, nothing sent.
          trifecta_legs: Pikuri::Tool::TrifectaLegs::NONE
        )
      end

      # The batch's size rather than an +Array#to_s+ dump of every item.
      #
      # @param arguments [Hash] raw tool-call arguments
      # @return [String]
      def describe_call(arguments)
        items = arguments['items'] || arguments[:items]
        items.is_a?(Array) ? Pikuri::Tool.pluralize(items.size, 'item') : Pikuri::Tool.describe_arguments(arguments)
      end

      # Validate and apply the batch.
      #
      # @param list [List]
      # @param items [Array<String>] raw +items+ argument from the LLM
      #   (already type-validated by {Pikuri::Tool::Parameters}).
      # @return [Pikuri::Tool::Result] {List#render} (+"3 tasks, 1 done"+) on
      #   success, or {Pikuri::Tool::Result.error} the LLM can react to.
      def self.execute(list:, items:)
        return Pikuri::Tool::Result.error('task_create requires at least one item') if items.empty?

        cleaned = items.map(&:strip)
        blank = cleaned.index('')
        if blank
          return Pikuri::Tool::Result.error("blank item at index #{blank} — every element " \
                                            'must be non-blank task text')
        end

        seen_in_batch = {}
        cleaned.each do |c|
          return Pikuri::Tool::Result.error("duplicate item in batch: '#{c}'") if seen_in_batch[c]

          seen_in_batch[c] = true
        end

        existing = list.items.map(&:content)
        clash = cleaned.find { |c| existing.include?(c) }
        return Pikuri::Tool::Result.error("task already exists: '#{clash}'") if clash

        cleaned.each { |c| list.add(c) }
        Pikuri::Tool::Result.new(content: list.render, summary: list.summary)
      end
    end
  end
end
