# frozen_string_literal: true

require 'json'
require 'net/http'
require 'open3'

# Executable form of AGENTS.md's seam tripwires — see tasks/tripwires.rake.
Dir.glob(File.expand_path('tasks/*.rake', __dir__)).sort.each { |f| load f }

# Rakefile for the pikuri-workshop monorepo. The release task bumps
# every workshop gem's VERSION constant in lockstep, builds each gem, and
# pushes each to rubygems.org — same shape Rails (rails/rails) uses
# for its multi-gem monorepo.
#
# Directory names of every gem in the monorepo. Each name doubles as
# the gem name — every gemspec inside <name>/ has +spec.name =
# '<name>'+.
#
# The order is a topological sort of the intra-monorepo dependency
# graph, kept because it documents that graph. It is **not** a release
# constraint: rubygems.org does not validate that a gem's dependencies
# already exist (its +Pusher+ never inspects them; a dependency naming
# an unknown gem is stored with an +unresolved_name+ and healed by
# +Rubygem+'s +after_create :update_unresolved+ when the name appears).
# So the push phase is free to fan out in any order — see +:release+.
GEMS = %w[
  pikuri-extractors
  pikuri-skills
  pikuri-tasks
  pikuri-memory
  pikuri-mcp
  pikuri-lsp
  pikuri-code
  pikuri-os
  pikuri-conversations
].freeze

# Path to the single source of truth for the shared version constant.
# Every release bumps this one file; the per-gem gemspec files all
# read +Pikuri::Workshop::VERSION+ via +require_relative+, so they pick
# up the new value automatically.
VERSION_FILE_REL = 'version.rb'
VERSION_FILE = File.expand_path(VERSION_FILE_REL, __dir__).freeze

RUBYGEMS_HOST = 'https://rubygems.org'

# The rubygems.org handle that must own every already-published gem in
# GEMS. The pre-flight refuses the release if a name we are about to
# push to is owned by somebody else — the squatting check.
EXPECTED_OWNER = 'mavi'

# How many +gem push+ children run at once.
#
# Two-wide is load bearing, which the estimate this comment used to
# carry had backwards. Measured at the v0.1.0 release, sixteen gems:
# each upload took 1.03–2.50s (mean 1.83s), so the phase ran 14.8s
# two-wide and left 10.9s of the window. Fully serial it would have
# been 29.3s — the sum of those same times — against a budget of
# 25.6s (the 30s window less 4.4s spent pasting the code), i.e. an
# overrun. The estimate that said otherwise assumed uploads "well
# under a second"; they are roughly 2–5x that.
#
# So the concurrency is fitting a budget, not just absorbing a
# straggler, and widening it is the first lever if a future release
# gets close. See +pikuri:D_release_one_otp+ for the point past which no
# single-code scheme survives at all.
PUSH_CONCURRENCY = 2

# TOTP period in seconds, per RFC 6238 and what rubygems.org uses.
OTP_PERIOD = 30

# Run rspec inside each gem dir. `bundle exec rake test` from the
# repo root fans out so the whole monorepo's tests run in one shot.
desc 'Run specs across every workshop gem'
task :test do
  failed = []
  GEMS.each do |dir|
    next unless Dir.exist?(File.join(dir, 'spec'))

    puts "\n==> #{dir}"
    ok = system("cd #{dir} && bundle exec rspec")
    failed << dir unless ok
  end
  raise "Specs failed in: #{failed.join(', ')}" unless failed.empty?
end

# The cross-repo standard entry point: `bundle exec rake check` (or bare
# `bundle exec rake`) runs the full verification. Prerequisite order keeps
# the CI invariant — tripwires run *after* the specs, so a drifted doc
# invariant never masks a real test failure.
desc 'Full check: specs across every gem, then the AGENTS.md seam and doc-layer tripwires'
task check: %i[test tripwires design_tripwires]

task default: :check

# --- release helpers -------------------------------------------------

def git(*args)
  out, status = Open3.capture2e('git', *args)
  raise "git #{args.join(' ')} failed:\n#{out}" unless status.success?

  out.strip
end

def git?(*args)
  _out, status = Open3.capture2e('git', *args)
  status.success?
end

# Paths reported dirty by +git status --porcelain+. Parsed here rather
# than through +git+ above, whose +strip+ would eat the leading status
# column (" M Rakefile" -> "M Rakefile") and shift every path by one.
def git_status_paths(*pathspec)
  out, status = Open3.capture2e('git', 'status', '--porcelain', *pathspec)
  raise "git status failed:\n#{out}" unless status.success?

  out.lines.filter_map { |line| line.chomp[3..] }.reject(&:empty?)
