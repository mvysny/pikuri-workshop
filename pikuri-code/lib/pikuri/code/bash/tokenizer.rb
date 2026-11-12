# frozen_string_literal: true

require 'set'

module Pikuri
  module Code
    class Bash
      # A deliberately narrow shell tokenizer: turns a command string into one
      # word list per *sequencer segment*, or +nil+ when it can't prove the
      # command is such a simple chain. It makes **no passivity judgement** —
      # that policy lives in {PassiveCommandDetector}, which classifies these
      # word lists. Lexing (here) is split from classification (the passive detector) so
      # a second consumer could reuse the parse.
      #
      # {.tokenize} returns +Array<Array<String>>+ — segments (cut on
      # {SEQUENCERS}) of de-quoted, de-redirected words, an empty list marking a
      # pure-comment no-op — or +nil+ meaning "more than a simple chain" (a
      # metacharacter, unsafe redirect, unbalanced quote, too many segments).
      # Conservative by contract: when in doubt it returns +nil+ so the caller
      # delegates to a human; it never silently drops a dangerous byte.
      #
      # +allow_glob:+ is the one knob: off (default) an unquoted glob/brace/
      # tilde ({GLOB_CHARS}) rejects like any metacharacter; on, it is kept as
      # a literal word byte and the *authorization* layer decides. This is
      # sound because those chars only ever expand to *words*, never to an
      # operator or a new command — so keeping them literal can't smuggle a
      # +;+/+|+/+$()+ past the lexer. The detector flips it on only for the
      # pure-allowlist glob fast path; see {PassiveCommandDetector}.
      #
      # == Why splitting on the sequencers is faithful
      #
      # {.split_segments} cuts only on a genuine control operator, never one
      # hidden inside a string: it tracks quote state (single *and* double) and
      # won't split inside a quoted span, and the backslash stays forbidden, so
      # nothing escapes a +;+/+|+/newline past it. Every *other* metacharacter
      # stays forbidden per segment, so an arbitrary-target redirect (+ps | grep
      # x > out+), a background +&+ (+ls & pwd+) or +|&+ trip the metacharacter
      # check ⇒ +nil+. The lone exception is a write-nothing redirect fragment
      # ({SAFE_REDIRECT}: +2>&1+, +2>/dev/null+ …), consumed and dropped — fd
      # duplication and +/dev/null+ discards add no capability.
      #
      # == Quote removal
      #
      # {.scan_segment} performs genuine shell quote-removal: the marks are
      # dropped and the interior kept *verbatim* and *literal*, so a quoted +|+
      # neither splits nor trips the gate (+echo 'a | b'+ is one echo). Single
      # quotes decode *unconditionally* — the POSIX interior is purely literal,
      # closed by the next +'+. Double quotes decode *only when verifiably
      # inert*: POSIX keeps three characters live inside +"..."+ — +$+
      # (expansion), the backtick (command substitution), +\+ (escaping) — so a
      # span containing any {DQUOTE_LIVE} byte returns +nil+ (delegate, never
      # guess), and one containing none is decoded like a single-quoted span.
      # This admits the common LLM shape +grep "foo bar" f+ while keeping the
      # failure mode "asks the human too often". An unbalanced quote → +nil+.
      #
      # Genuine quote-removal (not a placeholder rewrite) is what makes the
      # spelling-based classifiers in {PassiveCommandDetector} sound — the
      # cross-cutting "why the de-quoted word must be the *true* word, and why an
      # allowlist tolerates a shortcut a denylist doesn't" argument lives in
      # +pikuri-code/design/architecture.md+ (*The soundness hinge: true de-quoted words*).
      #
      # The classic mis-parse — +echo "a\"b; rm x"+, where a naive lexer closes
      # the span at the escaped quote and exposes the +;+ — cannot happen: the
      # scan bails on the +\+ *before* reaching the quote it escapes.
      # ({.split_segments}'s simpler tracker does close a span at an escaped
      # quote, but any command where that matters carries a +\+ outside single
      # quotes into *some* segment, which {.scan_segment} rejects — so the
      # divergence can only produce +nil+, never a mis-parsed approval.)
      #
      # Bash's fourth live character, +!+ (history expansion), is NOT gated
      # inside the span: it fires only in interactive shells, and {Bash} always
      # spawns +bash -c+ (histexpand off), so +echo "done!"+ is literal in every
      # shell this reaches. Outside quotes +!+ stays forbidden.
      module Tokenizer
        # Any shell metacharacter or ASCII control byte that, *outside* a quoted
        # span, means the segment is more than a single simple invocation ⇒
        # +nil+. {.scan_segment} consults this per character only after handling
        # quotes, whitespace, the {SAFE_REDIRECT} forms and {GLOB_CHARS}, so a
        # safe redirect's +>+/+&+ and every quoted-argument byte never reach it.
        #
        # The backslash +\+ stays here (still forbidden): decoding it would
        # reopen the parsing surface the quote handling avoids. The double quote
        # is *not* listed — like +'+ it is handled by {.scan_segment}'s quote
        # branches first. The glob/brace/tilde chars are *not* here either —
        # they live in {GLOB_CHARS}, which {.scan_segment} rejects by default
        # but keeps as literal word bytes under +allow_glob:+. Note +=+ is *not*
        # here (+--color=never+); a leading +VAR=val+ is caught because the
        # first word then isn't a bare allowed binary.
        SHELL_METACHARACTERS = /[;&|<>$`()\\!#\x00-\x1f]/

        # The shell *expansion* characters — pathname globbing (+*+ +?+
        # +[...]+), brace expansion (+{a,b}+), tilde expansion (+~+). Split out
        # of {SHELL_METACHARACTERS} because they are the one metacharacter class
        # that only ever expands to *words* (filenames/paths), never to an
        # operator or a new command (bash tokenizes operators *before*
        # expansion and never re-scans the result). {.scan_segment} rejects
        # them by default (⇒ +nil+, as before), but under +allow_glob: true+
        # keeps them as literal word bytes so the caller can classify them where
        # sound — see {.tokenize}'s +allow_glob:+ and the
        # {PassiveCommandDetector} glob fast path.
        GLOB_CHARS = /[*?\[\]{}~]/

        # The three characters POSIX keeps live inside +"..."+ — +$+
        # (expansion), the backtick (command substitution), +\+ (escaping,
        # including of the closing +"+). {.scan_segment} returns +nil+ when any
        # appears inside a double-quoted span; every other interior byte is
        # literal. See the class header on why +!+ is not gated.
        DQUOTE_LIVE = /[$`\\]/

        # Shell control operators that merely *sequence or pipe* commands.
        # {.split_segments} cuts on these outside quotes only (a quoted +|+/+;+
        # is literal data). Alternation order matters: two-char +&&+/+||+ before
        # single +|+ so +a || b+ splits into two segments, not three. A newline
        # is a command terminator like +;+; a literal newline would sit inside a
        # quoted span, where it is treated as data.
        SEQUENCERS = /&&|\|\||;|\||\n/

        # Defensive ceiling on sequencer-joined segments — a sanity backstop
        # against pathological input, set high enough to clear a real generated
        # batch (a +dpkg -S … || true+ probe per unit file across dozens of
        # files). Beyond it the whole command returns +nil+.
        MAX_CHAIN = 64

        # A redirect fragment that writes nothing. {.scan_segment} anchors this
        # at a +>+ (or +&>+) and, on a match, consumes and drops it (so the
        # +>+/+&+ never reaches the {SHELL_METACHARACTERS} gate); a
        # non-matching +>+ is a real redirect ⇒ +nil+. Two safe families:
        #
        # * fd *duplication* — +[n]>&[m]+ (+2>&1+ merges stderr into stdout):
        #   pure in-process fd-table manipulation, never a file.
        # * *discard* to +/dev/null+ — +[n|&]>[>] /dev/null+ (append forms too).
        #
        # The target is pinned to *exactly* +/dev/null+ by the +(?=\s|\z)+
        # lookahead, so a look-alike (+2>/dev/nullx+) does not match ⇒ +nil+, as
        # does any arbitrary-file redirect. +\s*+ accepts glued or spaced. The
        # leading +[0-9]*+ is the fd {.scan_segment} accumulated into the
        # current word (the +2+ of +2>&1+); it trims those digits on a match.
        SAFE_REDIRECT = %r{[0-9]*>&[0-9]+|(?:[0-9]|&)?>>?\s*/dev/null(?=\s|\z)}

        class << self
          # Parse the command into one word list per {SEQUENCERS} segment, or
          # +nil+ if it can't be safely analyzed as such a chain.
          #
          # @param command [String] the command (a +bin/pikuri-*+ caller should
          #   strip any +"$ "+ echo prefix first).
          # @param allow_glob [Boolean] when +true+, an unquoted {GLOB_CHARS}
          #   byte is kept as a literal word byte instead of rejecting the
          #   segment. Default +false+ (a glob ⇒ +nil+, the strict behavior).
          #   A quoted glob char is literal either way — this flag only affects
          #   *unquoted* ones. The caller opts in only where a post-expansion
          #   glob is provably harmless (see the {PassiveCommandDetector} glob
          #   fast path).
          # @return [Array<Array<String>>, nil] one de-redirected, de-quoted
          #   word list per segment (empty list = pure-comment no-op), or +nil+
          #   — more than {MAX_CHAIN} segments, an unbalanced quote, a
          #   {DQUOTE_LIVE} byte inside double quotes, an unquoted {GLOB_CHARS}
          #   byte (unless +allow_glob:+), or any segment empty (a dangling
          #   sequencer) or not a simple invocation.
          def tokenize(command, allow_glob: false)
            segments = split_segments(command)
            return nil if segments.nil?

            words_per_segment = segments.map { |s| scan_segment(s, allow_glob) }
            return nil if words_per_segment.any?(&:nil?)

            words_per_segment
          end

          private

          # Split the command into raw segment strings on {SEQUENCERS}, but only
          # *outside* quotes (a quoted operator stays literal data). Quote marks
          # are preserved here and removed per-segment by {.scan_segment}. This
          # tracker is escape-blind (closes a span at a +\"+ bash would treat as
          # escaped), safe because such a command carries a +\+ into some
          # segment that {.scan_segment} rejects — see the class header.
          #
          # @param command [String] the command.
          # @return [Array<String>, nil] the raw segments (quotes intact; empty
          #   strings kept, so a dangling operator yields an empty segment
          #   {.scan_segment} rejects), or +nil+ on an unbalanced quote or more
          #   than {MAX_CHAIN} segments.
          def split_segments(command)
            segments = []
            buf = +''
            quote = nil # the quote character we are inside, or nil
            i = 0
            while i < command.length
              char = command[i]
              if quote
                buf << char
                quote = nil if char == quote
                i += 1
              elsif char == "'" || char == '"'
                buf << char
                quote = char
                i += 1
              elsif (op = SEQUENCERS.match(command, i)) && op.begin(0) == i
                segments << buf
                buf = +''
                i += op[0].length
              else
                buf << char
                i += 1
              end
            end
            return nil if quote

            segments << buf
            segments.size > MAX_CHAIN ? nil : segments
          end

          # Reduce one sequencer segment to its de-quoted word list, or +nil+ to
          # reject the whole command. A left-to-right scan doing shell
          # quote-removal (the word handed back is the true argument, +--clear+
          # not +--_clear+ — see the class header). Outside quotes: whitespace
          # ends a word, a {SAFE_REDIRECT} fragment is consumed and dropped, a
          # {SHELL_METACHARACTERS} byte rejects, and a {GLOB_CHARS} byte rejects
          # unless +allow_glob+ (then it is kept literal, like any other byte).
          #
          # @param segment [String] one {SEQUENCERS} segment, not yet stripped.
          # @param allow_glob [Boolean] keep an unquoted {GLOB_CHARS} byte as a
          #   literal word byte instead of rejecting (see {.tokenize}).
          # @return [Array<String>, nil] the segment's de-quoted words with any
          #   {SAFE_REDIRECT} fragments removed; +[]+ for a pure-comment
          #   segment; or +nil+ — an empty segment, an unbalanced quote, a
          #   {DQUOTE_LIVE} byte inside double quotes, a {SHELL_METACHARACTERS}
          #   byte, an unquoted {GLOB_CHARS} byte (unless +allow_glob+), or a
          #   redirect that is not write-nothing.
          def scan_segment(segment, allow_glob = false)
            command = segment.strip
            return nil if command.empty?

            # A segment starting with +#+ is a shell comment — a no-op. Sound
            # because every segment boundary is a command separator, where +#+
            # genuinely opens a comment; a mid-segment +#+ (+ls #+) still trips
            # the gate below.
            return [] if command.start_with?('#')

            words = []
            word = nil          # current word buffer; nil between words
            quote = nil         # the quote character we are inside, or nil
            i = 0
            while i < command.length
              char = command[i]
              if quote == "'"
                # Single-quote interior: literal, never a separator/metachar.
                char == "'" ? (quote = nil) : (word = (word || +'') << char)
                i += 1
              elsif quote == '"'
                # Double-quote interior: literal too — unless one of the
                # POSIX-live bytes appears, which rejects the segment.
                if char == '"'
                  quote = nil
                elsif DQUOTE_LIVE.match?(char)
                  return nil
                else
                  word = (word || +'') << char
                end
                i += 1
              elsif char == "'" || char == '"'
                word ||= +''     # an opening quote starts a (maybe empty) word
                quote = char
                i += 1
              elsif char == ' ' || char == "\t"
                words << word unless word.nil?
                word = nil
                i += 1
              elsif char == '>' || (char == '&' && command[i + 1] == '>')
                # A redirect. Anchor {SAFE_REDIRECT} at the fd prefix (the
                # trailing digits of the current word, e.g. the +2+ of
                # +2>&1+), accepting only the write-nothing forms; anything
                # else (a real target) returns +nil+. The fd digits belonged
                # to the redirect, not the word, so trim them off.
                digits = char == '>' && word ? word[/\d*\z/].length : 0
                redirect = SAFE_REDIRECT.match(command, i - digits)
                return nil unless redirect && redirect.begin(0) == i - digits

                if digits.positive?
                  word = word[0...-digits]
                  word = nil if word.empty?
                end
                words << word unless word.nil?
                word = nil
                i = redirect.end(0)
              elsif GLOB_CHARS.match?(char)
                # An unquoted glob/brace/tilde byte. bash would *expand* it;
                # reject unless the caller opted into keeping it literal (then
                # it is treated exactly like any ordinary word byte below).
                return nil unless allow_glob

                word = (word || +'') << char
                i += 1
              elsif SHELL_METACHARACTERS.match?(char)
                return nil
              else
                word = (word || +'') << char
                i += 1
              end
            end
            return nil if quote

            words << word unless word.nil?
            words.empty? ? nil : words
          end
        end
      end
    end
  end
end
