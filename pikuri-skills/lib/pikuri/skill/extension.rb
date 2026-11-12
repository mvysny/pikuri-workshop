# frozen_string_literal: true

require 'pathname'

module Pikuri
  # Namespace for the Skills feature — the Agent Skills standard, as
  # {Catalog} (discovery) + {SkillTool} (load) + {Extension} (wiring).
  module Skill
    # An {Pikuri::Agent::Extension} that auto-wires the Agent Skills
    # standard onto an agent: appends the catalog's
    # +<available_skills>+ block to the system prompt and registers
    # the +skill+ tool so the LLM can load skill bodies on demand.
    # Empty catalog ⇒ no-op (no snippet, no tool).
    #
    # == Usage
    #
    #   catalog = Pikuri::Skill::Catalog::Bundled.new(
    #     search_bases: [project_root, Dir.home]
    #   )
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Skill::Extension.new(catalog: catalog, root: project_root)
    #   end
    #
    # This contributes no +trifecta_contribution+ of its own, and that is
    # not an omission: the prompt block and {#schedule_load_skill} carry the
    # same bundles' bytes the +skill+ tool does, so they ride its +untrusted+
    # leg, which {Catalog#untrusted_level} grades over the whole stored set.
    #
    # +configure+ appends the prompt snippet + +skill+ tool (both inherited
    # verbatim by sub-agents via the tool snapshot); +bind+ additionally
    # captures the parent agent's interloper so a host can load a skill on
    # its *own* initiative via {#schedule_load_skill} — the UI-driven
    # counterpart of the +skill+ tool. Main-agent-only: sub-agents don't
    # inherit extensions.
    #
    # It also owns this conversation's {Activation} — which +paths:+-gated
    # skills have fired — and clears it when the host clears the conversation.
    class Extension
      include Pikuri::Agent::Extension

      LOGGER = Pikuri.logger_for('Skills')
      private_constant :LOGGER

      # @param catalog [Pikuri::Skill::Catalog] the catalog of
      #   skills the agent may load. Required.
      # @param root [Pathname] the workspace root a touched path is resolved
      #   against before it is matched against a skill's +paths:+. Absolute,
      #   because that path is model-supplied and must never be read as
      #   relative to whatever the process's cwd happens to be.
      # @raise [ArgumentError] if +root+ is not an absolute +Pathname+
      def initialize(catalog:, root:)
        unless root.is_a?(Pathname) && root.absolute?
          raise ArgumentError, "root must be an absolute Pathname, got #{root.inspect}"
        end

        @catalog = catalog
        @root = root
        @activation = Pikuri::Skill::Activation.new(catalog: catalog)
        @gate_armed = catalog.list.any?(&:gated?)
      end

      # @return [Pikuri::Skill::Catalog]
      attr_reader :catalog

      # @return [Pathname]
      attr_reader :root

      # @return [Pikuri::Skill::Activation, Pikuri::Skill::Activation::Open]
      #   which gated skills this conversation has in play. {#configure}
      #   downgrades it to an {Activation::Open} — no gate at all — when the
      #   agent has no interloper to carry a promotion.
      attr_reader :activation

      # Register the +skill+ tool, and — when the agent can receive a promotion
      # — the listener that fires one. No-op when the catalog is empty (the
      # +<available_skills>+ snippet is contributed by
      # {#system_prompt_snippets}).
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        return if @catalog.empty?

        if c.tools.any?(Pikuri::Skill::SkillTool)
          raise 'Pikuri::Skill::SkillTool cannot be pre-registered (in tools: or via c.add_tool) ' \
                'when adding Pikuri::Skill::Extension — the extension auto-registers it from the catalog.'
        end

        arm_gate(c.interloper)
        c.add_tool(Pikuri::Skill::SkillTool.new(activation: @activation))
        c.add_listener(path_activation_listener) if gate_armed?
        nil
      end

      # Capture the live agent's interloper so {#schedule_load_skill} and
      # {#announce} can enqueue onto it, and the context {#announce} emits
      # through.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext]
      # @return [void]
      def bind(ctx)
        @interloper = ctx.agent.interloper
        @ctx = ctx
        nil
      end

      # Inject a promotion and emit {Promoted}. The listener's callback; a host
      # driving activation itself may call it too.
      #
      # @param skills [Array<Pikuri::Skill::Catalog::Skill>] newly in play
      # @param path [String] the workspace-relative path that fired them
      # @return [void]
      def announce(skills, path)
        return if skills.empty?

        @interloper.inject_system_message(Pikuri::Skill::Renderer.format_promotion(skills))
        @ctx&.emit_event(Pikuri::Skill::Promoted.new(skills: skills, path: path))
        nil
      end

      # Schedule a skill for injection into the conversation on the host's
      # own initiative — the UI-driven counterpart of the +skill+ tool. Looks
      # +name+ up in the catalog, renders its body identically to the tool,
      # and *enqueues* it on the interloper as a reference block.
      #
      #   ext   = Pikuri::Skill::Extension.new(catalog: catalog, root: project_root)
      #   agent = Pikuri::Agent.new(..., interloper: interloper) { |c| c.add_extension ext }
      #   ext.schedule_load_skill('pdf-tools')    # enqueue only — nothing runs yet
      #   agent.run_loop(user_message: nil)        # bare turn: the agent reacts to the skill
      #
      # IMPORTANT: this only *enqueues*. Nothing happens until the host runs
      # the loop — {Pikuri::Agent#run_loop} drains the injection at turn
      # start, before the first completion. Enqueue-only keeps the call
      # non-blocking and thread-safe (the interloper is +Mutex+-guarded); it
      # never touches the loop or a worker thread. Two host choices, by how
      # the loop is then run:
      #
      # * bare load — +run_loop(user_message: nil)+: the agent reacts to the
      #   skill alone and says something.
      # * load + message — +run_loop(user_message: text)+: the skill block
      #   and the message both land before the model responds.
      #
      # Either way the block sits positionally where it was loaded, on every
      # provider — a one-shot, exactly like the +skill+ tool's observation.
      # ({Pikuri::Agent#append_reference_block} is what makes that uniform.)
      #
      # @param name [String] a skill in play; the UI enumerates them, so a miss
      #   is a host bug. A +paths:+-gated skill whose path has not fired is
      #   *not* in play and is refused exactly as an unknown name is — the gate
      #   is the default at every surface, the host's included.
      # @raise [KeyError] if +name+ is not in play
      # @raise [RuntimeError] if the agent was built without an +interloper:+
      #   (nowhere to enqueue)
      # @return [Pikuri::Skill::Catalog::Skill] the scheduled skill
      def schedule_load_skill(name)
        skill = @activation.get(name)
        raise KeyError, "no skill named #{name.inspect} in the catalog" if skill.nil?

        raise 'schedule_load_skill needs an interloper — construct the Agent with `interloper:`' \
          if @interloper.nil?

        @interloper.inject_system_message(Pikuri::Skill::Renderer.format_skill(skill))
        skill
      end

      # Re-hide the gated skills. The clear dropped their promotions from the
      # log, so the next matching touch has to announce them again.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext] unused; protocol signature.
      # @return [void]
      def on_conversation_reset(_ctx)
        @activation.reset
        nil
      end

      # The +<available_skills>+ catalog block, carrying every *ungated* skill
      # and no hint that anything is missing (empty array when that leaves
      # nothing to say). {Renderer.format_catalog} returns leading blank lines;
      # the Agent joins sections with +\n\n+, so +lstrip+ avoids doubling them.
      #
      # Deliberately reads the catalog rather than the {Activation}: a
      # promotion belongs in the log, not the prompt, and
      # {Pikuri::Agent#clear_conversation} re-assembles the prompt *before* it
      # calls {#on_conversation_reset} — a snippet built from the activation
      # set would rebuild carrying activations that are about to be cleared,
      # advertising skills the +skill+ tool would then refuse.
      #
      # @return [Array<String>]
      def system_prompt_snippets
        return [] if @catalog.empty?

        block = Pikuri::Skill::Renderer.format_catalog(advertised)
        block.empty? ? [] : [block.lstrip]
      end

      private

      # Nothing gated ⇒ nothing to arm, and no listener worth running on every
      # tool call. Gated but no interloper ⇒ a promotion would have nowhere to
      # land, so the gate comes off entirely rather than hiding a skill nothing
      # can bring back.
      def arm_gate(interloper)
        gated = @catalog.list.select(&:gated?)
        @gate_armed = !gated.empty? && !interloper.nil?
        return if gated.empty? || @gate_armed

        LOGGER.warn('agent has no interloper, so a promotion would have nowhere to land — ' \
                    "paths:-gated skills stay advertised (#{gated.map(&:name).join(', ')})")
        @activation = Pikuri::Skill::Activation::Open.new(catalog: @catalog)
      end

      def gate_armed? = @gate_armed

      def advertised = gate_armed? ? @catalog.list.reject(&:gated?) : @catalog.list

      def path_activation_listener
        Pikuri::Skill::PathActivationListener.new(
          activation: @activation,
          root: @root,
          on_promote: ->(skills, path) { announce(skills, path) }
        )
      end
    end
  end
end
