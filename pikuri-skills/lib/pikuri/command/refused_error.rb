# frozen_string_literal: true

module Pikuri
  module Command
    # Raised by {Registry#get} for a command that exists on disk but cannot be
    # run — it declares +allowed-tools:+, or its body carries a
    # <code>!`cmd`</code> directive.
    #
    # Host-facing: it never reaches a tool, so the +"Error: …"+-string
    # convention for model-visible failures does not apply. A REPL rescues it
    # and prints {#message}; the command stays in {Registry#list} so a menu can
    # still show it, greyed out or not.
    #
    #   begin
    #     text = registry.expand(name, arguments: args)
    #   rescue Pikuri::Command::RefusedError => e
    #     puts "/#{name} is unavailable — #{e.message}"
    #     next
    #   end
    class RefusedError < StandardError
      # @return [String] path of the command file
      attr_reader :location

      # @param location [String] path of the command file
      # @param reason [String] what the file did, phrased as the predicate of
      #   "this command …"
      def initialize(location, reason)
        @location = location
        super("#{location}: #{reason}")
      end
    end
  end
end
