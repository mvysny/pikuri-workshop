# frozen_string_literal: true

require 'delegate'

module Pikuri
  module Code
    class PlanMode
      # A {Pikuri::Workspace::Filesystem} that refuses every write while its
      # {PlanMode} is on; built by {PlanMode#guard}.
      #
      #   fs = plan_mode.guard(filesystem)
      #   plan_mode.activate!
      #   fs.resolve_for_write('lib/a.rb')
      #   # raises Filesystem::Error: "cannot change lib/a.rb: you are in plan mode (read-only). …"
      #
      # Reads, containment and every other answer come from the wrapped
      # filesystem unchanged.
      class Guard < SimpleDelegator
        # @param filesystem [Pikuri::Workspace::Filesystem]
        # @param plan_mode [PlanMode]
        def initialize(filesystem, plan_mode)
          super(filesystem)
          @plan_mode = plan_mode
        end

        # @param path [String, Pathname]
        # @return [Pathname]
        # @raise [Pikuri::Workspace::Filesystem::Error] while plan mode is on,
        #   or when the wrapped filesystem refuses +path+.
        def resolve_for_write(path)
          if @plan_mode.active?
            raise Pikuri::Workspace::Filesystem::Error, "cannot change #{path}: #{PlanMode::REFUSAL}"
          end

          super
        end
      end
    end
  end
end
