# frozen_string_literal: true

# Pick-the-hit test: the model sees a question and ONE rag_search result in a variant's format,
# and names the hit that answers it. No agent loop, no reading, no table of contents — so a
# capable model cannot cover for a weak list, and only the presentation differs.
#
#   BUNDLE_GEMFILE=/home/mavi/work/my/courts/Gemfile bundle exec ruby pick.rb MODEL OUT.jsonl [REPEATS] [VARIANTS]

LIBRARY_ONLY = true
require_relative 'agent-eval'

model = ARGV[0] or abort 'usage: pick.rb MODEL OUT.jsonl [REPEATS] [variants]'
out = ARGV[1] or abort 'usage: pick.rb MODEL OUT.jsonl [REPEATS] [variants]'
repeats = (ARGV[2] || 3).to_i
variants = (ARGV[3] || 'none,cosine,labels,union10').split(',')
PARALLEL = 4
# Every request is capped, so a thinking loop can't hold a server slot for good (a disconnected
# client does not cancel a non-streamed llama-server request). THINK=off turns the chat
# template's thinking off — the cheap stand-in for a weaker model.
PARAMS = { max_tokens: (ENV['MAX_TOKENS'] || 8000).to_i }
PARAMS[:chat_template_kwargs] = { enable_thinking: false } if ENV['THINK'] == 'off'

PICK_PROMPT = <<~PROMPT.freeze
  You answer questions about Finnish employment law. The user gives you a question and the result of
  one search over the current text of four acts: työsopimuslaki (2001-55-tsl.md), vuosilomalaki
  (2005-162-vuosilomalaki.md), työaikalaki (2019-872-tal.md) and yhteistoimintalaki (2021-1333-ytl.md).
  Pick the one hit whose passage most likely holds the answer. Reply with only its number, e.g. 3,
  or 0 if no hit does.
PROMPT

# @return [Array<Integer>] 1-based numbers of the hits overlapping a gold section.
def gold_hits(content, gold)
  content.scan(/^\[(\d+)\] (\S+) lines (\d+)-(\d+)/).filter_map do |n, file, first, last|
    n.to_i if gold.any? { |g| g['file'] == file && first.to_i <= g['last'] && last.to_i >= g['first'] }
  end
end

def ask(model, question, content)
  answers = []
  listener = Class.new(Pikuri::Agent::Listener::Base) do
    define_method(:on_event) do |event|
      answers << event.content if event.is_a?(Pikuri::Agent::Event::Assistant)
    end
  end.new
  agent = Pikuri::Agent.new(
    transport: Pikuri::Agent::ChatTransport.from_openai_server(server: SERVER, model: model, api_key: API_KEY,
                                                               params: PARAMS),
    system_prompt: PICK_PROMPT, streaming: false
  ) { |c| c.add_listener listener }
  agent.run_loop(user_message: "Question: #{question}\n\nSearch result:\n\n#{content}")
  answers.last.to_s
ensure
  agent&.close
end

done = File.exist?(out) ? File.readlines(out).map { |l| JSON.parse(l).values_at('q', 'variant', 'repeat') } : []
jobs = Queue.new
QUESTIONS.each do |entry|
  # HARD=1: only the questions whose fused top 5 holds the gold below #1 — the only ones where
  # the fused variants (same list, same order) can differ.
  if ENV['HARD']
    fused = variant_execute('none', embedder: EMBEDDER, backend: RAG_CORPUS.backend, reranker: nil, query: entry['q'])
    hits = gold_hits(fused.content, gold_of(entry))
    next if hits.empty? || hits.min == 1
  end
  variants.each do |variant|
    content = variant_execute(variant, embedder: EMBEDDER, backend: RAG_CORPUS.backend, reranker: nil,
                                       query: entry['q']).content
    repeats.times do |rep|
      jobs << [entry, variant, content, rep] unless done.include?([entry['q'], variant, rep])
    end
  end
end
total = jobs.size
warn "#{total} picks to ask #{model}"
lock = Mutex.new
count = 0
PARALLEL.times.map do
  Thread.new do
    loop do
      entry, variant, content, rep = jobs.pop(true)
      gold = gold_of(entry)
      hits = gold_hits(content, gold)
      started = Time.now
      reply = begin
        ask(model, entry['q'], content)
      rescue StandardError => e
        "ERROR #{e.class}: #{e.message[0, 200]}"
      end
      pick = reply[/\A\D*(\d+)/, 1]&.to_i
      row = { 'q' => entry['q'], 'kind' => entry.fetch('kind', 'paraphrase'), 'variant' => variant,
              'repeat' => rep, 'n_hits' => content.scan(/^\[\d+\]/).size, 'gold_hits' => hits,
              'pick' => pick, 'correct' => hits.include?(pick), 'reply' => reply[0, 300],
              'seconds' => (Time.now - started).round(1) }
      lock.synchronize do
        File.open(out, 'a') { |f| f.puts(JSON.generate(row)) }
        count += 1
        warn format('%3d/%d %-8s pick=%-3s gold=%-10s %5.1fs', count, total, variant, pick.inspect,
                    hits.inspect, row['seconds'])
      end
    rescue ThreadError
      break
    end
  end
end.each(&:join)
