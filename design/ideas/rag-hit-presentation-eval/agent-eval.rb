# frozen_string_literal: true

# Agent-level eval: the courts law agent answers eval/questions.yml once per rag_search
# presentation variant; scored on whether it cited and whether it read a gold section.
#
#   BUNDLE_GEMFILE=/home/mavi/work/my/courts/Gemfile bundle exec ruby agent-eval.rb OUT_DIR [N_QUESTIONS] [VARIANTS]
#
# Variants (all over the same index, no reranker):
#   none    - fused top 5, rank only (pikuri's working tree)
#   cosine  - fused top 5, each hit "(cosine=0.66)"
#   labels  - fused top 5, each hit "— meaning #1, keyword #4"
#   union10 - each leg's top 10 interleaved, header counts per leg, each hit labelled with the
#             meaning rank and/or keyword rank plus the query words it matched

require 'json'
require 'yaml'
require 'pikuri-rag'
require 'pikuri-stemmers'
require 'voikko'

COURTS = '/home/mavi/work/my/courts'
CORPUS = File.join(COURTS, 'corpus')
ACTS = { 'tsl' => '2001-55-tsl.md', 'vll' => '2005-162-vuosilomalaki.md',
         'tal' => '2019-872-tal.md', 'ytl' => '2021-1333-ytl.md' }.freeze
ACT_NAMES = { 'tsl' => 'työsopimuslai', 'vll' => 'vuosilomalai', 'tal' => 'työaikalai',
              'ytl' => 'yhteistoimintalai' }.freeze
MODEL = 'Ornith-1.5'
TIME_LIMIT = 600

config = YAML.safe_load_file(File.expand_path('~/.pikuri-examples-config.yaml'))
server = SERVER = config.fetch('llm_server')
api_key = API_KEY = config.fetch('llm_api_key', 'not-needed')

