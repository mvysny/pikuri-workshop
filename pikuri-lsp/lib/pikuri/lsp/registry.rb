# frozen_string_literal: true

module Pikuri
  module Lsp
    # Pure configuration: which language servers exist, how to launch each, and
    # which files each one claims. No I/O and no live state — a host writes this
    # once and {ClientWrapper} spawns from it.
    #
    #   registry = Registry.new(entries: [
    #     Registry::StdioEntry.new(id: 'ruby', command: %w[ruby-lsp],
    #                              files: %w[*.rb *.rake *.gemspec Rakefile Gemfile]),
    #     Registry::StdioEntry.new(id: 'java', command: ['jdtls', '-data', data_dir],
    #                              files: %w[*.java],
    #                              env: { 'JAVA_HOME' => ENV.fetch('JAVA_HOME') },
    #                              init_options: { extendedClientCapabilities: {
    #                                classFileContentsSupport: true } })
    #   ])
    #   registry.entry_for('lib/pikuri/agent.rb').id   # => "ruby"
    #   registry.entry_for('Gemfile').id               # => "ruby"
    #   registry.entry_for('README.md')                # => nil
    #
    # A Ruby server is two facts, +command+ and +files+; the Java one exercises
    # every remaining field.
    class Registry
      # Extension → LSP language identifier, for entries that don't spell out a
      # +language_id:+. Only the +didOpen+ notification uses it, and a server
      # given the wrong one indexes nothing, so an unmapped extension is a
      # config error rather than a guess.
      LANGUAGE_IDS = {
        '.rb' => 'ruby', '.rake' => 'ruby', '.gemspec' => 'ruby',
        '.java' => 'java', '.kt' => 'kotlin', '.kts' => 'kotlin',
        '.scala' => 'scala', '.groovy' => 'groovy', '.clj' => 'clojure',
        '.py' => 'python', '.js' => 'javascript', '.jsx' => 'javascriptreact',
        '.ts' => 'typescript', '.tsx' => 'typescriptreact',
        '.go' => 'go', '.rs' => 'rust', '.c' => 'c', '.h' => 'c',
        '.cpp' => 'cpp', '.cc' => 'cpp', '.hpp' => 'cpp', '.cs' => 'csharp',
        '.php' => 'php', '.swift' => 'swift', '.dart' => 'dart',
        '.ex' => 'elixir', '.exs' => 'elixir', '.erl' => 'erlang',
        '.hs' => 'haskell', '.lua' => 'lua', '.pl' => 'perl', '.r' => 'r',
        '.jl' => 'julia', '.sh' => 'shellscript', '.sql' => 'sql',
        '.html' => 'html', '.css' => 'css', '.scss' => 'scss',
        '.json' => 'json', '.yaml' => 'yaml', '.yml' => 'yaml',
        '.xml' => 'xml', '.md' => 'markdown', '.tex' => 'latex'
      }.freeze

      # One language server: the argv to launch it and the files it answers for.
      #
      # +files+ holds *basename* globs, not extensions, because +Rakefile+ has
      # none — and it is the dispatch key, so getting it wrong sends Ruby
      # questions to a Java server rather than merely failing.
      #
      # @!attribute [r] id
      #   @return [String] this server's name in log lines, restart messages and
      #     {ServerProgress#server_id}, e.g. +"ruby"+. Never model-facing: the
      #     model names no server, it names a file.
      # @!attribute [r] command
      #   @return [Array<String>] argv, e.g. +["jdtls", "-data", "/…/cache"]+.
      #     Spawned with cwd = the workspace root, always.
      # @!attribute [r] files
      #   @return [Array<String>] basename globs, e.g.
      #     +["*.rb", "*.rake", "Rakefile"]+. First entry whose glob matches
      #     wins; overlaps are not detected.
      # @!attribute [r] language_id
      #   @return [String] the +languageId+ every +didOpen+ carries, e.g.
      #     +"ruby"+. Derived at construction from the first extension-bearing
      #     glob when not given — per *entry*, not per file, which is wrong for
      #     the +eslint+-shaped server that claims eight extensions and right for
      #     everything pikuri has met.
      # @!attribute [r] env
      #   @return [Hash{String => String}] extra environment for the child,
      #     merged over the de-bundlerized environment ({Pikuri::BundlerEnv}), e.g.
      #     +{"JAVA_HOME" => "/usr/lib/jvm/java-21"}+. Frozen, defaults to +{}+.
      #     The legitimate per-child credential channel of the "environment is
      #     not a secret store" seam.
      # @!attribute [r] init_options
      #   @return [Hash, nil] +initializationOptions+, passed verbatim at
      #     handshake time and never parsed by pikuri — the home for outbound
      #     per-server glue, e.g. jdtls's +classFileContentsSupport+, without
      #     which every library symbol answers with silence. There is
      #     deliberately no sibling +settings:+ field for answering the
      #     server's +workspace/configuration+ requests: {Connection} replies
      #     +null+ to every server-initiated request, and both reference
      #     servers tolerate that.
      StdioEntry = Data.define(:id, :command, :files, :language_id, :env, :init_options) do
        # @raise [ArgumentError] on an empty +id+ / +command+ / +files+, or when
        #   +language_id:+ is omitted and no glob in +files+ carries an
        #   extension {LANGUAGE_IDS} knows.
        def initialize(id:, command:, files:, language_id: nil, env: {}, init_options: nil)
          raise ArgumentError, "id must be a non-empty String, got #{id.inspect}" if id.to_s.empty?
          raise ArgumentError, "command must be a non-empty argv Array, got #{command.inspect}" if command.to_a.empty?
          raise ArgumentError, "files must be a non-empty glob Array, got #{files.inspect}" if files.to_a.empty?

          super(id: id, command: command.freeze, files: files.freeze,
                language_id: language_id || Registry.derive_language_id(files, id),
                env: env.freeze, init_options: init_options)
        end

        # Whether this server answers for +path+ — matched on the basename, so a
        # directory component never decides which server sees a file.
        #
        # @param path [String, Pathname] absolute or relative; only the basename
        #   is read.
        # @return [Boolean]
        def claims?(path)
          basename = File.basename(path.to_s)
          files.any? { |glob| File.fnmatch?(glob, basename, File::FNM_DOTMATCH) }
        end
      end

      # The fields a {StdioEntry} accepts from a config file — everything but
      # +id+, which is the key it is written under.
      ENTRY_FIELDS = %i[command files language_id env init_options].freeze

      # Builds a registry out of a plain Hash, so a host can map its own config
      # file onto one — which is where this belongs, because *which language
      # servers you have installed* is machine state, like an API key. The demo
      # scripts read the YAML they already keep keys in:
      #
      #   # ~/.pikuri-examples-config.yaml
      #   lsp_servers:
      #     ruby:
      #       command: [ruby-lsp]
      #       files: ["*.rb", "*.rake", "*.gemspec", Rakefile, Gemfile]
      #     java:
      #       command: [jdtls, -data, /home/me/.cache/pikuri/jdtls/my-app]
      #       files: ["*.java"]
      #       env:
      #         JAVA_HOME: /usr/lib/jvm/java-21
      #       init_options:
      #         extendedClientCapabilities:
      #           classFileContentsSupport: true
      #
      #   Registry.from_h(YAML.safe_load_file(path)['lsp_servers'])
      #
      # Nothing here knows what YAML is; a host reading TOML, JSON or its own
      # settings object uses the same method. Keyed by server id rather than
      # holding a list of +{id: …}+ Hashes, which makes the duplicate
      # {#initialize} refuses unwritable; insertion order is dispatch order.
      #
      # Two things a config file cannot do, both visible above. It cannot
      # *compute*, so jdtls's +-data+ path is spelled out rather than derived
      # from {Pikuri::Paths.cache} — a host that wants it computed builds the
      # {StdioEntry} in Ruby, which is equally first-class. And it cannot be
      # type-checked by the person writing it, so every field is validated here
      # rather than coerced: a mistyped +env+ is otherwise a jdtls that
      # hard-fails below Java 21, and a mistyped +init_options+ is every Java
      # library symbol answering with silence.
      #
      # @param config [Hash{String, Symbol => Hash}, nil] server id → that
      #   server's {StdioEntry} fields, with String or Symbol keys. +nil+ — what
      #   a host reading an absent config key gets — yields an empty registry,
      #   so no caller needs a +|| {}+.
      # @return [Registry]
      # @raise [ArgumentError] on an unknown field, a field of the wrong type,
      #   or anything {StdioEntry} itself refuses (an unguessable
      #   +language_id+, an empty +id+).
      def self.from_h(config)
        new(entries: (config || {}).map { |id, fields| entry_from_h(id.to_s, fields) })
      end

      # One +id => fields+ pair as a {StdioEntry}.
      #
      # @param id [String] the key it was written under.
      # @param fields [Hash] its config fields.
      # @return [StdioEntry]
      # @raise [ArgumentError] as {from_h}.
      def self.entry_from_h(id, fields)
        unless fields.is_a?(Hash)
          raise ArgumentError, "lsp server #{id.inspect}: expected a Hash of fields, got #{fields.inspect}"
        end

        fields = fields.transform_keys(&:to_sym)
        unknown = fields.keys - ENTRY_FIELDS
        unless unknown.empty?
          raise ArgumentError, "lsp server #{id.inspect}: unknown field(s) #{unknown.join(', ')} — " \
                               "known fields are #{ENTRY_FIELDS.join(', ')}"
        end

        StdioEntry.new(
          id: id,
          command: string_list(id, :command, fields[:command]),
          files: string_list(id, :files, fields[:files]),
          language_id: typed(id, :language_id, fields[:language_id], String),
          env: string_hash(id, fields[:env]),
          init_options: typed(id, :init_options, fields[:init_options], Hash)
        )
      end

      # @param id [String] the server id, for the message.
      # @param field [Symbol] the field name, for the message.
      # @param value [Object] the configured value.
      # @return [Array<String>]
      # @raise [ArgumentError] unless +value+ is a non-empty Array of Strings.
      def self.string_list(id, field, value)
        return value if value.is_a?(Array) && !value.empty? && value.all?(String)

        raise ArgumentError,
              "lsp server #{id.inspect}: #{field} must be a non-empty list of strings, got #{value.inspect}"
      end

      # @param id [String] the server id, for the message.
      # @param value [Object] the configured +env+, or +nil+.
      # @return [Hash{String => String}] empty when +nil+.
      # @raise [ArgumentError] unless every key and value is a String; a child
      #   environment holds strings, and an unquoted +PORT: 8080+ is the way in.
      def self.string_hash(id, value)
        return {} if value.nil?

        unless value.is_a?(Hash)
          raise ArgumentError, "lsp server #{id.inspect}: env must be a mapping, got #{value.inspect}"
        end

        value.to_h do |name, setting|
          unless setting.is_a?(String)
            raise ArgumentError,
                  "lsp server #{id.inspect}: env #{name} must be a String, got #{setting.inspect}"
          end

          [name.to_s, setting]
        end
      end

      # @param id [String] the server id, for the message.
      # @param field [Symbol] the field name, for the message.
      # @param value [Object] the configured value.
      # @param type [Class] what it must be when given.
      # @return [Object, nil] +value+, unchanged.
      # @raise [ArgumentError] unless +value+ is +nil+ or a +type+.
      def self.typed(id, field, value, type)
        return value if value.nil? || value.is_a?(type)

        raise ArgumentError, "lsp server #{id.inspect}: #{field} must be a #{type}, got #{value.inspect}"
      end

      private_class_method :entry_from_h, :string_list, :string_hash, :typed

      # LSP language id for a +files:+ list.
      #
      # @param files [Array<String>] basename globs.
      # @param id [String] the entry's id, for the error message.
      # @return [String]
      # @raise [ArgumentError] when no glob carries a known extension.
      def self.derive_language_id(files, id)
        files.each do |glob|
          extension = glob[/\.[A-Za-z0-9]+\z/]&.downcase
          language = extension && LANGUAGE_IDS[extension]
          return language if language
        end
        raise ArgumentError,
              "cannot derive language_id for #{id.inspect} from files: #{files.inspect} — " \
              'pass language_id: explicitly'
      end

      # @return [Array<StdioEntry>] the entries, in declaration order.
      attr_reader :entries

      # @param entries [Array<StdioEntry>] zero or more servers. Order is the
      #   dispatch order.
      # @raise [ArgumentError] if two entries share an id — one would shadow the
      #   other's log lines and progress bars.
      def initialize(entries: [])
        duplicate = entries.map(&:id).tally.find { |_, count| count > 1 }
        raise ArgumentError, "duplicate server id #{duplicate.first.inspect}" if duplicate

        @entries = entries.freeze
      end

      # The server that answers for +path+, or +nil+ when none claims it.
      #
      # @param path [String, Pathname]
      # @return [StdioEntry, nil]
      def entry_for(path)
        @entries.find { |entry| entry.claims?(path) }
      end

      # @return [Boolean] whether no server is configured, in which case a host
      #   wires no +lsp+ tool at all.
      def empty?
        @entries.empty?
      end

      # The no-servers default, so a host that configures nothing passes nothing.
      EMPTY = new
    end
  end
end
