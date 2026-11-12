# frozen_string_literal: true

module Pikuri
  module Command
    # Expands a {Registry::Command} into the text a host sends as the *user's*
    # turn. Stateless.
    #
    #   body:  "Weekly log for $ARGUMENTS, Monday through today."
    #   expand(cmd, arguments: 'swingai')
    #   # => "Weekly log for swingai, Monday through today."
    #
    # A body that only *mentions* the token keeps it — the span is code — and
    # the arguments arrive in the tail instead, which is exactly what
    # +~/.claude/commands/wh.md+ does:
    #
    #   body:  "Read the label off `$ARGUMENTS`."
    #   expand(cmd, arguments: 'swingai')
    #   # => "Read the label off `$ARGUMENTS`.\n\n\nARGUMENTS: swingai"
    #
    # The result is a *plain* user message — the interloper's +:user+ kind, not
    # its +:system+ one: +/wh swingai+ is the human's request typed short, so
    # +on_user_message+ must fire (a memory layer that never sees it is a silent
    # hole) and it must not arrive wrapped as reference text.
    #
    #   agent.run_loop(user_message: text)       # synchronous host
    #   interloper.inject_user_message(text)     # async host, mid-loop
    #
    # == What gets substituted
    #
    # +$ARGUMENTS+ is everything typed after the command name, verbatim.
    # +$1+…+$9+ index that string split on whitespace, **1-based** — the one
    # place this diverges from Claude Code 2.1.233, which is 0-based in the
    # binary while being 1-based in its own docs and in every body anyone
    # writes. An out-of-range +$n+ stays literal, as it does there: a
    # placeholder that silently vanishes is worse than one a human can see in
    # the transcript.
    #
    # There is no quote handling and no flag parsing: +/foo "two words"+ is
    # three tokens. A body that wants either reads +$ARGUMENTS+, which is what
    # it meant.
    #
    # == Fenced blocks and code spans are skipped
    #
    # Substitution ignores +```+ blocks and +`inline spans`+, because a false
    # positive here is *silent corruption of an instruction*: a body writing
    # about its own arguments ("read it off +`$ARGUMENTS`+ rather than +`$1`+")
    # would otherwise have that sentence rewritten into nonsense, and a body
    # emitting a shell script would have its +"$1"+ hardcoded to one
    # invocation.
    #
    # Note that {Registry}'s <code>!`cmd`</code> *detection* is deliberately
    # fence-**blind** while this is fence-**aware**. Not an inconsistency: they
    # answer different questions about the same characters, and the failure
    # directions are opposite — a false positive there is a loud exception on
    # an editable file, here it is silent damage. Don't "fix" one to match the
    # other.
    #
    # == The two tails
    #
    # When the body references neither placeholder anywhere outside code, the
    # arguments are appended as +ARGUMENTS: <raw>+ — Claude Code's exact
    # spelling, so a body authored against it reads identically here. That
    # rule and the skipping above are one pass over one tokenization on
    # purpose: read the body blind and a file whose every +$ARGUMENTS+ is
    # backticked counts as "referenced", gets no append, gets no substitution,
    # and silently loses what the human typed.
    #
    # A +(this command lives in …)+ footer follows when the command has
    # sidecars, giving the model a base directory to resolve a path against —
    # since +@path+ inlining is deliberately not implemented, a path in the
    # body stays literal text and reaches the file only through the gated
    # +read+ tool.
    module Renderer
      module_function

      # @param command [Pikuri::Command::Registry::Command]
      # @param arguments [String] everything typed after the command name
      # @return [String] the user turn to send
      def expand(command, arguments: '')
        raw = arguments.to_s
        tokens = raw.split
        segments = segment(command.body)

        text = segments.map { |chunk, code| code ? chunk : substitute(chunk, raw, tokens) }.join
        unless raw.strip.empty? || segments.any? { |chunk, code| !code && references?(chunk) }
          text = "#{text.rstrip}\n\n\nARGUMENTS: #{raw}"
        end
        text = "#{text.rstrip}\n\n(this command lives in #{File.dirname(command.location)})" if command.sidecars?
        text
      end

      # @param text [String]
      # @return [Boolean] whether +text+ names either placeholder
      def references?(text)
        text.match?(/\$ARGUMENTS/) || text.match?(/\$[1-9]/)
      end
      private_class_method :references?

      # @param text [String] one prose chunk, no code in it
      # @param raw [String]
      # @param tokens [Array<String>]
      # @return [String]
      def substitute(text, raw, tokens)
        text.gsub(/\$ARGUMENTS|\$([1-9])/) do
          index = Regexp.last_match(1)
          index ? tokens[index.to_i - 1] || Regexp.last_match(0) : raw
        end
      end
      private_class_method :substitute

      # Split a body into +[chunk, code?]+ pairs covering every character, so
      # the caller can rebuild it with +join+.
      #
      # @param body [String]
      # @return [Array<Array(String, Boolean)>]
      def segment(body)
        chunks = []
        fence = nil

        body.each_line do |line|
          if fence
            chunks << [line, true]
            fence = nil if line.match?(/\A {0,3}#{fence[0]}{#{fence.length},}\s*\z/)
          elsif (opener = line.match(/\A {0,3}(`{3,}|~{3,})/))
            fence = opener[1]
            chunks << [line, true]
          else
            chunks.concat(split_spans(line))
          end
        end

        chunks
      end
      private_class_method :segment

      # @param line [String]
      # @return [Array<Array(String, Boolean)>] the line's prose and its
      #   +`code spans`+, in order; a span is delimited by a backtick run of
      #   matching length, as Markdown defines it
      def split_spans(line)
        chunks = []
        pos = 0

        while (span = line.match(/(`+)(?:(?!\1).)*\1/, pos))
          chunks << [line[pos...span.begin(0)], false] if span.begin(0) > pos
          chunks << [span[0], true]
          pos = span.end(0)
        end
        chunks << [line[pos..], false] if pos < line.length

        chunks
      end
      private_class_method :split_spans
    end
  end
end
