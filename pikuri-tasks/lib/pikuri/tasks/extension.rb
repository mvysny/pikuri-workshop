# frozen_string_literal: true

module Pikuri
  # Namespace for the in-memory task-list feature. Holds the
  # {List} value type, the four task tool classes ({Create},
  # {InProgress}, {Completed}, {Delete}), the {ListChanged} domain
  # event, and the {Extension} that wires them into an
  # {Pikuri::Agent}.
  module Tasks
    # An {Pikuri::Agent::Extension} that auto-wires an in-memory task list
    # onto an agent: constructs a fresh {List}, registers the four task
    # tools against it, contributes a workflow snippet, and (in {#bind})
    # arms {ListChanged} emission.
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Tasks::Extension.new
    #   end
    #
    # Sub-agents don't inherit extensions, so a spawned sub-agent gets no
    # task list — keeping the parent's plan private and avoiding
    # who-owns-which-task confusion. A host wanting one adds the extension
    # to the sub-agent's own configurator.
    class Extension
      include Pikuri::Agent::Extension

      # System-prompt snippet appended once per agent. Rules-of-thumb
      # only, no inventory (the tool descriptions cover their own usage).
      #
      # @return [String]
      PROMPT_SNIPPET = <<~PROMPT
        <tasks_usage>
        You have an in-memory task list. Use it to plan and track multi-step work.

        Workflow:
        - When a task has 3+ steps, call `task_create` once with the full plan (a JSON array of strings, all start as `pending`).
        - Before starting an item, call `task_in_progress` with its numeric id. Keep exactly one item `in_progress` at a time.
        - When an item is fully done (including any required verification), call `task_completed` with its numeric id.
        - Use `task_delete` to remove items that turn out not to be needed.

        Skip task tracking entirely for single-step or purely informational requests — it adds noise, not value.

        Every mutation returns the full current list, with each task's id (`- #3 [pending] ...` → id 3), so you do not need a separate read tool. Ids never change and are never reused.
        </tasks_usage>
      PROMPT

      # Tool classes the extension auto-registers.
      TOOL_CLASSES = [Create, InProgress, Completed, Delete].freeze

      # @return [Extension]
      def initialize
        @list = List.new
      end

      # @return [List] the per-agent list, exposed for tests. Do NOT read
      #   it from another thread — it's agent-thread-confined; consume the
      #   {ListChanged} events wired by {#bind} instead.
      attr_reader :list

      # Construct the four tools (each sharing +@list+), register them,
      # and append {PROMPT_SNIPPET}. Raises if any of the four were
      # pre-registered via +c.add_tool+ — the extension is the single
      # owner of the shared list, and a pre-registered tool would bind to
      # a different one.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        TOOL_CLASSES.each do |cls|
          if c.tools.any?(cls)
            raise "#{cls} cannot be pre-registered (in tools: or via c.add_tool) " \
                  'when adding Pikuri::Tasks::Extension — the extension auto-registers all four task tools ' \
                  'so they share the same in-memory list.'
          end
        end

        TOOL_CLASSES.each { |cls| c.add_tool(cls.new(list: @list)) }
        nil
      end

      # @return [Array<String>] the static task-workflow snippet.
      def system_prompt_snippets = [PROMPT_SNIPPET]

      # Arm {List#on_change} to emit a {ListChanged} (carrying a fresh
      # {List#items} snapshot) after every mutation — how a UI listener
      # observes the list without touching the agent-thread-confined {List}.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext]
      # @return [void]
      def bind(ctx)
        @list.on_change = -> { ctx.emit_event(ListChanged.new(items: @list.items)) }
        nil
      end

      # Clear the task list on conversation reset — a plan is meaningless
      # without the conversation that produced it. {List#clear} fires the
      # armed +on_change+, so an empty {ListChanged} reaches the listener
      # stream like any other mutation.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext] unused; part of the
      #   protocol signature.
      # @return [void]
      def on_conversation_reset(_ctx)
        @list.clear
        nil
      end
    end
  end
end