end

# GET a rubygems.org API path. Returns [Integer status, String body].
def rubygems_get(path)
  res = Net::HTTP.get_response(URI("#{RUBYGEMS_HOST}#{path}"))
  [res.code.to_i, res.body]
end

# Classify one gem against rubygems.org. Returns [:push | :skip |
# :refuse, String reason].
#
# Two *distinct* questions, deliberately not collapsed into one. Is
# this exact version already published (benign — a resumed run, and
# what makes retrying safe)? And is the name owned by somebody else
# (not benign — the squatting signal, which +gem push+ would otherwise
# surface as a 403 partway through the fan-out)?
def classify_gem(name, version)
  status, body = rubygems_get("/api/v1/gems/#{name}/owners.json")
  case status
  when 404
    return [:push, 'new gem — name unclaimed']
  when 200
    handles = JSON.parse(body).map { |o| o['handle'] }
    unless handles.include?(EXPECTED_OWNER)
      return [:refuse, "owned by #{handles.join(', ')} — not #{EXPECTED_OWNER}"]
    end
  else
    raise "rubygems.org returned #{status} for #{name} owners: #{body}"
  end

  status, body = rubygems_get("/api/v2/rubygems/#{name}/versions/#{version}.json")
  case status
  when 200 then [:skip, "#{version} already published"]
  when 404 then [:push, 'ready']
  else raise "rubygems.org returned #{status} for #{name} #{version}: #{body}"
  end
end

# Run +work+ over +items+ with at most +width+ threads, returning a
# Hash item => result.
def in_parallel(items, width)
  queue = items.dup
  results = {}
  lock = Mutex.new
  Array.new([width, items.size].min) do
    Thread.new do
      loop do
        item = lock.synchronize { queue.shift }
        break if item.nil?

        value = yield item
        lock.synchronize { results[item] = value }
      end
    end
  end.each(&:join)
  results
end

def report(rows)
  width = GEMS.map(&:length).max
  rows.each { |name, text| puts "    #{name.ljust(width)}  #{text}" }
end

# Sleep until the top of the next TOTP window, so the code the human
# is about to read has its full ~30s ahead of it.
#
# The wait is unconditional on purpose. A release is rare enough that
# a mean 15s costs nothing, and the wait is not idle — it is exactly
# when the human fetches their authenticator. Sleeping only when the
# current window is short would need a threshold covering paste
# latency as well as push time, and could strand the human mid-paste
# with "that code is too stale, try again".
#
# The boundary is computed from *this machine's* clock while the code
# is read off the *authenticator's*. A disagreement of d seconds hands
# the pushes a window of (30 - d) — the one assumption here that fails
# silently, since nothing reports a skewed clock. It is tolerated
# rather than fixed: the v0.1.0 release left 10.9s of its window
# unspent, so that much skew is absorbed outright, and rubygems.org's
# TOTP drift tolerance roughly doubles that. Any machine running NTP
# is nowhere near it. Note this is the measured ~10s, not the "well
# over 20s" an earlier estimate here claimed — the headroom is real
# but thinner than advertised.
def wait_for_fresh_otp_window
  wait = OTP_PERIOD - (Time.now.to_i % OTP_PERIOD)
  puts "\n==> Waiting #{wait}s for a fresh OTP window — have your authenticator ready."
  sleep wait
  monotonic
end

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# Ask for the OTP code on stdin.
#
# stdin is the *only* supply path; there is deliberately no way to
# hand the code in through the environment. A code supplied upfront
# starts dying immediately, which would force the task to build while
# the clock runs — spending window on work that has no need to be
# inside it — or to refuse and make you re-run. Asking after the slow
# phases inverts that: the build is already done, so every second of
# the window goes to uploads.
#
# Not to be confused with the plumbing: each +gem push+ child *is*
# handed the code through GEM_HOST_OTP_CODE below. That is how the
# code reaches the child, not an interface for supplying it.
def ask_otp
  3.times do
    print 'OTP code: '
    $stdout.flush
    code = $stdin.gets
    raise 'stdin closed while asking for the OTP code' if code.nil?

    code = code.strip
    return code if code.match?(/\A\d{6}\z/)

    puts "  Expected six digits, got #{code.inspect}."
  end
  raise 'No valid OTP code after three attempts'
