# frozen_string_literal: true

module Pikuri
  module Lsp
    # The +lsp+ tool: one tool, ten operations, and no column ever asked for.
    #
    #   tool = LspTool.new(servers: servers, filesystem: filesystem)
    #   tool.run('operation' => 'goToDefinition', 'symbol' => 'resolve_for_read',
    #            'file' => 'read.rb', 'line' => 165)
    #
    # The *surface* lives here — the schema, the description the model reads, the
    # legs, the progress emitter. The behaviour is {Navigator}'s, the enum is
    # {Operation}'s, and why a column is derived rather than asked for is {Anchor}'s.
    #
    # Ten +lsp_*+ tools would be ten descriptions in every request's prompt budget,
    # and all three shipped harnesses reached the same one-tool conclusion. The
    # +foo_*+ prefix convention is still satisfied: the family shares one backing
    # resource, and +Tool::Parameters+ validates the enum strictly.
    #
    # == The legs, including the one that will surprise you
    #
    # +untrusted: :hard+, **unconditionally** — not riding +filesystem.trusted?+ the
    # way {Pikuri::Workspace::Read} does. +read+'s conditional cannot be copied
    # because +read+ is confined to the root, so a human's "yes, I trust this
    # checkout" covers exactly what +read+ can reach. A server's index does not stop
    # at the root: it reaches the whole bundle, the JDK and four hundred transitive
    # jars, and the +jdt:+ content path reads text out of a jar nobody ever diffed.
    # Quoting third-party prose into the context in bulk is this gem's *marquee
    # feature*, not an edge case of it. The consequence is deliberate: on a trusted
    # checkout +read+ declares +:none+, so wiring +lsp+ beside +fetch+ or
    # +web_search+ can light the untrusted leg where nothing fired before.
    #
    # +egress_payload_review: :no_egress+, and *not* because the server is trusted:
    # a seat whose outbound bytes do not originate in the model's choosing holds no
    # leg to grade. +operation+, +symbol+, +file+ and +line+ reach an in-memory
    # index, never a socket. A registered server may go online on its own — jdtls
    # resolving a jar — but that traffic follows the project's build files and
    # happens identically if the model never issues a single call.
    #
    # +private:+ is inherited from the workspace, never claimed here: the host
    # already asked the human whether this project is private.
    #
    # == Sharing
    #
    # +P_one_agent+, and accepted as such: one wiring, one agent. Three things
    # bind it — a per-agent {Pikuri::Agent::Control::Cancellable}, a mutable
    # +on_progress+ hook installed after construction, and {Servers}, whose
    # open-document bookkeeping assumes one caller (a second agent's
    # +didClose+ can land on a document the first is still asking about).
    #
    # Ten agents over one project therefore means ten registries and ten sets
    # of child processes, which is the honest cost of not having built a shared
    # server pool. Nothing here refuses the sharing; it just goes wrong
    # quietly, so don't.
    class LspTool < Pikuri::Tool
      # Description shown to the LLM (opencode-shape). Per-parameter constraints
      # live in the parameter descriptions; the operation list is generated from
      # {Operation::ALL} so it cannot drift from what dispatch accepts.
      #
      # Two things it deliberately does *not* say, both of which an earlier draft
      # did. It does not mention that the first call waits for the server to
      # finish indexing — the model has no notion of time, so the only content in
      # that sentence is an implied promise that results are now complete, and a
      # fully-started server can still be broken. And it does not announce that an
      # unsupported operation refuses cleanly: the model learns that from the
      # refusal, which names the missing capability. What stays is mechanics —
      # how to anchor a call, what shapes the answer comes in — never a claim
      # about the *quality* of what comes back, which is the model's to judge.
      DESCRIPTION = <<~DESC
        Ask a language server about code: where a name is defined, who calls it, what it inherits from.

        Usage:
        - Anchor a query with `symbol` plus `file` and `line` — the line number as printed when you read the file or searched it. The column is worked out from that line's text, so it is never asked for.
        - `symbol` on its own searches every configured server's index instead. Best effort: a short name is matched against fully qualified ones and can score below a server's own threshold, and some servers index types but no methods.
        - Servers are configured per file type. A file type nothing claims is refused, never guessed at.
        - Results are capped and grouped, references and callers most aggressively; a truncation marker means there was more.
        - A server's index reaches outside the project, so a result may live in a dependency rather than in your code. Such a result always carries its line of code, and carries a path when this workspace can read that file — otherwise just the file's name, or the type's name and the archive it came from.

        Operations:
        #{Operation::ALL.map { |operation| "- #{operation.name} — #{operation.summary}" }.join("\n")}
      DESC

      # @return [Proc] called with a {ServerProgress}, on the calling thread, while
      #   a call waits for a server to finish indexing. A host installs its event
      #   emitter here after construction; the default drops them, which is what a
      #   tool built outside an agent wants.
      attr_accessor :on_progress

      # @param servers [Servers] started clients. The tool never spawns.
      # @param filesystem [Pikuri::Workspace::Filesystem] the project: path
      #   resolution, root confinement, the +denied?+ pass every walked path owes,
      #   and the +private?+ answer this tool's legs inherit.
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] what makes an
      #   unbounded index wait acceptable.
      def initialize(servers:, filesystem:, cancellable: nil)
        @servers = servers
        @filesystem = filesystem
        @cancellable = cancellable
        @on_progress = ->(_progress) {}
        tool = self
        super(
          name: 'lsp',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_enum :operation,
                            'Which question to ask; see the Operations list, ' \
                            'e.g. "goToDefinition".',
                            values: Operation.names
            p.required_string :symbol,
                              'The name to ask about, spelled exactly as the ' \
                              'source spells it, e.g. "resolve_for_read" or ' \
                              '"Pikuri::Workspace::Read".'
            p.optional_string :file,
                              'File the symbol is in, e.g. ' \
                              '"pikuri-workspace/lib/pikuri/workspace/read.rb". ' \
                              'Relative paths resolve against the workspace ' \
                              'root. Picks the language server and, with line, ' \
                              'anchors the query; without it every server\'s ' \
                              'index is searched. Required for documentSymbol, ' \
                              'and needed in practice for goToTypeDefinition, ' \
                              'whose usual target is a local variable that is in ' \
                              'no index.'
            p.optional_integer :line,
                               '1-based line the symbol appears on, as printed ' \
                               'when you read the file, e.g. 165. Needs file, ' \
                               'and the symbol must occur literally on that line.'
          },
          execute: lambda { |operation:, symbol:, file: nil, line: nil|
            tool.navigate(operation: operation, symbol: symbol, file: file, line: line)
          },
          trifecta_legs: Pikuri::Tool::TrifectaLegs.new(
            private: filesystem.private?,
            untrusted: :hard,
            egress_payload_review: :no_egress
          )
        )
      end

      # +LSP+, not the +Lsp+ the mechanical CamelCase produces: it is an acronym,
      # and a chrome shows this string to a human.
      #
      # @return [String]
      def display_name
        'LSP'
      end

      # Operation *and* symbol, because the first required parameter is the
      # operation enum and +LSP(references)+ says nothing about what was asked.
      #
      # @param arguments [Hash] raw tool-call arguments
      # @return [String]
      def describe_call(arguments)
        operation = arguments['operation'] || arguments[:operation]
        symbol = arguments['symbol'] || arguments[:symbol]
        Pikuri::Tool.one_line([operation, symbol].compact.join(' '))
      end

      # Run one call.
      #
      # A fresh {Navigator} per call, rather than one captured in the +execute+
      # lambda: {#on_progress} is installed *after* the tool is built, so a
      # navigator built once would keep emitting into the default no-op forever.
      #
      # @param operation [String]
      # @param symbol [String]
      # @param file [String, nil]
      # @param line [Integer, nil]
      # @return [Pikuri::Tool::Result] the renderer's observation (+"3
      #   results"+), or {Pikuri::Tool::Result.error} when the call was
      #   refused.
      def navigate(operation:, symbol:, file: nil, line: nil)
        Navigator.new(servers: @servers, filesystem: @filesystem,
                      on_progress: @on_progress, cancellable: @cancellable)
                 .navigate(operation: operation, symbol: symbol, file: file, line: line)
      end
    end
  end
end
