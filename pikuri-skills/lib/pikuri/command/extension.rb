# frozen_string_literal: true

module Pikuri
  module Command
    # Declares the command surface to {Pikuri::Trifecta}, and does nothing
    # else — it registers no tool, renders no prompt snippet and binds no
    # handle.
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Command::Extension.new(registry: registry)
    #   end
    #
    # A host wires it purely so the boot banner tells the truth. Expansion
    # needs none of this: {Registry} and {Renderer} are pure functions over
    # disk, and a host dispatches a typed +/name+ itself.
    #
    # == Why an extension for one declaration
    #
    # The detector builds its tree from an agent's *tools* plus what its
    # extensions contribute. A command is neither — so a wired command surface
    # would land in that tree nowhere, and an agent that genuinely holds all
    # three legs would report two. Skills don't have this problem only because
    # their bytes ride {Pikuri::Skill::SkillTool}'s declaration; commands have
    # no tool to ride.
    #
    # An object rather than a kwarg on the host side because the mistake
    # should be unrepresentable, not something each host remembers.
    class Extension
      include Pikuri::Agent::Extension

      # @param registry [Pikuri::Command::Registry]
      def initialize(registry:)
        @registry = registry
      end

      # @return [Pikuri::Command::Registry]
      attr_reader :registry

      # The +untrusted+ leg, graded over the commands the registry stored:
      # +:hard+ unless every one of them came from a base the host vouched
      # for. No +private+ leg (a command reads nothing) and no egress leg (it
      # sends nothing) — a command body is prose that lands in a user turn.
      #
      # @param tools [Array<Pikuri::Tool>] unused; commands contribute no children
      # @return [Pikuri::Trifecta::Contribution, nil] +nil+ when there is
      #   nothing to declare, so an empty or fully-vouched registry adds no row
      def trifecta_contribution(tools)
        level = @registry.untrusted_level
        return nil if level == :none

        Pikuri::Trifecta::Contribution.new(
          label: '(commands)',
          legs: Pikuri::Tool::TrifectaLegs.new(
            private: false, untrusted: level, egress_payload_review: :no_egress
          )
        )
      end
    end
  end
end