end

# --- release ---------------------------------------------------------

# Lockstep release: pre-flight → bump → build → push → tag.
#
# Usage: VERSION=1.2.3 bundle exec rake release
#
# The ordering is the design. Everything slow and everything fallible
# happens *before* the OTP is asked for, so one code covers all
# the pushes: gemspec errors surface before the first gem is
# public, and the pre-flight refuses a squatted name up front. Then a
# single narrated sleep lands on a fresh TOTP window, one prompt takes
# the code, and the uploads — the only fast part — spend it.
#
# Every step is idempotent, which is what lets the push phase carry no
# OTP state at all: there is no mid-flight re-prompt and no
# carry-forward retry, because **the recovery for anything is
# re-running the task**. An already-published version is skipped and
# reported, an applied bump / existing commit / existing tag are
# passed over.
# Set DRY_RUN=1 to rehearse. The pre-flight, the version bump, the
# builds, the window wait and the OTP prompt all run for real — so the
# gems built are the ones a release would build — while the three
# things that leave a mark (the bump commit, the pushes, the tag) are
# reported instead of done, and the bump is reverted on the way out. A
# release is irreversible: a pushed gem can be yanked, but its version
# number is spent forever. Rehearse any change to this task first.
desc 'Lockstep release: pre-flight → bump → build → push → tag (set VERSION=x.y.z, DRY_RUN=1 to rehearse)'
task :release do
  version = ENV.fetch('VERSION') { raise 'Set VERSION=x.y.z to release' }
  tag = "v#{version}"
  dry = !ENV['DRY_RUN'].to_s.empty?
  puts '==> DRY RUN — nothing will be committed, pushed or tagged' if dry

  # The tree must be clean, except for a version bump this task itself
  # already applied on an earlier, failed run.
  # A bump this task already applied on an earlier failed run is
  # tolerated — both the constant and the lock bundler rewrites from it.
  dirty = git_status_paths
  unless (dirty - [VERSION_FILE_REL, 'Gemfile.lock']).empty?
    raise "Working tree must be clean before release. Uncommitted: #{dirty.join(', ')}"
  end

  puts '==> Pre-flight against rubygems.org'
  verdicts = in_parallel(GEMS, 4) { |name| classify_gem(name, version) }
  report(GEMS.map { |name| [name, "#{verdicts[name][0]} — #{verdicts[name][1]}"] })

  refused = GEMS.select { |name| verdicts[name][0] == :refuse }
  unless refused.empty?
    raise "Refusing to release: #{refused.join(', ')} owned by someone else. " \
          'Investigate before pushing anything.'
  end

  to_push = GEMS.select { |name| verdicts[name][0] == :push }
  skipped = GEMS - to_push
  if to_push.empty?
    puts "\nEverything is already published at #{version}. Nothing to push."
  end

  # The bump is written before the build (the gemspecs read it) but
  # committed after, so a gemspec error leaves no commit behind at
  # all. The commit carries Gemfile.lock as well: the lock pins every
  # path gem's version, so bundler rewrites it the moment the constant
  # changes. Committing only version.rb would leave the lock dirty
  # after every release and the tag pointing at a tree whose lock
  # disagrees with its own gemspecs.
  puts "\n==> Bumping VERSION constant to #{version}"
  text = File.read(VERSION_FILE)
  current = text[/VERSION\s*=\s*['"]([^'"]+)['"]/, 1]
  raise "VERSION constant not found in #{VERSION_FILE}" if current.nil?

  if current == version
    puts "    already at #{version}"
  else
    File.write(VERSION_FILE, text.sub(/VERSION\s*=\s*['"][^'"]+['"]/, "VERSION = '#{version}'"))
    puts "    #{current} → #{version}"
  end

  puts "\n==> Building #{GEMS.size} gems"
  build_rows = GEMS.map do |dir|
    Dir.glob(File.join(dir, '*.gem')).each { |f| File.delete(f) }
    spec = Dir.glob(File.join(dir, '*.gemspec')).first
    raise "no gemspec in #{dir}" unless spec

    out, status = Open3.capture2e('gem', 'build', File.basename(spec), chdir: dir)
    raise "gem build failed in #{dir}:\n#{out}" unless status.success?

    built = Dir.glob(File.join(dir, '*.gem')).first
    raise "no .gem built in #{dir}" unless built

    [dir, File.basename(built)]
  end
  report(build_rows)

  puts "\n==> Committing the bump"
  bump_paths = ['--', VERSION_FILE_REL, 'Gemfile.lock']
  if dry
    changed = git_status_paths(*bump_paths)
    puts changed.empty? ? '    nothing to commit' : "    would commit #{tag}: #{changed.join(', ')}"
  elsif git_status_paths(*bump_paths).empty?
    puts "    already committed (HEAD: #{git('log', '-1', '--pretty=%s')})"
  else
    git('add', VERSION_FILE_REL, 'Gemfile.lock')
    git('commit', '-m', tag)
    puts "    committed #{tag}"
  end

  unless to_push.empty?
    window_start = wait_for_fresh_otp_window
    otp = ask_otp
    paste_took = monotonic - window_start

    puts "\n==> #{dry ? 'Would push' : 'Pushing'} #{to_push.size} gems, #{PUSH_CONCURRENCY} at a time"
    # Each child is handed the code through the environment (never
    # argv, so it stays out of the process table) with its stdin
    # closed. `gem push` self-heals a rejected code by prompting and
    # retrying; with nobody watching, that would hang the release
    # silently, so it must hit EOF and fail fast instead.
    push_start = monotonic
    outcomes = in_parallel(to_push, PUSH_CONCURRENCY) do |dir|
      gem_file = File.basename(Dir.glob(File.join(dir, '*.gem')).first)
      next [true, "would push #{gem_file}", 0.0] if dry

      started = monotonic
      out, status = Open3.capture2e(
        { 'GEM_HOST_OTP_CODE' => otp },
        'gem', 'push', gem_file,
        chdir: dir, stdin_data: ''
      )
      [status.success?, out.strip, monotonic - started]
    end
    push_took = monotonic - push_start
    window_left = OTP_PERIOD - (monotonic - window_start)
  else
    outcomes = {}
  end

  puts "\n==> Results"
  rows = GEMS.map do |name|
    if skipped.include?(name)
      [name, "skipped — #{verdicts[name][1]}"]
    elsif outcomes[name]&.first
      [name, format('%s (%.2fs)', dry ? 'would push' : 'pushed', outcomes[name][2])]
    else
      [name, "FAILED — #{outcomes[name] && outcomes[name][1].to_s.lines.last&.strip}"]
    end
  end
  report(rows)

  # The measurement the whole single-code design rests on: did the
  # uploads fit inside one OTP window, and by how much? Printed every
  # release so the margin is observed rather than assumed — and so a
  # failure caused by overrunning the window says so in as many words
  # instead of looking like a row of unrelated rejections.
  unless to_push.empty?
    puts "\n==> OTP window#{dry ? ' (rehearsal — nothing was uploaded, so the push time is not a measurement)' : ''}"
    accounting = format('%.1fs to paste, %.1fs to push %d gems %d-wide',
                        paste_took, push_took, to_push.size, PUSH_CONCURRENCY)
    verdict = if window_left.negative?
                format('OVERRAN the %ds window by %.1fs', OTP_PERIOD, -window_left)
              else
                format('%.1fs of the %ds window left', window_left, OTP_PERIOD)
              end
    puts "    #{accounting} — #{verdict}"
  end

  failed = to_push.reject { |name| outcomes[name]&.first }
  unless failed.empty?
    raise "Push failed for: #{failed.join(', ')}. " \
          "Fix the cause and re-run `VERSION=#{version} rake release` — " \
          'the gems that landed are skipped on the next run.'
  end

  if dry
    puts "\n==> DRY RUN complete — would have tagged #{tag}. Nothing was published."
    next
  end

  if git?('rev-parse', '-q', '--verify', "refs/tags/#{tag}")
    puts "\n==> Tag #{tag} already exists"
  else
    git('tag', tag)
    puts "\n==> Tagged #{tag}"
  end

  puts "Released #{tag}. Push the commit and tag with: git push && git push --tags"
ensure
  # A rehearsal writes the bump for real, so that the gems it builds
  # are the ones a release would build. Put it back — on the way out
  # of a failure too, so a rehearsal never leaves the tree bumped.
  if dry && !git_status_paths('--', VERSION_FILE_REL, 'Gemfile.lock').empty?
    git('checkout', '--', VERSION_FILE_REL, 'Gemfile.lock')
    puts "==> DRY RUN — restored #{VERSION_FILE_REL} and Gemfile.lock"
  end
end
