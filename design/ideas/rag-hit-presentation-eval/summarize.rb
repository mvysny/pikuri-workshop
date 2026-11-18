# frozen_string_literal: true

# ruby summarize.rb full — per variant: gold cited / gold read, searches, calls, tokens, time.
require 'json'

ACT_NAMES = { 'tsl' => 'työsopimuslai', 'vll' => 'vuosilomalai', 'tal' => 'työaikalai',
              'ytl' => 'yhteistoimintalai' }.freeze

# Re-scored here, not trusted from the run: the run's matcher missed Markdown emphasis between
# the act's name and the chapter ("Työsopimuslain **6 luvun 3 §**").
def cited?(answer, ref)
  act, sec = ref.split
  chapter, section = sec.split(':')
  text = answer.delete('*_')
  section = section.sub(/([a-z])\z/, '\s*\1')
  long = /#{ACT_NAMES.fetch(act)}\w*\s+#{chapter}\s+luvun\s+(?:[\d\s,–-]*(?:ja|sekä)\s+)?#{section}\s*§/i
  short = /\b#{act}\s*#{chapter}\s*:\s*#{section}\b/i
  text.match?(long) || text.match?(short)
end

dir = ARGV[0] || 'full'
rows = Dir[File.join(dir, '*.jsonl')].sort.to_h do |f|
  rs = File.readlines(f).map { |l| JSON.parse(l) }
  rs.each { |r| r['cited'] = r['gold'].any? { |ref| cited?(r['answer'], ref) } }
  [File.basename(f, '.jsonl'), rs]
end
avg = ->(xs) { xs.empty? ? 0 : xs.sum.to_f / xs.size }
%w[paraphrase exact all].each do |kind|
  puts "#{kind.ljust(10)} #{'n'.rjust(3)} #{'cited'.rjust(6)} #{'read'.rjust(5)} #{'either'.rjust(6)} " \
       "#{'search'.rjust(6)} #{'calls'.rjust(5)} #{'in_tok'.rjust(7)} #{'sec'.rjust(5)} err"
  rows.each do |variant, rs|
    rs = rs.select { |r| r['kind'] == kind } unless kind == 'all'
    puts format('%-10s %3d %6d %5d %6d %6.1f %5.1f %7.0f %5.0f %d', variant, rs.size,
                rs.count { |r| r['cited'] }, rs.count { |r| r['read'] }, rs.count { |r| r['cited'] || r['read'] },
                avg.(rs.map { |r| r['searches'] }), avg.(rs.map { |r| r['calls'] }),
                avg.(rs.map { |r| r['tokens']['input'] }), avg.(rs.map { |r| r['seconds'] }),
                rs.count { |r| r['error'] })
  end
  puts
end
# Per question: which variants cited the gold (C), read it (r), or neither (.).
qs = rows.values.flatten.map { |r| r['q'] }.uniq
puts "per question (C cited, r read only, . neither): #{rows.keys.join(' ')}"
qs.each do |q|
  marks = rows.values.map do |rs|
    r = rs.find { |x| x['q'] == q }
    next '-' unless r

    r['cited'] ? 'C' : (r['read'] ? 'r' : '.')
  end
  next if marks.uniq.size == 1 && marks.first == 'C'

  puts "  #{marks.join(' ' * 6)}  #{q[0, 60]}"
end
