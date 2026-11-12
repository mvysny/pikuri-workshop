# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

describe Pikuri::Lsp::Servers do
  entry = ->(id, files) { Pikuri::Lsp::Registry::StdioEntry.new(id: id, command: [id], files: files) }
  registry = Pikuri::Lsp::Registry.new(entries: [entry.call('ruby', %w[*.rb Rakefile]),
                                                 entry.call('java', %w[*.java])])

  # A stand-in for a started client: {Servers} only ever reads its +entry+ and
  # calls +close+, which is what makes the spawn seam worth having.
  stub_client = Struct.new(:entry, :closed) do
    def close
      self.closed = true
    end
  end

  # Yields a Servers over a real tree, because relevance is answered by walking
  # one. +files+ are created relative to the root; a trailing +/+ makes a dir.
  built = lambda do |files, the_registry = registry, &block|
    Dir.mktmpdir('pikuri-lsp-servers-') do |root|
      files.each do |path|
        full = File.join(root, path)
        if path.end_with?('/')
          FileUtils.mkdir_p(full)
        else
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, '')
        end
      end
      spawned = []
      servers = described_class.new(
        registry: the_registry, root: root,
        spawn: lambda { |spawn_entry|
          spawned << spawn_entry.id
          stub_client.new(spawn_entry, false)
        }
      )
      block.call(servers, spawned, root)
    end
  end

  it 'starts nothing at all until a call needs a server' do
    built.call(%w[lib/agent.rb src/App.java]) do |servers, spawned|
      assert_empty spawned
      assert_empty servers.started_ids
    end
  end

  it 'starts only the server that claims the file, and memoizes it' do
    built.call(%w[lib/agent.rb src/App.java]) do |servers, spawned|
      assert_equal 'ruby', servers.client_for('lib/agent.rb').entry.id
      servers.client_for('other.rb')

      assert_equal %w[ruby], spawned
      assert_equal %w[ruby], servers.started_ids
    end
  end

  it 'routes on the basename, extension or not' do
    built.call(%w[lib/agent.rb src/App.java]) do |servers|
      assert_equal 'ruby', servers.client_for('lib/pikuri/agent.rb').entry.id
      assert_equal 'ruby', servers.client_for('/abs/path/Rakefile').entry.id
      assert_equal 'java', servers.client_for('src/main/java/App.java').entry.id
      assert_nil servers.client_for('README.md')
    end
  end

  it 'fans out to a claiming server without the file having to exist' do
    built.call(%w[lib/agent.rb]) do |servers, spawned|
      assert_equal 'java', servers.client_for('src/App.java').entry.id
      assert_equal %w[java], spawned
    end
  end

  describe 'relevance' do
    it 'activates only the entries the project has files for' do
      built.call(%w[lib/agent.rb Rakefile]) do |servers, spawned|
        assert_equal %w[ruby], servers.active_entries.map(&:id)
        assert_equal %w[ruby], servers.active.map { |client| client.entry.id }
        assert_equal %w[ruby], spawned
      end
    end

    it 'activates both in a mixed project, in declaration order' do
      built.call(%w[src/App.java lib/agent.rb]) do |servers|
        assert_equal %w[ruby java], servers.active.map { |client| client.entry.id }
      end
    end

    it 'activates nothing when no configured server claims anything here' do
      built.call(%w[README.md docs/guide.txt]) do |servers, spawned|
        assert_empty servers.active
        assert_empty spawned
      end
    end

    it 'rescans while incomplete, so a file the agent just wrote joins the fan-out' do
      built.call(%w[lib/agent.rb]) do |servers, _spawned, root|
        assert_equal %w[ruby], servers.active_entries.map(&:id)
        File.write(File.join(root, 'App.java'), '')

        assert_equal %w[ruby java], servers.active_entries.map(&:id)
      end
    end

    it 'stops rescanning once every registered entry is relevant' do
      built.call(%w[lib/agent.rb App.java]) do |servers, _spawned, root|
        assert_equal %w[ruby java], servers.active_entries.map(&:id)
        File.delete(File.join(root, 'App.java'))

        # A rescan would drop java; the memo is what keeps the answer stable —
        # and what stops the walk from running on every fan-out forever.
        assert_equal %w[ruby java], servers.active_entries.map(&:id)
      end
    end

    it 'keeps a server the walk cannot see but a call already started' do
      # The walk skips dot-directories, so nothing in the project *it* sees
      # claims java. Having answered for the file is the better evidence.
      built.call(%w[lib/agent.rb .hidden/App.java]) do |servers|
        assert_equal %w[ruby], servers.active_entries.map(&:id)
        servers.client_for('.hidden/App.java')

        assert_equal %w[ruby java], servers.active_entries.map(&:id)
        assert_equal %w[ruby java], servers.active.map { |client| client.entry.id }
      end
    end

    it 'does not descend into dot-directories' do
      built.call(%w[.git/hooks/pre-commit.rb README.md]) do |servers|
        assert_empty servers.active
      end
    end

    it 'does not follow a symlinked directory' do
      Dir.mktmpdir('pikuri-lsp-elsewhere-') do |elsewhere|
        File.write(File.join(elsewhere, 'App.java'), '')
        built.call(%w[README.md]) do |servers, _spawned, root|
          File.symlink(elsewhere, File.join(root, 'linked'))

          assert_empty servers.active
        end
      end
    end

    it 'ignores an unreadable directory rather than failing the call it serves' do
      built.call(%w[locked/App.java lib/agent.rb]) do |servers, _spawned, root|
        locked = File.join(root, 'locked')
        File.chmod(0o000, locked)
        begin
          assert_equal %w[ruby], servers.active_entries.map(&:id)
        ensure
          File.chmod(0o700, locked)
        end
      end
    end
  end

  it 'retries a failed spawn rather than remembering it, so installing the binary recovers' do
    attempts = 0
    servers = described_class.new(
      registry: registry, root: '/unused',
      spawn: lambda { |spawn_entry|
        attempts += 1
        raise Pikuri::Lsp::ClientWrapper::ServerDied, 'no ruby-lsp here' if attempts == 1

        stub_client.new(spawn_entry, false)
      }
    )

    assert_raises(Pikuri::Lsp::ClientWrapper::ServerDied) { servers.client_for('a.rb') }

    assert_equal 'ruby', servers.client_for('a.rb').entry.id
    assert_equal 2, attempts
  end

  it 'keeps the servers it did start when a later one fails, so the owner can sweep them' do
    started = []
    Dir.mktmpdir('pikuri-lsp-servers-') do |root|
      File.write(File.join(root, 'a.rb'), '')
      File.write(File.join(root, 'App.java'), '')
      servers = described_class.new(
        registry: registry, root: root,
        spawn: lambda { |spawn_entry|
          raise Pikuri::Lsp::ClientWrapper::ServerDied, 'no jdtls here' if spawn_entry.id == 'java'

          started << stub_client.new(spawn_entry, false)
          started.last
        }
      )

      assert_raises(Pikuri::Lsp::ClientWrapper::ServerDied) { servers.active }
      servers.close

      assert_equal [true], started.map(&:closed)
    end
  end

  it 'reports emptiness from the registry, not from what is running' do
    built.call(%w[lib/agent.rb]) do |servers|
      refute servers.empty?, 'a configured server is something to ask, started or not'
      servers.client_for('lib/agent.rb')
      servers.close

      refute servers.empty?
      assert_empty servers.started_ids
    end
  end

  it 'answers nothing for an empty registry, so a host that configures none wires no tool' do
    built.call(%w[lib/agent.rb], Pikuri::Lsp::Registry::EMPTY) do |servers, spawned|
      assert servers.empty?
      assert_empty servers.active
      assert_empty spawned
      assert_nil servers.client_for('a.rb')
    end
  end
end
