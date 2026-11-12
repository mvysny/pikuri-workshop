# frozen_string_literal: true

module Pikuri
  module Skill
    # The +skill+ tool: looks the requested +name+ up in the bound
    # {Catalog} and returns the skill body wrapped in a +<skill>+ block
    # with its base directory, so the LLM resolves relative sidecar
    # paths against it via the +read+ tool.
    #
    # The available-skills inventory is *not* in this tool's
    # description — it lives in the system prompt (see
    # {Renderer.format_catalog}), next to the agent's persona, as PI,
    # Claude Code and opencode v2 all do. So the description is static:
    # it explains the load mechanism, not the inventory.
    #
    # A sub-agent is the exception, and the description must not paper
    # over it: {Extension} contributes that prompt snippet, and
    # sub-agents don't inherit extensions — so a persona naming +skill+
    # in its +tool_names:+ gets this tool with no +<available_skills>+
    # block anywhere in its prompt, and supplies the loadable names in
    # its own +system_prompt:+ instead. Hence the description says
    # *where the list is, when there is one* rather than asserting the
    # section exists, and the not-found error enumerates the catalog so
    # recovery never depends on a block that may be absent.
    #
    # {Extension#configure} auto-registers this (never manually) when
    # the catalog is non-empty. The bound {Activation} rides in the
    # +execute+ closure, so a sub-agent inheriting the tool resolves names
    # against the same catalog the parent saw — but through
    # {#for_sub_agent}, against a sealed view of it.
    #
    # The prompt pays per skill *installed*, this tool pays per skill
    # *used*, and the ratio is why: a `skill(name:)` call is ~30 output
    # tokens once, where `cop` + `tuile` resident are ~4 000 input tokens
    # for the rest of the conversation. Roughly 100:1 — so every mechanism
    # for shaving the round-trip (pre-injecting bodies, a `names:` batch)
    # makes the expensive axis worse. A `paths:` trigger is therefore a
    # relevance filter on the catalog *entry*, never a body preloader; see
    # `design/decisions.md` `D_skill_path_activation`.
    #
    # Sharing: +P_one_agent+ — the {Activation} it resolves through is *this*
    # conversation's set of fired +paths:+ gates, and a promotion one agent
    # earned must not hand the name to an agent that was never told it. That
    # {Activation} is itself thread-safe, which is exactly the case where
    # thread-safety is no licence to share. {#for_sub_agent} hands a child a
    # sealed view rather than this one.
    class SkillTool < Pikuri::Tool
      # Description shown to the LLM (opencode-shape; inventory omitted —
      # see the class header).
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Load a specialized skill that provides domain-specific instructions and resources for a particular task.

        Usage:
        - Invoke this tool with a skill's `name` to inject its full instructions into the conversation.
        - Load only a name you were actually given: your system prompt lists them under `<available_skills>` when it carries that section, otherwise your instructions name the skills you may load.
        - The loaded skill may reference helper scripts and files in its base directory — use the `read` tool to load those when the skill's instructions tell you to.
        - On `Error: skill '...' not found`, do NOT retry with a guessed name — the error lists every name that does exist, so load one of those or report to the user that no matching skill is installed.
      DESC

      # @param activation [Activation, Activation::Sealed] the conversation's
      #   view of the catalog — what this tool resolves a name against, and
      #   (through {Activation#catalog}) the source of its +untrusted+ leg
      #   ({Catalog#untrusted_level}). Captured by closure so the tool retains
      #   access to the same instance even when copied into a sub-agent's tool
      #   snapshot, which is exactly what {#for_sub_agent} overrides.
      # @return [SkillTool]
      def initialize(activation:)
        @activation = activation
        catalog = activation.catalog
        super(
          name: 'skill',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :name,
                              'Name of the skill to load, e.g. "pdf-extraction". ' \
                              'Must match one of the skill names you were given.'
          },
          execute: lambda { |name:|
            loaded = activation.get(name)
            if loaded.nil?
              # The enumeration is half the gate: recite the catalog here and
              # one refused guess dumps every name the prompt withheld.
              available = activation.names
              list = available.empty? ? 'none' : available.join(', ')
              next Pikuri::Tool::Result.error("skill '#{name}' not found. " \
                                              "Available skills: #{list}.")
            end

            body = Pikuri::Skill::Renderer.format_skill(loaded)
            Pikuri::Tool::Result.new(content: body,
                                     summary: "Loaded #{Pikuri::Tool.format_bytes(body.bytesize)}")
          },
          # No egress; untrusted graded by the catalog. A skill body is prose —
          # Markdown dropped into the model's context verbatim, exactly like a README
          # the model +read+, with no added privilege — so the only question is whose
          # bytes they are, and {Pikuri::Bundle::Base} answers it per root. Unvouched is
          # +:hard+ and is the default, which is what a downloaded +.agents/+ bundle
          # gets; the Agent Skills standard exists precisely so bundles travel.
          # An executable sidecar changes nothing here: it runs only when the model
          # invokes it through bash, where the sandbox and the confirmer gate it.
          trifecta_legs: Pikuri::Tool::TrifectaLegs.new(private: false, untrusted: catalog.untrusted_level,
                                                        egress_payload_review: :no_egress)
        )
      end

      # @return [Activation, Activation::Sealed] the view this tool resolves
      #   names against
      attr_reader :activation

      # The copy a spawned sub-agent gets: same catalog, but a sealed
      # {Activation::Sealed}, so a skill the parent promoted mid-run is not
      # quietly reachable in a child that was never told its name.
      #
      # @return [SkillTool]
      def for_sub_agent
        self.class.new(activation: Pikuri::Skill::Activation::Sealed.new(catalog: @activation.catalog))
      end
    end
  end
end
