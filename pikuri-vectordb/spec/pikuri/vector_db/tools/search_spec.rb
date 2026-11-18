# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Tools::Search do
  # Real Backend::InMemory — lightweight, no stubs needed.
  # Tested in its own spec, trusted here.
  let(:backend) { Pikuri::VectorDb::Backend::InMemory.new }

  # Deterministic fake embedder: returns one fixed vector per
  # text. The query vector matches v_a so risotto wins
  # top-of-result ordering when we want to assert format.
  let(:fake_embedder) do
    fake = Object.new
    def fake.embed(texts)
      texts.map { |_t| [1.0, 0.0, 0.0] }
    end
    fake.singleton_class.send(:attr_reader, :captured)
    fake.instance_variable_set(:@captured, [])
    fake.singleton_class.send(:define_method, :embed) do |texts|
      @captured << texts
      texts.map { |_t| [1.0, 0.0, 0.0] }
    end
    fake
  end

  def populate_backend
    chunks = [
      Pikuri::VectorDb::Chunk.new(
        id: 'risotto.md:0', source: 'risotto.md',
        text: 'Rice should be added gradually after toasting the butter.',
        metadata: { ordinal: 0, first_line: 1, last_line: 3 }
      ),
      Pikuri::VectorDb::Chunk.new(
        id: 'risotto.md:1', source: 'risotto.md',
        text: 'For risotto, the key is the gradual addition of broth.',
        metadata: { ordinal: 1, first_line: 3, last_line: 3 }
      ),
      Pikuri::VectorDb::Chunk.new(
        id: 'paella.md:0', source: 'paella.md',
        text: 'Paella uses short-grain rice but cooked in one shot.',
        metadata: { ordinal: 0 }
      )
    ]
    vectors = [[1.0, 0.0, 0.0], [0.9, 0.1, 0.0], [0.0, 1.0, 0.0]]
    backend.upsert(chunks: chunks, vectors: vectors)
  end

  # +.to_s+ because the observation is a Pikuri::Tool::Result; the display
  # line has its own tests below.
  def execute(query: 'how to cook risotto?', reranker: nil)
    result(query: query, reranker: reranker).to_s
  end

  def result(query: 'how to cook risotto?', reranker: nil)
    Pikuri::VectorDb::Tools::Search.execute(
      embedder: fake_embedder, backend: backend,
      reranker: reranker, query: query
    )
  end

  describe 'as a Pikuri::Tool' do
    it 'is named vectordb_search' do
      tool = Pikuri::VectorDb::Tools::Search.new(embedder: fake_embedder, backend: backend,
                                                 legs: Pikuri::Tool::TrifectaLegs::NONE)
      assert_equal 'vectordb_search', tool.name
    end

    it 'declares a single required-string query parameter' do
      tool = Pikuri::VectorDb::Tools::Search.new(embedder: fake_embedder, backend: backend,
                                                 legs: Pikuri::Tool::TrifectaLegs::NONE)
      schema = tool.parameters.to_openai
      assert_equal ['query'], schema[:required]
      props = schema[:properties]
      query_schema = props[:query] || props['query']
      assert_equal 'string', query_schema[:type] || query_schema['type']
    end
  end

  describe '#execute happy path (no reranker)' do
    before { populate_backend }

    it 'returns a header + numbered blocks with source + line range + snippet, no score' do
      observation = execute

      assert_includes observation, 'Found 3 matches.'
      assert_includes observation, "[1] risotto.md lines 1-3\n"
      assert_includes observation, 'Rice should be added gradually'
      assert_includes observation, "[2] risotto.md line 3\n"
      # paella.md:0 carries no line range — a chunk not written by the Corpus.
      assert_includes observation, "[3] paella.md\n"
      refute_includes observation, 'score'
    end

    it 'asks the backend for FINAL_K candidates when no reranker is configured' do
      # Backend gets a top_k matching FINAL_K, not CANDIDATE_K
      executed_top_k = nil
      orig = backend.method(:query)
      backend.define_singleton_method(:query) do |vector:, top_k:|
        executed_top_k = top_k
        orig.call(vector: vector, top_k: top_k)
      end

      execute

      assert_equal Pikuri::VectorDb::Tools::Search::FINAL_K, executed_top_k
    end
  end

  describe 'the display line' do
    before { populate_backend }

    it 'counts the matches and never carries corpus text' do
      display = result.summary

      assert_equal 'Found 3 matches', display
      refute_includes display, 'Rice should be added gradually'
    end

    it 'says zero rather than going silent on an empty corpus' do
      assert_equal 'Found 0 matches',
                   Pikuri::VectorDb::Tools::Search.execute(embedder: fake_embedder,
                                                           backend: Pikuri::VectorDb::Backend::InMemory.new,
                                                           reranker: nil, query: 'anything').summary
    end
  end

  describe '#execute happy path (with reranker)' do
    before { populate_backend }

    # Reranker that reverses the order — easy to spot in
    # the observation that the rerank ran.
    let(:reversing_reranker) do
      r = Object.new
      def r.rerank(query:, documents:)
        documents.each_with_index.map do |_d, i|
          # Reverse: last document gets highest score.
          Pikuri::VectorDb::Reranker::Hit.new(
            index: documents.length - 1 - i,
            score: documents.length - i.to_f
          )
        end.sort_by { |h| -h.score }
      end
      r
    end

    it 'asks the backend for CANDIDATE_K candidates when a reranker is configured' do
      executed_top_k = nil
      orig = backend.method(:query)
      backend.define_singleton_method(:query) do |vector:, top_k:|
        executed_top_k = top_k
        orig.call(vector: vector, top_k: top_k)
      end

      execute(reranker: reversing_reranker)

      assert_equal Pikuri::VectorDb::Tools::Search::CANDIDATE_K, executed_top_k
    end

    it 'reorders candidates by the reranker output' do
      # Without rerank, vector order is risotto (1.0), risotto (0.9), paella (0.0).
      # The reversing reranker flips it.
      observation = execute(reranker: reversing_reranker)

      first_block = observation.split("\n\n")[1]
      assert_includes first_block, 'paella.md'
    end

    it 'returns at most FINAL_K results even from a wider candidate set' do
      # Populate with 10 chunks, all matching the query.
      backend.delete_all
      chunks = (0...10).map do |i|
        Pikuri::VectorDb::Chunk.new(
          id: "doc:#{i}", source: "doc#{i}.md", text: "text #{i}", metadata: {}
        )
      end
      vectors = chunks.map { [1.0, 0.0, 0.0] }
      backend.upsert(chunks: chunks, vectors: vectors)

      observation = execute(reranker: reversing_reranker)

      # Count "[i]" markers
      assert_equal Pikuri::VectorDb::Tools::Search::FINAL_K, observation.scan(/^\[\d+\]/).length
    end
  end

  describe '#execute reranker outage' do
    before { populate_backend }

    let(:broken_reranker) do
      r = Object.new
      def r.rerank(query:, documents:)
        raise 'Reranker::LlamaServer: HTTP 503 ...'
      end
      r
    end

    it 'falls back to vector-only top-k and emits a WARN' do
      log_buf = StringIO.new
      original_io = Pikuri.log_io
      Pikuri.log_io = log_buf
      Pikuri::VectorDb::Tools::Search::LOGGER.instance_variable_get(:@logdev).instance_variable_set(:@dev, log_buf)

      begin
        observation = execute(reranker: broken_reranker)

        # Observation is still produced — degraded, not failed.
        assert_includes observation, 'Found '
        # And the vector order (not reranker order) appears.
        assert_includes observation, "[1] risotto.md lines 1-3\n"
      ensure
        Pikuri.log_io = original_io
      end

      # Hard to assert the log line content portably across
      # logger guts — assert *that* something was logged at WARN
      # via the message-string we know we emit.
      assert_includes log_buf.string, 'reranker outage'
    end
  end

  describe '#execute degenerate inputs' do
    it 'returns Error on empty query' do
      assert_equal 'Error: query is empty',
                   execute(query: '')
    end

    it 'returns Error on whitespace-only query' do
      assert_equal 'Error: query is empty',
                   execute(query: "  \n\t ")
    end

    it 'returns "No matches found" when the backend is empty' do
      assert_equal 'No matches found in the indexed corpus.',
                   execute(query: 'anything')
    end
  end

  describe '#execute snippet truncation' do
    it 'truncates snippets longer than SNIPPET_LENGTH chars with "..."' do
      long_text = 'x' * (Pikuri::VectorDb::Tools::Search::SNIPPET_LENGTH + 100)
      chunk = Pikuri::VectorDb::Chunk.new(
        id: 'big:0', source: 'big.md', text: long_text, metadata: {}
      )
      backend.upsert(chunks: [chunk], vectors: [[1.0, 0.0, 0.0]])

      observation = execute

      # snippet portion (after the header line) ends in "..."
      assert_includes observation, '...'
      # Snippet length is capped; total observation is bounded.
      snippet_len = Pikuri::VectorDb::Tools::Search::SNIPPET_LENGTH
      assert_operator observation.length, :<, snippet_len + 200 # snippet + header overhead
    end

    it 'leaves short snippets untruncated' do
      chunk = Pikuri::VectorDb::Chunk.new(
        id: 's:0', source: 's.md', text: 'short.', metadata: {}
      )
      backend.upsert(chunks: [chunk], vectors: [[1.0, 0.0, 0.0]])

      observation = execute

      assert_includes observation, 'short.'
      # No "..." truncation marker appended
      assert_match(/^short\.$/, observation.lines.last.chomp)
    end
  end
end
