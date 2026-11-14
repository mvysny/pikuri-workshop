# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'pathname'
require 'securerandom'
require 'time'

module Pikuri
  class Conversations
    # The on-disk home of saved conversations: one directory per conversation
    # under a single root. Minting an id and committing are separate steps — a
    # folder per click would litter the root — but a commit is *one* call, and
    # it writes both halves:
    #
    #   store = Store.new(root: dir, shell: 'pikuri-webui-chat')
    #   entry = store.create                                  # mints an id; no folder yet
    #   store.save(entry, agent.export_history, model: m, server: s)   # the whole commit
    #   store.list                                            # everything committed, newest first
    #   history = store.history(store.find(id))               # for Agent.new(history:)
    #
    # The layout, each format with exactly one writer:
    #
    #   2026-08-27T12-03-51Z-3f9a/
    #       history.json   {HistoryFile}'s
    #       attachments/   {HistoryFile}'s — content-addressed, only if there are any;
    #                      {#stash} writes a message's images here ahead of its turn
    #       meta.json      the envelope — title, timestamps, shell, connection, extras
    #
    # {#save} writes +history.json+ itself rather than leaving each caller to,
    # which is what makes this class the single writer of a conversation's
    # directory — the mode, the order and the commit point are decided once.
    # The folder format is what pikuri-webui and Puri wrote before this gem;
    # their conversations list here unchanged.
    #
    # == The connection a conversation is on
    #
    # +meta.json+ records the +[model, server]+ *pair*: a model id alone
    # cannot tell two servers running one model apart. +server+ is the
    # transport's normalized +api_base+. An envelope missing either half reads
    # as a conversation with no saved connection — a key can be added without
    # a {SCHEMA} bump, because a reader checks the version and ignores what it
    # does not read. {#save} takes the pair per call because what gets written
    # is the agent's *own* transport at turn end; a store-wide field could only
    # ever record the connection the process booted on.
    #
    # == Implementation details
    #
    # Directories are created 0700: a conversation holds everything the user
    # typed plus whatever the tools fetched, unencrypted. That covers
    # +attachments/+, which {HistoryFile.save} creates with the default mode —
    # an unreadable parent is what actually blocks traversal. Hence {#save}'s
    # first step: tightening the directory *after* writing into it leaves the
    # contents world-readable for as long as the write takes.
    #
    # == Thread-safety
    #
    # Thread-safe in the narrow sense that is all this object can promise: it
    # holds no mutable state past its constructor arguments. The consistency
    # of the *folder* rests elsewhere —
    #
    # - one conversation's directory has one writer at a time, which the host
    #   guarantees (one agent per conversation, saving between its turns), not
    #   anything in this class;
    # - both files are written temp-file-and-rename, which is the whole of what
    #   a reader in another process gets — there is no cross-process lock;
    # - {#list} needs no coordination with a concurrent save or delete, because
    #   +row+ takes a read's own +ENOENT+ as the answer.
    #
    # Cross-call sequences are *not* atomic: {#find} then {#delete} has a gap,
    # and a caller must tolerate the conversation having vanished inside it.
    class Store
      # Basename of the envelope. The +history.json+ beside it is
      # {HistoryFile}'s.
      #
      # @return [String]
      META_FILE = 'meta.json'

      # +meta.json+'s format version. Bumped only for a change an old reader
      # could not survive; {#list} refuses that one conversation rather than
      # crash the whole listing.
      #
      # @return [Integer]
      SCHEMA = 1

      # The envelope keys {#save} owns; an +extra:+ key may not reuse one.
      #
      # @return [Array<String>]
      RESERVED_KEYS = %w[schema id title created_at updated_at shell model server].freeze

      # The start stamp an id opens with, +strftime+ing and matching halves of
      # the same format.
      #
      # @return [String]
      ID_TIME = '%Y-%m-%dT%H-%M-%SZ'
      # @return [Regexp]
      ID = /\A(\d{4})-(\d\d)-(\d\d)T(\d\d)-(\d\d)-(\d\d)Z-[0-9a-f]+\z/

      # One conversation's identity and where it lives; no history of its own —
      # that is +history.json+ under +dir+, read by {Store#history}. A snapshot:
      # the next {Store#save} moves +meta.json+ on and an +Entry+ never follows.
      #
      # @!attribute [r] id
      #   @return [String] the directory basename, e.g. +"2026-08-27T12-03-51Z-3f9a"+
      # @!attribute [r] dir
      #   @return [Pathname] the conversation's directory; may not exist yet
      # @!attribute [r] title
      #   @return [String] display title — the local-time start stamp until
      #     something names it
      # @!attribute [r] created_at
      #   @return [Time]
      # @!attribute [r] supported
      #   @return [Boolean] false for a conversation {Store#list} could not read
      #     — +title+ is then the stamp derived from the id, and nothing else on
      #     disk should be trusted
      # @!attribute [r] model
      #   @return [String, nil] the model +meta.json+ held when this value was
      #     built, or what {Store#create} was given; nil for no saved connection
      # @!attribute [r] server
      #   @return [String, nil] the +server+ half of the same pair
      # @!attribute [r] extra
      #   @return [Hash{String => Object}] the envelope's keys outside
      #     {RESERVED_KEYS}, as a host stored them through {Store#save}'s
      #     +extra:+ (Puri's +last_question+, say); empty when unsupported
      Entry = Data.define(:id, :dir, :title, :created_at, :supported, :model, :server, :extra) do
        # Defaulted because "no saved connection" is a real and ordinary state —
        # every conversation is in it until its first turn lands.
        #
        # @param model [String, nil] see {#model}
        # @param server [String, nil] see {#server}
        # @param extra [Hash{String => Object}] see {#extra}
        def initialize(model: nil, server: nil, extra: {}, **) = super
      end

      # Creates +root+ if it is not there — so the folder exists from boot,
      # rather than appearing on whichever later event happens to save first.
      #
      # @param root [String, Pathname] directory holding one subdirectory per
      #   conversation, e.g. +~/.local/state/puri/conversations+
      # @param shell [String] which program is writing these, recorded in
      #   +meta.json+ so a later picker can say "saved by a different harness"
      def initialize(root:, shell:)
        @root = Pathname(root)
        @shell = shell
        mkdir_private(@root)
      end

      # @return [Pathname] the conversations root
      attr_reader :root

      # Mint a new conversation. No directory yet — a folder per click would
      # litter the root with conversations nothing was ever said in, so one
      # appears when there is something to put in it.
      #
      #   store.create.id     # => "2026-08-27T12-03-51Z-3f9a"
      #   store.create.title  # => "2026-08-27 14:03"
      #
      # The id sorts lexically and greps by date, so +ls+ is already a
      # newest-last listing; the random suffix keeps two processes minting in
      # the same second apart. UTC in the id, local time in the title.
      #
      # @param at [Time] the conversation's start time
      # @param model [String, nil] connection to start on, e.g. inherited from
      #   the conversation the user was reading
      # @param server [String, nil] the +server+ half of the same pair
      # @return [Entry]
      def create(at: Time.now, model: nil, server: nil)
        # #getutc / #getlocal, not #utc / #localtime: the destructive pair would
        # convert the caller's own Time object as a side effect.
        id = "#{at.getutc.strftime(ID_TIME)}-#{SecureRandom.hex(2)}"
        Entry.new(id: id, dir: @root / id, title: stamp_title(at), created_at: at, supported: true,
                  model: model, server: server)
      end

      # Every conversation committed to disk, newest first.
      #
      #   store.list.map { [_1.title, _1.supported] }
      #   # => [["2026-08-27 14:03", true], ["2026-08-26 09:14", false]]
      #
      # Newest-first is a lexical sort on the id, which *is* the start stamp:
      # a conversation holds its place however long it goes on being written
      # to, and ordering never opens a file.
      #
      # A directory without +meta.json+ is not listed — that file is {#save}'s
      # commit point, so such a directory is a save interrupted between the
      # history and the envelope. One whose +meta.json+ is unreadable, or
      # stamped by a schema this version doesn't know, comes back
      # +supported: false+ rather than being dropped: a conversation the user
      # can see and not open beats one that silently isn't there, and a listed
      # one can be deleted.
      #
      # No index file fronts the per-conversation +meta.json+ reads: an index
      # is a cache of the directory, and it drifts from it. They are fine into
      # the hundreds — measure a slow sidebar before trading that away.
      #
      # @return [Array<Entry>]
      def list
        @root.children.filter_map { |dir| row(dir) }.sort_by(&:id).reverse
      end

      # One listed conversation by id, or nil.
      #
      #   store.find(params['id'])   # => Entry, or nil for anything else
      #
      # Resolution goes *through the listing* rather than by building a path,
      # so an id arriving from a URL can only ever name a conversation that is
      # already there — no caller has to think about traversal.
      #
      # @param id [String]
      # @return [Entry, nil]
      def find(id)
        list.find { |entry| entry.id == id }
      end

      # The stored conversation, ready for +Agent.new(history:)+; nil for one
      # never saved.
      #
      #   convs.open(id: entry.id, transport:, listener:, history: store.history(entry))
      #
      # "Never saved" is no +meta.json+, {#save}'s commit point and {#list}'s
      # test: a minted entry answers nil, and so does a save interrupted
      # before its envelope. A committed folder without its +history.json+ is
      # damage, and raises.
      #
      # @param entry [Entry] from {#create}, {#list} or {#find}
      # @return [Pikuri::Agent::History, nil]
      # @raise [HistoryFile::Error] for a committed conversation whose
      #   +history.json+ is missing or broken, or an attachment that fails
      #   confinement or its digest
      def history(entry)
        return nil unless (entry.dir / META_FILE).file?

        HistoryFile.load(entry.dir)
      end

      # Commit a conversation to disk — the directory, the history, the envelope.
      #
      #   store.save(entry, agent.export_history,
      #              model: transport.model, server: transport.api_base)   # => the directory
      #
      # +meta.json+ goes last because it is the commit point: {#list} skips a
      # directory without one, so a save that dies half-way leaves an
      # *unlisted* conversation rather than a listed one that cannot be opened.
      # {#delete} inverts the order for the same reason.
      #
      # An empty history still commits — whether a conversation with no
      # messages deserves a folder is the caller's call, not the folder's.
      #
      # @param entry [Entry] from {#create}, {#list} or {#find}; its +title+
      #   and +created_at+ are what the envelope records
      # @param history [Pikuri::Agent::History]
      # @param model [String] what the agent is *on* — read off its transport,
      #   never off a selection, so this and +history.json+'s last +model_id+
      #   agree by construction
      # @param server [String] the transport's +api_base+
      # @param updated_at [Time] last-activity stamp
      # @param extra [Hash{String => Object}] host-owned envelope keys, written
      #   beside the store's own; JSON-safe values
      # @return [Pathname] the conversation's directory
      # @raise [ArgumentError] when +extra+ reuses one of {RESERVED_KEYS}
      # @raise [SystemCallError] when a write fails
      def save(entry, history, model:, server:, updated_at: Time.now, extra: {})
        clash = extra.keys.map(&:to_s) & RESERVED_KEYS
        raise ArgumentError, "extra: reuses the store's own key(s) #{clash.join(', ')}" unless clash.empty?

        mkdir_private(entry.dir)
        HistoryFile.save(history, entry.dir)
        write_meta(entry, model: model, server: server, updated_at: updated_at, extra: extra)
        entry.dir
      end

      # Write a message's images into the conversation's +attachments/+
      # *before* its turn, so a picture is on disk by the time any tab asks
      # for it.
      #
      #   store.stash(entry, [attachment])   # => dir/attachments/3f9a1c8e2b-shot.png
      #
      # The names are {HistoryFile.stored_name}'s, and {HistoryFile.save}
      # skips a name that already exists — so this does not write twice, it
      # moves the write out of the turn-end save to the caller's thread. The
      # folder appears here rather than at the first save when a
      # conversation's opening message carries an image; it stays unlisted
      # until +meta.json+ lands.
      #
      # A process killed mid-turn leaves the images with nothing referencing
      # them — an orphan {HistoryFile.save} itself accepts. A delete racing
      # the message is the caller's to clean up, by deleting again.
      #
      # @param entry [Entry]
      # @param attachments [Array<Pikuri::Attachment>]
      # @return [void]
      # @raise [SystemCallError] when the write fails
      def stash(entry, attachments)
        return if attachments.empty?

        mkdir_private(entry.dir)
        root = entry.dir / HistoryFile::ATTACHMENTS_DIR
        root.mkpath
        attachments.each do |attachment|
          path = root / HistoryFile.stored_name(attachment)
          next if path.exist?

          # A name of its own, not atomic_write's fixed one: two tabs sending
          # the same image at once would otherwise write through one temp file.
          tmp = root / ".#{path.basename}.#{SecureRandom.hex(4)}.tmp"
          tmp.binwrite(attachment.bytes)
          tmp.rename(path.to_path)
        end
        nil
      end

      # One stored attachment, by the name {#stash} or {HistoryFile.save} gave it.
      #
      #   store.attachment(entry, params['name'])   # => Pathname, or nil
      #
      # Resolved through the folder's listing, like {#find}, so a name
      # arriving from a URL can only ever pick a file that is already there.
      #
      # @param entry [Entry]
      # @param name [String]
      # @return [Pathname, nil] nil for a name that is not in the folder
      def attachment(entry, name)
        (entry.dir / HistoryFile::ATTACHMENTS_DIR).children.find { |path| path.basename.to_s == name && path.file? }
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      # Whether this conversation still carries the start stamp it was minted
      # with — i.e. nothing has named it yet; a titler's cue.
      #
      # The test is the stamp's *shape*, because +meta.json+'s +title+ always
      # holds something and +row+ falls back to the stamp when it does not. A
      # model-written title colliding with +"%Y-%m-%d %H:%M"+ is not a real
      # case.
      #
      # @param entry [Entry]
      # @return [Boolean]
      def stamp_titled?(entry)
        entry.title == stamp_title(entry.created_at)
      end

      # Rename a conversation: in memory always, on disk when there is an
      # envelope to rewrite.
      #
      #   entry = store.retitle(entry, 'Keeping An Avocado')
      #
      # The renamed {Entry} is the return value because it is frozen and
      # {#save} writes +entry.title+ — a caller that kept the old value would
      # revert the rename at its next save.
      #
      # No envelope yet (minted, first turn not saved), or one this reader
      # cannot stand behind, is renamed in memory alone: the next {#save}
      # writes +meta.json+ whole and carries the title anyway. The directory
      # is untouched in every case — a title never appears in a path.
      #
      # @param entry [Entry]
      # @param title [String] stored as given — capping and sanitizing belong
      #   to whoever produced it
      # @return [Entry] the same conversation, retitled
      # @raise [SystemCallError] like {#save}, when the write itself fails; a
      #   folder deleted underneath is the caller's to tolerate
      def retitle(entry, title)
        path = entry.dir / META_FILE
        meta = load_meta(path)
        atomic_write(path, "#{JSON.pretty_generate(meta.merge('title' => title))}\n") if meta.is_a?(Hash)
        entry.with(title: title)
      end

      # Remove a conversation from disk — folder, +history.json+,
      # +attachments/+.
      #
      #   store.delete(store.find(params['id']))   # => true
      #
      # +meta.json+ is unlinked *before* the folder, inverting {#save}'s
      # commit point: a removal that dies half-way then leaves a conversation
      # unlisted, rather than one that lists and cannot be opened.
      #
      # Takes an {Entry} rather than an id, like {#find}, so no caller turns
      # user input into a path. Nothing is refcounted — attachments are never
      # shared between conversations.
      #
      # @param entry [Entry] from {#list}, {#find} or {#create}
      # @return [Boolean] true when a folder was removed; false when there was
      #   nothing on disk — a conversation minted but never saved
      # @raise [ArgumentError] when the entry does not live under the root
      def delete(entry)
        raise ArgumentError, "#{entry.id} is not under #{@root}" unless entry.dir.parent == @root
        return false unless entry.dir.exist?

        FileUtils.rm_f((entry.dir / META_FILE).to_path)
        FileUtils.rm_r(entry.dir.to_path)
        true
      end

      private

      # Write +meta.json+, into a directory {#save} has already created 0700.
      # The store's own keys go last, so they win over a stray +extra+ one.
      def write_meta(entry, model:, server:, updated_at:, extra:)
        meta = extra.transform_keys(&:to_s).merge(
          'schema' => SCHEMA,
          'id' => entry.id,
          'title' => entry.title,
          'created_at' => entry.created_at.utc.iso8601,
          'updated_at' => updated_at.utc.iso8601,
          'shell' => @shell,
          'model' => model,
          'server' => server
        )
        atomic_write(entry.dir / META_FILE, "#{JSON.pretty_generate(meta)}\n")
      end

      # One listing row, or nil for a directory that is not a committed
      # conversation.
      def row(dir)
        return nil unless dir.directory?

        # The stamp comes from the directory name rather than meta.json's
        # created_at: the name is the sort key, so a disagreeing envelope would
        # sort a conversation in one place and date it in another.
        created_at = id_time(dir.basename.to_s)
        return nil if created_at.nil?

        # No +file?+ check first: the read's own ENOENT is the answer, and a
        # check-then-read would call a conversation being deleted right now
        # "unsupported format" instead of dropping it.
        meta = load_meta(dir / META_FILE)
        return nil if meta == :absent

        title = meta && meta['title']
        model, server = saved_connection(meta)
        Entry.new(
          id: dir.basename.to_s, dir: dir,
          title: title.is_a?(String) ? title : stamp_title(created_at),
          created_at: created_at, supported: !meta.nil?,
          model: model, server: server,
          extra: meta ? meta.except(*RESERVED_KEYS).freeze : {}
        )
      end

      # The envelope; nil when this reader can't stand behind it — corrupt, or
      # written by a schema it doesn't know — and +:absent+ when there is no
      # envelope at all, which is a save interrupted between the history and
      # the envelope rather than a conversation to list.
      #
      # @return [Hash, nil, :absent]
      def load_meta(path)
        meta = JSON.parse(path.read)
        meta if meta.is_a?(Hash) && meta['schema'] == SCHEMA
      rescue Errno::ENOENT
        :absent
      rescue JSON::ParserError, SystemCallError
        nil
      end

      # @return [Time, nil] nil when the name is not one of our ids
      def id_time(basename)
        match = ID.match(basename)
        match && Time.utc(*match.captures.map(&:to_i))
      rescue ArgumentError
        # Shaped like an id but not a date (month 99): one hand-made directory
        # must not take the whole listing down.
        nil
      end

      # The local-time start stamp a conversation is titled by until something
      # better replaces it.
      def stamp_title(at) = at.getlocal.strftime('%Y-%m-%d %H:%M')

      # The pair is one value: half of it is none of it, and a half-written or
      # hand-edited one reads as no connection at all. An envelope carrying a
      # +model+ and no +server+ is the case that matters: that +model+ named
      # the connection its *writer* was booted on, not the conversation's.
      #
      # @return [Array(String, String), Array(nil, nil)]
      def saved_connection(meta)
        pair = %w[model server].map { |key| meta && meta[key] }
        pair.all?(String) ? pair : [nil, nil]
      end

      # 0700 explicitly rather than through +mkdir_p+'s +mode:+, which a umask
      # can widen.
      def mkdir_private(dir)
        FileUtils.mkdir_p(dir.to_path)
        FileUtils.chmod(0o700, dir.to_path)
      end

      # Sibling temp file plus rename, so a reader never sees a half-written
      # +meta.json+.
      def atomic_write(path, content)
        tmp = path.dirname / ".#{path.basename}.tmp"
        tmp.write(content)
        tmp.rename(path.to_path)
      end
    end
  end
end
