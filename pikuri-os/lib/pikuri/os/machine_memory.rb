# frozen_string_literal: true

require 'pathname'

module Pikuri
  module Os
    # Durable, cross-conversation memory for the OS helper — a single
    # user-owned +MACHINE.md+, the +AGENTS.md+-for-this-host. This class is
    # the *read* half (resolve the XDG path, load content, size-warn,
    # render the prompt section); the *write* half is the ordinary
    # (confirmed) +write+/+edit+ tools plus a prompt line pointing the agent
    # at {.default_path}. Narrative in book/os-assistant.md.
    #
    # A markdown file, not mem0: this agent reads untrusted local content
    # (logs, downloads), so auto-extracted memory could be poisoned. A file
    # makes that risk *visible + confirmed + reversible* — every write is a
    # plain-text diff through the confirmer, the whole memory is one
    # readable file — and needs no vector store or embedder, fitting the
    # "small enough to audit" posture.
    #
    # {#content} reads fresh on every call and {#prompt_section} is re-pulled
    # on every {Pikuri::Agent#clear_conversation}, so a user's or agent's
    # edit surfaces on the next "/clear" rather than freezing at boot. Read
    # a handful of times (boot + clears), never per turn.
    class MachineMemory
      LOGGER = Pikuri.logger_for('MachineMemory')

      # @return [String] the memory filename.
      FILENAME = 'MACHINE.md'

      # @return [Integer] soft size ceiling. On overshoot we log a warning to
      #   trim — mirrors the Claude CLI nudging an oversized AGENTS.md.
      #   No hard cap, no eviction: the file is prepended to every prompt,
      #   so a visible nudge is enough.
      OVERSIZE_BYTES = 10 * 1024

      # @return [Pathname] the resolved memory file path.
      attr_reader :path

      # @param path [String, Pathname] memory file location; defaults to
      #   {.default_path}. Overridable for tests.
      def initialize(path: self.class.default_path)
        @path = Pathname.new(path)
      end

      # Host-scoped path under pikuri's XDG config root
      # ({Pikuri::Paths.config} — +$XDG_CONFIG_HOME/pikuri+ or
      # +~/.config/pikuri+). Not project-local: for this agent the machine
      # *and the user's home* are the subject, so the notes span the whole
      # host.
      #
      # @return [String]
      def self.default_path
        Pikuri::Paths.config.join(FILENAME).to_s
      end

      # Raw file content, or +''+ when the file doesn't exist. Read
      # fresh on each call (not memoized) so a re-pull on conversation
      # clear picks up edits; logs the size-guard warning on each read.
      #
      # @return [String]
      def content
        read_content
      end

      # @return [Boolean] whether the content exceeds {OVERSIZE_BYTES}.
      def oversized?
        content.bytesize > OVERSIZE_BYTES
      end

      # The system-prompt section: the notes wrapped in a labeled block
      # naming the file (so the agent knows where its memory lives and can
      # update it), or +nil+ when there's nothing recorded yet — keeping
      # the prompt lean until there's something to say.
      #
      # @return [String, nil]
      def prompt_section
        text = content.strip
        return nil if text.empty?

        <<~SECTION.chomp
          # Notes about this machine

          Durable, user-owned notes about this computer (kept in #{@path}). Treat
          them as trusted context; edit the file to keep the notes current as you
          learn about this computer's setup.

          #{text}
        SECTION
      end

      private

      # @return [String]
      def read_content
        return '' unless @path.file?

        text = @path.read
        if text.bytesize > OVERSIZE_BYTES
          LOGGER.warn(
            "#{@path} is #{text.bytesize / 1024} KB (over the #{OVERSIZE_BYTES / 1024} KB " \
            'guideline); it is prepended to every prompt — consider trimming it.'
          )
        end
        text
      end
    end
  end
end