# --- gold section line ranges, as bin/embedder-eval --------------------------------------------
def section_ranges
  ACTS.to_h do |act, file|
    lines = File.readlines(File.join(CORPUS, file), chomp: true)
    heads = lines.each_index.select { |i| lines[i].match?(/\A##+ /) }
    ranges = heads.each_with_index.filter_map do |i, k|
      m = lines[i].match(/\A### (\d+(?: [a-z])?) luku (\d+(?: [a-z])?) §/) or next
      ["#{m[1]}:#{m[2]}".delete(' '), [i + 1, heads[k + 1] || lines.size]]
    end
    [act, ranges.to_h]
  end
end
GOLD_RANGES = section_ranges

# --- the index, once -----------------------------------------------------------------------------
voikko = Voikko.new(language: 'fi')
STEMMER = Pikuri::Stemmers::Voikko.new(voikko)
EMBEDDER = Pikuri::VectorDb::Embedder.new(server: server, model: config.fetch('embed_model'), api_key: api_key)
vector_server = Pikuri::VectorDb::Server::InMemory.ensure_running
RAG_CORPUS = Pikuri::VectorDb::Corpus.new(
  backend: Pikuri::Rag::Backend::Hybrid.new(vectors:  vector_server.client(collection: 'agent-eval'),
                                            keywords: Pikuri::Rag::Backend::Fts5.new(stemmer: STEMMER)),
  source: CORPUS, embedder: EMBEDDER
)
warn "indexed #{RAG_CORPUS.index_all!} chunks"

# --- the variants: rag_search's execute, per thread ----------------------------------------------
Search = Pikuri::Rag::Tools::Search
VSearch = Pikuri::VectorDb::Tools::Search
ORIGINAL = Search.method(:execute)

def stems_of_text(text)
  Pikuri::Rag::Query.tokenize(text).flat_map { |w| STEMMER.index_stems(w) }.to_set
end

def matched_words(query, chunk)
  have = stems_of_text(chunk.text)
  Pikuri::Rag::Query.tokenize(query).uniq.select { |w| STEMMER.stems(w).any? { |s| have.include?(s) } }
end

def block(i, result, label)
  snippet = result.chunk.text
  snippet = snippet[0, VSearch::SNIPPET_LENGTH] + '...' if snippet.length > VSearch::SNIPPET_LENGTH
  m = result.chunk.metadata
  "[#{i + 1}] #{result.chunk.source} lines #{m[:first_line]}-#{m[:last_line]}#{label}\n#{snippet}"
end

# RRF as rag_search fuses, but the vector leg's #1 pinned first — union10's one edge, at the
# fused list's cost: the same hits, reordered.
def vector_first(vec, kw)
  fused = Search.fuse(vec, kw)
  return fused if vec.empty?

  top = fused.find { |r| r.chunk.id == vec.first.chunk.id }
  [top, *fused.reject { |r| r.equal?(top) }]
end

def variant_execute(variant, embedder:, backend:, reranker:, query:)
  return ORIGINAL.call(embedder: embedder, backend: backend, reranker: reranker, query: query) if variant == 'none'
  return Pikuri::Tool::Result.error('query is empty') if query.nil? || query.strip.empty?

  vector = embedder.embed([query]).first
  all_vec = backend.query(vector: vector, top_k: 10_000)
  cos = all_vec.to_h { |r| [r.chunk.id, r.score] }
  vec = all_vec.first(Search::LEG_K)
  match = Pikuri::Rag::Query.any(query, stemmer: backend.stemmer)
  kw = match ? backend.keyword_query(match: match, top_k: Search::LEG_K) : []
  vrank = vec.each_with_index.to_h { |r, i| [r.chunk.id, i + 1] }
  krank = kw.each_with_index.to_h { |r, i| [r.chunk.id, i + 1] }

  if variant == 'union10'
    hits = (0...Search::LEG_K).flat_map { |i| [vec[i], kw[i]] }.compact.uniq { |r| r.chunk.id }
    both = hits.count { |r| vrank[r.chunk.id] && krank[r.chunk.id] }
    header = "Found #{hits.size} matches: #{vec.size} by meaning, #{kw.size} by keyword" \
             "#{both.positive? ? " (#{both} found by both)" : ''}.\n\n"
    body = hits.each_with_index.map do |r, i|
      parts = []
      parts << "meaning ##{vrank[r.chunk.id]}" if vrank[r.chunk.id]
      if krank[r.chunk.id]
        words = matched_words(query, r.chunk)
        parts << "keyword ##{krank[r.chunk.id]}#{words.empty? ? '' : " #{words.map { |w| "'#{w}'" }.join(', ')}"}"
      end
      block(i, r, " — #{parts.join(', ')}")
    end
  elsif variant == 'vfirst'
    fused = vector_first(vec, kw).first(Search::FINAL_K)
    return Pikuri::Tool::Result.new(content: 'No matches found in the indexed corpus.', summary: 'Found 0 matches') if fused.empty?

    header = "Found #{fused.size} match#{'es' unless fused.size == 1}.\n\n"
    body = fused.each_with_index.map { |r, i| block(i, r, '') }
  else
    fused = Search.fuse(vec, kw).first(Search::FINAL_K)
    return Pikuri::Tool::Result.new(content: 'No matches found in the indexed corpus.', summary: 'Found 0 matches') if fused.empty?

    header = "Found #{fused.size} match#{'es' unless fused.size == 1}.\n\n"
    body = fused.each_with_index.map do |r, i|
      label = if variant == 'cosine'
                format(' (cosine=%.2f)', cos.fetch(r.chunk.id))
              else
                parts = []
                parts << "meaning ##{vrank[r.chunk.id]}" if vrank[r.chunk.id]
                parts << "keyword ##{krank[r.chunk.id]}" if krank[r.chunk.id]
                " — #{parts.join(', ')}"
              end
      block(i, r, label)
    end
  end
  Pikuri::Tool::Result.new(content: header + body.join("\n\n"), summary: "Found #{body.size} matches")
end

Search.define_singleton_method(:execute) do |**kw|
  variant_execute(Thread.current[:variant], **kw)
end

# --- one agent run --------------------------------------------------------------------------------
class Recorder < Pikuri::Agent::Listener::Base
  attr_reader :calls, :answers, :tokens

  def initialize
    @calls = []
    @answers = []
    @tokens = { input: 0, output: 0 }
  end

  def on_event(event)
    case event
    in Pikuri::Agent::Event::ToolCall(name:, arguments:)
      @calls << { 'name' => name, 'args' => arguments }
    in Pikuri::Agent::Event::Assistant(content:)
      @answers << content
    in Pikuri::Agent::Event::Tokens(input:, output:)
      @tokens[:input] += input.to_i
      @tokens[:output] += output.to_i
    else
      nil
    end
  end
end

SYSTEM_PROMPT = [File.read(File.join(COURTS, 'prompts', 'law-agent.txt')).rstrip,
                 Pikuri.prompt(:'agent-loop').rstrip].join("\n\n") +
                "\n\nCurrent date: #{Time.now.strftime('%Y-%m-%d')}"

def gold_of(entry)
  entry['gold'].map do |ref|
    act, sec = ref.split
    first, last = GOLD_RANGES.fetch(act).fetch(sec)
    ch, s = sec.split(':')
    { 'act' => act, 'file' => ACTS.fetch(act), 'first' => first, 'last' => last, 'chapter' => ch, 'section' => s }
  end
end

def cited?(answer, g)
  sec = g['section'].sub(/([a-z])\z/, '\s*\1')
  name = ACT_NAMES.fetch(g['act'])
  long = /#{name}\w*\s+#{g['chapter']}\s+luvun\s+(?:[\d\s,–-]*(?:ja|sekä)\s+)?#{sec}\s*§/i
  short = /\b#{g['act']}\s*#{g['chapter']}\s*:\s*#{sec}\b/i
  answer.match?(long) || answer.match?(short)
end

def read?(calls, g)
  calls.any? do |c|
    next false unless c['name'] == 'rag_read'

    args = c['args'].transform_keys(&:to_s)
    next false unless File.basename(args['source'].to_s) == g['file']

    offset = (args['offset'] || 1).to_i
    limit = (args['limit'] || Pikuri::Extractor::PAGE_DEFAULT_LIMIT).to_i
    offset <= g['last'] && offset + limit - 1 >= g['first']
  end
end

def run_one(entry, variant, server:, api_key:)
  Thread.current[:variant] = variant
  recorder = Recorder.new
  cancellable = Pikuri::Agent::Control::Cancellable.new
  agent = Pikuri::Agent.new(
    transport: Pikuri::Agent::ChatTransport.from_openai_server(server: server, model: MODEL, api_key: api_key),
    system_prompt: SYSTEM_PROMPT, cancellable: cancellable, streaming: false
  ) do |c|
    c.add_listener recorder
    # The extension's tools over the one shared index, by hand: no rag_reindex.
    legs = Pikuri::VectorDb::CorpusLegs.derive(private: false, trusted: true)
    c.add_tool Search.new(embedder: EMBEDDER, backend: RAG_CORPUS.backend, legs: legs)
    c.add_tool Pikuri::Rag::Tools::SearchKeywords.new(backend: RAG_CORPUS.backend, root: RAG_CORPUS.root, legs: legs)
    c.add_tool Pikuri::VectorDb::Tools::Read.new(backend: RAG_CORPUS.backend, root: RAG_CORPUS.root, legs: legs,
                                                 family: Pikuri::Rag::Extension::FAMILY)
  end
  started = Time.now
  timer = Thread.new { sleep TIME_LIMIT; cancellable.cancel! }
  error = nil
  begin
    agent.run_loop(user_message: entry['q'])
  rescue Pikuri::Agent::Control::Cancellable::Cancelled
    error = 'timeout'
  rescue StandardError => e
    error = "#{e.class}: #{e.message[0, 200]}"
  ensure
    timer.kill
    agent.close
  end
  answer = recorder.answers.last.to_s
  gold = gold_of(entry)
  { 'q' => entry['q'], 'kind' => entry.fetch('kind', 'paraphrase'), 'gold' => entry['gold'], 'variant' => variant,
    'cited' => gold.any? { |g| cited?(answer, g) }, 'read' => gold.any? { |g| read?(recorder.calls, g) },
    'searches' => recorder.calls.count { |c| c['name'] == 'rag_search' },
    'calls' => recorder.calls.size, 'tokens' => recorder.tokens, 'seconds' => (Time.now - started).round(1),
    'error' => error, 'tool_calls' => recorder.calls, 'answer' => answer }
end

QUESTIONS = YAML.load_file(File.join(COURTS, 'eval', 'questions.yml'))
return if defined?(LIBRARY_ONLY) # pick.rb loads the index, the variants and the gold from here

out_dir = ARGV[0] or abort 'usage: agent-eval.rb OUT_DIR [N] [variants,comma,separated]'
n_questions = (ARGV[1] || 1000).to_i
variants = (ARGV[2] || 'none,cosine,labels,union10').split(',')
Dir.mkdir(out_dir) unless Dir.exist?(out_dir)
questions = QUESTIONS.first(n_questions)
if ENV['PREVIEW']
  variants.each do |v|
    puts "=== #{v}", variant_execute(v, embedder: EMBEDDER, backend: RAG_CORPUS.backend, reranker: nil,
                                      query: ENV['PREVIEW']).content.gsub(/^(?!\[|Found).*\n?/, '')
  end
  exit
end
threads = variants.map do |variant|
  Thread.new do
    path = File.join(out_dir, "#{variant}.jsonl")
    done = File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l)['q'] } : []
    questions.each_with_index do |entry, i|
      next if done.include?(entry['q'])

      row = run_one(entry, variant, server: server, api_key: api_key)
      File.open(path, 'a') { |f| f.puts(JSON.generate(row)) }
      warn format('%-8s %2d/%d cited=%-5s read=%-5s calls=%2d %5.0fs %s', variant, i + 1, questions.size,
                  row['cited'], row['read'], row['calls'], row['seconds'], row['error'] || '')
    end
  end
end
threads.each(&:join)
RAG_CORPUS.close # and with it the Voikko handle
vector_server.close
