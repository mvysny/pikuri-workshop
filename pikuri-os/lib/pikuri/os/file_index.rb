# frozen_string_literal: true

module Pikuri
  module Os
    # Picks the desktop file index the +fileindex_*+ tools run on, and says
    # why when no index is ready, so a host never probes one itself:
    #
    #   backend = FileIndex.pick                     # => Pikuri::Os::LocalSearch
    #   c.add_tool FileindexSearch.new(backend: backend)
    #   c.add_tool FileindexRead.new(backend: backend)
    #
    # On a host with neither index ready, {.pick} raises {Unavailable}, whose
    # message is meant for the user:
    #
    #   no file index is ready:
    #   - localsearch: the 'tinysparql' command is missing. Install …
    #   - recoll: no index in /home/u/.recoll yet. Build one with `recollindex`.
    #
    # A backend is a module answering +unavailable_reason+, +search+,
    # +read_text+, +limitations+ and +label+, with a +CommandError+ —
    # {LocalSearch} and {Recoll}.
    module FileIndex
      # @return [Array<Module>] backends in preference order: localsearch
      #   needs no setup on GNOME; recoll only works once the user built an
      #   index.
      BACKENDS = [LocalSearch, Recoll].freeze

      # Raised by {.pick} when no backend is ready; the message names each
      # one's reason.
      class Unavailable < StandardError; end

      # The first backend that is ready, probing each once, in order.
      #
      # @param backends [Array<Module>] candidates in preference order
      # @return [Module] the first one whose +unavailable_reason+ is +nil+
      # @raise [Unavailable] when none is ready
      def self.pick(backends = BACKENDS)
        reasons = []
        backends.each do |backend|
          reason = backend.unavailable_reason
          return backend unless reason

          reasons << "- #{backend.label}: #{reason}"
        end
        raise Unavailable, "no file index is ready:\n#{reasons.join("\n")}"
      end
    end
  end
end
