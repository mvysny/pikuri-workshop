# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Chunker
      # Sliding-window chunker: splits text on whitespace into words, then walks
      # forward emitting ~+size+-token chunks, each after the first re-including
      # +overlap+ tokens of the previous chunk's tail so an answer straddling a
      # boundary stays intact in at least one chunk (standard RAG practice).
      #
      #   FixedWindow.new(size: 3, overlap: 1, tokenizer: one_token_per_word).chunk("a b\nc d\n\ne")
      #   # => [Piece(text: "a b c", first_line: 1, last_line: 2),
      #   #     Piece(text: "c d e", first_line: 2, last_line: 4)]
      #
      # A piece's text is its words joined by single spaces, newlines gone:
      # a snippet that kept them could pose as search output
      # (+"bla\n\n[2] secrets.md lines 1-5"+ reads as a second hit). The
      # layout survives only as the line range.
      #
      # Whitespace-split gives word boundaries for Western-European languages —
      # good enough for any text {Pikuri::FileType.read_as_text} flattens to
      # prose; CJK (no whitespace) degrades to one-huge-unit chunks, a documented
      # limitation.
      #
      # *Per-chunk tokenizer cost*: the greedy "add a word, re-count" algorithm
      # calls +tokenizer.count+ O(n_words × chunks) times — negligible for
      # {Tokenizer::CharHeuristic}, but a tokenizer behind an HTTP round-trip
      # would turn indexing a large corpus into minutes.
      #
      # *Forward-progress guard*: the constructor rejects +overlap >= size+, and
      # the inner loop always advances at least one word — termination holds even
      # if a pathological tokenizer reports misleading counts.
      class FixedWindow
        # @return [Integer] target token count per chunk.
        attr_reader :size

        # @return [Integer] tokens of overlap between adjacent
        #   chunks.
        attr_reader :overlap

        # @param size [Integer] target token count per chunk.
        #   Must be positive. Common values: 256, 512, 1024 —
        #   pick to match the embedder's context (e.g. 512 for
        #   bge-small-en-v1.5).
        # @param overlap [Integer] tokens of overlap between
        #   adjacent chunks. Must be +>= 0+ and strictly less
        #   than +size+. Common values: ~10% of size.
        # @param tokenizer [#count] a {Tokenizer}; anything
        #   responding to +count(text) -> Integer+. Defaults to
        #   {Tokenizer::CharHeuristic} (zero-dep,
        #   ~4-chars-per-token approximation).
        # @return [FixedWindow]
        # @raise [ArgumentError] on invalid +size+ or +overlap+.
        def initialize(size:, overlap: 0, tokenizer: Tokenizer::CharHeuristic.new)
          raise ArgumentError, "size must be positive (got #{size})" if size <= 0
          raise ArgumentError, "overlap must be >= 0 (got #{overlap})" if overlap.negative?
          if overlap >= size
            raise ArgumentError,
                  "overlap (#{overlap}) must be strictly less than size (#{size}) " \
                  "— the sliding window would not advance"
          end

          @size = size
          @overlap = overlap
          @tokenizer = tokenizer
        end

        # Chunk +text+ into approximately +size+-token windows
        # with +overlap+-token tail repeats. Empty /
        # whitespace-only input returns +[]+.
        #
        # @param text [String]
        # @return [Array<Piece>] non-empty pieces, in source
        #   order. May be empty.
        def chunk(text)
          words, lines = words_with_lines(text)
          return [] if words.empty?

          chunks = []
          start = 0
          while start < words.length
            finish = find_chunk_end(words, start)
            chunks << Piece.new(text: words[start...finish].join(' '),
                                first_line: lines[start], last_line: lines[finish - 1])

            break if finish >= words.length

            start = find_next_start(words, start, finish)
          end

          chunks
        end

        private

        # Split +text+ into the same words as +String#split+, each with its
        # 1-based line number. Only +"\n"+ advances the line — a lone CR is
        # whitespace like any other, per {Pikuri::Extractor}'s == Lines.
        #
        # @param text [String]
        # @return [Array(Array<String>, Array<Integer>)] parallel arrays.
        def words_with_lines(text)
          words = []
          lines = []
          line = 1
          text.scan(/\n|\S+/) do |token|
            if token == "\n"
              line += 1
            else
              words << token
              lines << line
            end
          end
          [words, lines]
        end

        # Walk forward from +start+ adding one word at a time
        # until +tokenizer.count+ exceeds +@size+, returning the
        # exclusive end index. Always advances at least one word
        # so a single oversized word still becomes a chunk (the
        # embedder truncates rather than the chunker silently
        # dropping the word).
        def find_chunk_end(words, start)
          finish = start + 1
          while finish < words.length
            candidate = words[start...(finish + 1)].join(' ')
            break if @tokenizer.count(candidate) > @size

            finish += 1
          end
          finish
        end

        # Find the index where the next chunk should start so
        # that words[next_start...finish] is approximately
        # +@overlap+ tokens. Walks backward from +finish+ until
        # the back-window crosses the overlap budget. Always
        # advances at least one word past +start+ to guarantee
        # forward progress.
        def find_next_start(words, start, finish)
          return finish if @overlap.zero?

          next_start = finish
          while next_start > start + 1
            window = words[(next_start - 1)...finish].join(' ')
            break if @tokenizer.count(window) > @overlap

            next_start -= 1
          end
          [next_start, start + 1].max
        end
      end
    end
  end
end
