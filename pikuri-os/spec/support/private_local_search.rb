# frozen_string_literal: true

require 'fileutils'
require 'open3'

# A throwaway GNOME localsearch index over a corpus you hand it, so specs
# run the real indexer and the real {Pikuri::Os::LocalSearch} queries without
# touching the user's own index:
#
#   index = PrivateLocalSearch.new('beta/b.md' => 'A zebra, a mouse.')
#   index.start                 # ~2 s: boots a bus, indexes, waits for the text
#   Pikuri::Os::LocalSearch.search(query: 'zebra', limit: 5, folder: "#{index.corpus}/beta")
#   index.stop
#
# Between +start+ and +stop+, +ENV['DBUS_SESSION_BUS_ADDRESS']+ points at a
# private session bus, so every tinysparql the backend spawns talks to it.
#
# == Implementation details
#
# The private bus carries the whole sandbox in its environment: D-Bus
# activation starts +localsearch-3+ on the first query, and the daemon
# inherits a temp +HOME+ / XDG dirs (its database lands in the temp
# +XDG_CACHE_HOME+) and +GSETTINGS_BACKEND=keyfile+, which reads the
# index-these-folders setting from a file we write. Ubuntu doesn't ship the
# upstream +localsearch test-sandbox+ helper, which does the same.
#
# The corpus lives under {Pikuri::Paths.new_temp} (+~/.cache/pikuri/…+), not
# +/tmp+: the indexer refuses a folder on a tmpfs mount ("not an indexed
# folder"), while hidden ancestors are fine as long as the configured folder
# itself isn't hidden. The user's own indexer skips +~/.cache+, so the corpus
# never leaks into the real index.
class PrivateLocalSearch
  # @return [String] the indexing daemon D-Bus activation starts.
  MINER = '/usr/libexec/localsearch-3'

  # @return [Integer] seconds to wait for the corpus's text to be indexed.
  TIMEOUT = 30

  # @return [String] absolute path of the indexed folder (set by {#start}).
  attr_reader :corpus

  # @return [Boolean] whether this host can run a private index at all.
  def self.usable?
    File.executable?(MINER) && on_path?('dbus-daemon') && on_path?('tinysparql')
  end

  # @param name [String]
  # @return [Boolean]
  def self.on_path?(name)
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
  end

  # @param files [Hash{String => String}] corpus-relative path => content;
  #   plain text, since {#start} waits for each one's text
  # @param name_only [Array<String>] those of +files+ the index keeps by
  #   name only (source code), whose text {#start} doesn't wait for
  def initialize(files, name_only: [])
    @files = files
    @name_only = name_only
  end

  # Write the corpus, boot the private bus and wait until every file is in
  # the index, with its text unless it is +name_only+.
  #
  # @return [self]
  # @raise [RuntimeError] if the index doesn't hold every file within {TIMEOUT}
  def start
    root = Pikuri::Paths.new_temp
    @corpus = root.join('corpus').to_s
    home = root.join('home').to_s
    @files.each do |rel, content|
      path = File.join(@corpus, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    write_settings("#{home}/.config")
    start_bus(home)
    wait_for_text
    self
  end

  # Kill the private bus (the daemon exits with it) and restore the bus
  # address. The corpus goes with {Pikuri::Paths.new_temp}'s exit reaper.
  #
  # @return [void]
  def stop
    ENV['DBUS_SESSION_BUS_ADDRESS'] = @saved_address
    return unless @bus_pid

    Process.kill('TERM', -@bus_pid)
    Process.wait(@bus_pid)
  rescue Errno::ESRCH, Errno::ECHILD => e
    Pikuri.logger_for('PrivateLocalSearch').debug("bus already gone: #{e.message}")
  end

  private

  # @param config_home [String]
  # @return [void]
  def write_settings(config_home)
    path = File.join(config_home, 'glib-2.0', 'settings', 'keyfile')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~KEYFILE)
      [org/freedesktop/tracker/miner/files]
      index-recursive-directories=['#{@corpus}']
      index-single-directories=@as []
    KEYFILE
  end

  # @param home [String]
  # @return [void]
  def start_bus(home)
    runtime = File.join(home, 'run')
    FileUtils.mkdir_p(runtime, mode: 0o700)
    env = {
      'HOME' => home,
      'XDG_CACHE_HOME' => "#{home}/.cache",
      'XDG_CONFIG_HOME' => "#{home}/.config",
      'XDG_DATA_HOME' => "#{home}/.local/share",
      'XDG_RUNTIME_DIR' => runtime,
      'GSETTINGS_BACKEND' => 'keyfile',
      'GIO_USE_VFS' => 'local',            # no gvfs daemons on the private bus
      'GIO_USE_VOLUME_MONITOR' => 'unix'
    }
    reader, writer = IO.pipe
    @bus_pid = Process.spawn(env, 'dbus-daemon', '--session', '--nofork', '--print-address=1',
                             out: writer, err: File::NULL, pgroup: true)
    writer.close
    address = reader.gets&.strip
    reader.close
    raise "dbus-daemon printed no address (pid #{@bus_pid})" if address.nil? || address.empty?

    @saved_address = ENV.fetch('DBUS_SESSION_BUS_ADDRESS', nil)
    ENV['DBUS_SESSION_BUS_ADDRESS'] = address
  end

  # @return [void]
  def wait_for_text
    deadline = Time.now + TIMEOUT
    want = [@files.size, @files.size - @name_only.size]
    urls = @files.keys.map { |rel| "\"#{Pikuri::Os::LocalSearch.file_uri(File.join(@corpus, rel))}\"" }.join(' ')
    loop do
      have = [count("VALUES ?u { #{urls} } ?f nie:url ?u"), count('?e nie:plainTextContent ?t')]
      return if have.zip(want).all? { |h, w| h >= w }
      if Time.now > deadline
        raise "private index holds #{have[0]}/#{want[0]} files, text of #{have[1]}/#{want[1]}, after #{TIMEOUT}s"
      end

      sleep 0.2
    end
  end

  # @param pattern [String] a SPARQL graph pattern
  # @return [Integer] how many solutions it has
  def count(pattern)
    out, = Open3.capture2e('tinysparql', 'query', '-b', Pikuri::Os::LocalSearch::DBUS_SERVICE, '-q',
                           "SELECT (CONCAT(\"v:\", STR(COUNT(*))) AS ?n) WHERE { #{pattern} }")
    Pikuri::Os::LocalSearch.parse_rows(out).first&.first.to_i
  end
end
