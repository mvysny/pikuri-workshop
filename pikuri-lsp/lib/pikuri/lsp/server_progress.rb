# frozen_string_literal: true

module Pikuri
  module Lsp
    # One language server's indexing task, shaped as a domain event a host
    # shows as a line. Two states matter — a task under way, and the same task
    # over:
    #
    #   progress = ServerProgress.new(server_id: 'java', title: 'Initialize Workspace',
    #                                 message: 'Importing gradle project')
    #   progress.to_s   # => "java: Initialize Workspace — Importing gradle project"
    #   progress.with(message: nil, done: true).to_s
    #                   # => "java: Initialize Workspace — done"
    #

    # It exists because pikuri removed the clock: the first call blocks until
    # the server is ready — 7s warm, 78s for a cold jdtls import — and a silent
    # three-minute stall is indistinguishable from a hang for whoever is
    # watching.
    #
    # Maps 1:1 onto LSP's +WorkDoneProgress+ +begin+ / +report+ / +end+, one
    # variant covering the whole lifecycle.
    #
    # @!attribute [r] server_id
    #   @return [String] the registry entry's +id+, e.g. +"ruby"+ or +"java"+.
    #     Two servers index concurrently at boot, so a line names its server.
    # @!attribute [r] title
    #   @return [String] the server's own name for the task, e.g.
    #     +"Initialize Workspace"+. Server-supplied text bound for a terminal,
    #     so whoever renders it defangs it via {Pikuri::Sanitizer}.
    # @!attribute [r] message
    #   @return [String, nil] the finer detail a +report+ carries, e.g.
    #     +"3200/4096 files"+; +nil+ when the server sent none.
    # @!attribute [r] percentage
    #   @return [Integer, nil] 0..100, or +nil+ — which is common enough that a
    #     consumer must not assume a percentage.
    # @!attribute [r] done
    #   @return [Boolean] the task is over. Defaults to +false+.
    ServerProgress = Data.define(:server_id, :title, :message, :percentage, :done) do
      def initialize(server_id:, title:, message: nil, percentage: nil, done: false)
        super
      end

      # @return [String] one line, server first — two servers index at once, so
      #   whoever reads it needs to know whose task it is.
      def to_s
        detail = [percentage && "#{percentage}%", message, (done ? 'done' : nil)].compact
        "#{server_id}: #{([title] + detail).join(' — ')}"
      end
    end
  end
end
