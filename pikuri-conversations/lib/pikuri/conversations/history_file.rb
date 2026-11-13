# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'

module Pikuri
  class Conversations
    # The file format of a stored {Pikuri::Agent::History}: pikuri hands a
    # conversation out as an in-memory value and never writes one, so
    # resuming across a restart needs this. Two encodings of one value:
    #
    #   json = HistoryFile.to_json(agent.export_history)    # self-contained, base64 inside
    #   history = HistoryFile.parse(json)
    #
    #   HistoryFile.save(agent.export_history, dir)         # dir/history.json + attachments/
    #   history = HistoryFile.load(dir)
    #
    #   Pikuri::Agent.new(transport: t, system_prompt: p, history: history)
    #
    # Both round-trip to the same value, which is the property that keeps them
    # from drifting into two formats:
    #
    #   HistoryFile.load(dir) == HistoryFile.parse(json)   # => true
    #
    # The system prompt is *not* stored — the resuming agent assembles its own
    # from every extension, so a resumed conversation gets today's prompt.
    #
    # == The doors in are the validators
    #
    # {parse}, {from_h} and {load} are the only ways to build a history from
    # stored bytes, and each raises {Error} rather than returning something
    # half-built. A tool call with no result is legal — it is what a process
    # killed mid-batch leaves behind, and +Agent.new(history:)+ repairs it
    # (+pikuri:D_history_load_repairs+); a result with no call, or one call
    # answered twice, is corruption and refused. Unknown keys are ignored, so
    # a file from a newer writer still loads; a version above {VERSION} is
    # refused outright. See +design/decisions.md+ +D_history_file+.
    #
    # == Attachments
    #
    # {save} writes each attachment once, content-addressed under
    # {ATTACHMENTS_DIR}, and never deletes; {load} reads one only if it is a
    # plain file directly inside that folder whose bytes still match the
    # digest in its name. See +design/decisions.md+ +D_history_attachments+.
    #
    # == Implementation details
    #
    # Every {Pikuri::Attachment} field is written by +attachment_to_h+ and read
    # by +attachment_from_h+; a field pikuri adds there must be added to both,
    # or it is dropped on save without a sound — the spec pins
    # +Pikuri::Attachment.members+ so that fails loudly.
    #
    # The container is one JSON object, rewritten whole, not JSONL — see
    # +design/decisions.md+ +D_history_container+.
    #
    # Stateless; thread-safe for different folders. Two saves into one folder
    # at once share {save}'s fixed temp name, so a host serializes them — one
    # writer per conversation.
    module HistoryFile
      # Bumped only for a change an old reader could not survive; an added
      # optional key is not one (readers ignore unknown keys). A file claiming
      # a higher version is refused, never best-effort loaded.
      #
      # @return [Integer]
      VERSION = 1

      # Basename of the JSON {save} writes and {load} reads.
      #
      # @return [String]
      HISTORY_FILE = 'history.json'

      # Subfolder {save} writes attachment bytes into. Fixed, so "in the
      # folder" is one comparison rather than a policy.
      #
      # @return [String]
      ATTACHMENTS_DIR = 'attachments'

      # Message roles a stored history may hold. +system+ cannot: the prompt
      # is re-assembled, not replayed.
      #
      # @return [Array<String>]
      ROLES = %w[user assistant tool].freeze

      # Raised by every door in: malformed JSON or a bad record, a dangling
      # tool result, an attachment outside the folder, a version from the
      # future.
      class Error < StandardError; end

      class << self
        # The self-contained Hash: attachments inline, as base64.
        #
        # @param history [Pikuri::Agent::History]
        # @param inline_attachments [Boolean] +false+ renders each attachment
        #   as a reference to its {stored_name}, which only {save} wants — the
        #   bytes then live in the folder, not the Hash.
        # @return [Hash{String => Object}] JSON-safe, String keys.
        def to_h(history, inline_attachments: true)
          {
            'version' => VERSION,
            'messages' => history.messages.map { |m| message_to_h(m, inline_attachments) }
          }
        end

        # @param history [Pikuri::Agent::History]
        # @return [String] pretty-printed {to_h}, so a stored conversation
        #   stays readable and diffs a turn at a time.
        def to_json(history)
          JSON.pretty_generate(to_h(history))
        end

        # Write +dir/history.json+ plus +dir/attachments/+, creating the
        # folder if needed.
        #
        #   HistoryFile.save(agent.export_history, '~/conversations/2026-08-27-abc')
        #
        # Attachments are written **first**: +history.json+ is the commit
        # point, so an interrupted save leaves unreferenced bytes (harmless)
        # rather than a reference to bytes that are not there.
        #
        # Never deletes, and never enumerates the folder: an attachment the
        # history no longer references simply stays, since this writes into a
        # folder it does not own outright. Re-saving is idempotent: a
        # content-addressed name that already exists is skipped after one
        # +stat+, so cost tracks the history rather than the folder.
        #
        # @param history [Pikuri::Agent::History]
        # @param dir [String, Pathname] destination; created if absent.
        # @return [Pathname] +dir+, so a caller can chain.
        def save(history, dir)
          dir = Pathname(dir).expand_path
          attachments = history.messages.flat_map(&:attachments)

          unless attachments.empty?
            root = dir / ATTACHMENTS_DIR
            root.mkpath
            attachments.each do |a|
              path = root / stored_name(a)
              atomic_write(path, a.bytes) unless path.exist?
            end
          end

          dir.mkpath
          atomic_write(dir / HISTORY_FILE, JSON.pretty_generate(to_h(history, inline_attachments: false)))
          dir
        end

        # Parse the self-contained JSON form.
        #
        #   HistoryFile.parse(File.read('conv.json'))
        #
        # @param json [String] what {to_json} produced.
        # @return [Pikuri::Agent::History]
        # @raise [Error] on malformed JSON, a bad record, a future version, or
        #   an attachment stored as a file — a String has no folder to resolve
        #   one against, so that case names {load} rather than guessing.
        def parse(json)
          raw = begin
            JSON.parse(json)
          rescue JSON::ParserError => e
            raise Error, "history is not valid JSON: #{e.message}"
          end
          from_h(raw)
        end

        # Read a folder written by {save}.
        #
        # @param dir [String, Pathname] the folder holding {HISTORY_FILE}.
        # @return [Pikuri::Agent::History]
        # @raise [Error] as {from_h}, plus a missing, unreadable, or
        #   digest-mismatched attachment.
        def load(dir)
          dir = Pathname(dir)
          file = dir / HISTORY_FILE
          raise Error, "no #{HISTORY_FILE} in #{dir}" unless file.file?

          raw = begin
            JSON.parse(file.read)
          rescue JSON::ParserError => e
            raise Error, "#{file} is not valid JSON: #{e.message}"
          end
          from_h(raw, dir: dir)
        end

        # Validate a plain Hash — the shared gate {parse} and {load} both run
        # through, and the only place a record's shape is checked.
        #
        # Unknown *keys* are ignored, so a file written by a newer writer
        # still loads; malformed *known* keys raise. That asymmetry is the
        # whole forward-compatibility story, and it is why {VERSION} is
        # expected to stay +1+.
        #
        # @param raw [Hash] parsed JSON, String keys.
        # @param dir [Pathname, nil] folder to resolve file-backed attachments
        #   against; +nil+ refuses them.
        # @return [Pikuri::Agent::History]
        # @raise [Error] on a non-Hash, a version above {VERSION}, a message
        #   with a bad role/kind/id, a duplicate id, or a +tool+ message whose
        #   +tool_call_id+ no preceding assistant message issued.
        def from_h(raw, dir: nil)
          raise Error, "expected a Hash, got #{raw.class}" unless raw.is_a?(Hash)

          version = raw['version']
          raise Error, "missing version (expected #{VERSION})" if version.nil?
          if version.is_a?(Integer) && version > VERSION
            raise Error, "history version #{version} is newer than this reader understands " \
                         "(#{VERSION}); upgrade pikuri-conversations to read it"
          end
          raise Error, "version must be #{VERSION}, got #{version.inspect}" unless version == VERSION

          messages = raw['messages']
          raise Error, "messages must be an Array, got #{messages.class}" unless messages.is_a?(Array)

          built = messages.each_with_index.map { |m, i| message_from_h(m, i, dir) }
          check_ids!(built)
          check_tool_pairing!(built)
          Pikuri::Agent::History.new(messages: built)
        end

        # Content-addressed filename: the digest prefix makes it unique and
        # self-verifying, so the same image read twice is stored once and a
        # tampered file is caught at {load}.
        #
        #   HistoryFile.stored_name(Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: png))
        #   # => "3f9a1c8e2b-shot.png"
        #
        # @param attachment [Pikuri::Attachment]
        # @return [String] a bare basename, never a path.
        def stored_name(attachment)
          ext = File.extname(attachment.filename.to_s)
          stem = File.basename(attachment.filename.to_s, ext).gsub(/[^A-Za-z0-9._-]+/, '-')
          stem = 'attachment' if stem.empty?
          "#{Digest::SHA256.hexdigest(attachment.bytes)[0, 10]}-#{stem}#{ext}"
        end

        private

        def message_to_h(msg, inline)
          h = {
            'id' => msg.id,
            'role' => msg.role,
            'kind' => msg.kind,
            'content' => msg.content
          }
          h['attachments'] = msg.attachments.map { |a| attachment_to_h(a, inline) } unless msg.attachments.empty?
          h['tool_calls'] = msg.tool_calls.map { |c| tool_call_to_h(c) } unless msg.tool_calls.empty?
          h['tool_call_id'] = msg.tool_call_id if msg.tool_call_id
          h['summary'] = msg.summary if msg.summary
          h['model_id'] = msg.model_id if msg.model_id
          h['thinking'] = compact_h(msg.thinking) if msg.thinking
          h['tokens'] = compact_h(msg.tokens) if msg.tokens
          h
        end

        # Drops an absent display string rather than writing +null+, so a file
        # written before summaries existed and one written by a wiring that
        # had no tool to ask are the same bytes.
        def tool_call_to_h(call)
          h = { 'id' => call.id, 'name' => call.name, 'arguments' => call.arguments }
          h['display_name'] = call.display_name if call.display_name
          h['argument'] = call.argument if call.argument
          h
        end

        # Every {Pikuri::Attachment} field, mirrored by +attachment_from_h+; a
        # new field belongs in both.
        def attachment_to_h(att, inline)
          base = { 'mime' => att.mime, 'filename' => att.filename }
          if inline
            base.merge('kind' => 'inline', 'bytes' => [att.bytes].pack('m0'))
          else
            base.merge('kind' => 'file', 'file' => stored_name(att))
          end
        end

        def compact_h(value)
          value.to_h.compact.transform_keys(&:to_s)
        end

        # Write via a sibling temp file and rename, so a reader never sees a
        # half-written file and a crash cannot leave one.
        def atomic_write(path, content)
          tmp = path.dirname / ".#{path.basename}.tmp"
          tmp.binwrite(content)
          tmp.rename(path.to_s)
        end

        def message_from_h(raw, index, dir)
          raise Error, "message #{index}: expected a Hash, got #{raw.class}" unless raw.is_a?(Hash)

          role = raw['role']
          raise Error, "message #{index}: role must be one of #{ROLES.join('/')}, got #{role.inspect}" unless
            ROLES.include?(role)

          # Absent kind reads as "user": additive fields must not break an
          # older file, and this is the only field with a sensible default.
          kinds = Pikuri::Agent::History::KINDS
          kind = raw['kind'] || 'user'
          raise Error, "message #{index}: kind must be one of #{kinds.join('/')}, got #{kind.inspect}" unless
            kinds.include?(kind)

          id = raw['id']
          raise Error, "message #{index}: id must be a non-empty String, got #{id.inspect}" unless
            id.is_a?(String) && !id.empty?

          tool_call_id = raw['tool_call_id']
          if role == 'tool' && !(tool_call_id.is_a?(String) && !tool_call_id.empty?)
            raise Error, "message #{index} (#{id}): a tool message needs a tool_call_id, got #{tool_call_id.inspect}"
          end
          if role != 'tool' && !tool_call_id.nil?
            raise Error, "message #{index} (#{id}): only a tool message may carry a tool_call_id"
          end

          Pikuri::Agent::History::Message.new(
            id: id, role: role, kind: kind,
            content: string_field(raw['content'], index, id, 'content'),
            attachments: (raw['attachments'] || []).map { |a| attachment_from_h(a, index, id, dir) },
            tool_calls: (raw['tool_calls'] || []).map { |t| tool_call_from_h(t, index, id) },
            tool_call_id: tool_call_id,
            model_id: raw['model_id'],
            thinking: thinking_from_h(raw['thinking'], index, id),
            tokens: tokens_from_h(raw['tokens'], index, id),
            summary: display_string(raw['summary'], index, id, 'summary')
          )
        end

        def string_field(value, index, id, name)
          return value if value.is_a?(String)
          return '' if value.nil?

          raise Error, "message #{index} (#{id}): #{name} must be a String, got #{value.class}"
        end

        def tool_call_from_h(raw, index, id)
          raise Error, "message #{index} (#{id}): each tool_call must be a Hash" unless raw.is_a?(Hash)

          call_id = raw['id']
          raise Error, "message #{index} (#{id}): a tool_call needs a non-empty id" unless
            call_id.is_a?(String) && !call_id.empty?
          raise Error, "message #{index} (#{id}): tool_call #{call_id} needs a name" unless raw['name'].is_a?(String)

          args = raw['arguments'] || {}
          raise Error, "message #{index} (#{id}): tool_call #{call_id} arguments must be a Hash" unless args.is_a?(Hash)

          Pikuri::Agent::History::ToolCall.new(
            id: call_id, name: raw['name'], arguments: args,
            display_name: display_string(raw['display_name'], index, id, 'display_name'),
            argument: display_string(raw['argument'], index, id, 'argument')
          )
        end

        # A stored display string: absent reads as +nil+ (an older file, or a
        # wiring that had no tool to ask), present must be a String.
        def display_string(value, index, id, name)
          return nil if value.nil?
          return value if value.is_a?(String)

          raise Error, "message #{index} (#{id}): #{name} must be a String, got #{value.class}"
        end

        def thinking_from_h(raw, index, id)
          return nil if raw.nil?
          raise Error, "message #{index} (#{id}): thinking must be a Hash" unless raw.is_a?(Hash)

          Pikuri::Agent::History::Thinking.new(text: raw['text'], signature: raw['signature'])
        end

        def tokens_from_h(raw, index, id)
          return nil if raw.nil?
          raise Error, "message #{index} (#{id}): tokens must be a Hash" unless raw.is_a?(Hash)

          Pikuri::Agent::History::Tokens.new(
            input: raw['input'], output: raw['output'], cached: raw['cached'],
            cache_creation: raw['cache_creation'], thinking: raw['thinking']
          )
        end

        def attachment_from_h(raw, index, id, dir)
          raise Error, "message #{index} (#{id}): each attachment must be a Hash" unless raw.is_a?(Hash)

          filename = raw['filename'].to_s
          bytes =
            case raw['kind']
            when 'inline' then decode_inline(raw['bytes'], index, id)
            when 'file' then read_confined(dir, raw['file'], index, id)
            else raise Error, "message #{index} (#{id}): attachment kind must be inline or file, " \
                              "got #{raw['kind'].inspect}"
            end

          Pikuri::Attachment.new(mime: raw['mime'], filename: filename, bytes: bytes)
        end

        def decode_inline(data, index, id)
          raise Error, "message #{index} (#{id}): inline attachment needs base64 bytes" unless data.is_a?(String)

          data.unpack1('m0')
        rescue ArgumentError => e
          raise Error, "message #{index} (#{id}): attachment base64 is malformed: #{e.message}"
        end

        # Read one attachment, refusing anything that is not a plain file
        # directly inside +dir/attachments+.
        #
        # The comparison is on the **resolved** path, not the string: a file
        # sitting in the folder may itself be a symlink to
        # +~/.ssh/id_ed25519+, which every textual check passes. That is the
        # case this method exists for.
        def read_confined(dir, name, index, id)
          where = "message #{index} (#{id})"
          if dir.nil?
            raise Error, "#{where}: this history references the external attachment #{name.inspect}; " \
                         'use HistoryFile.load(dir) rather than HistoryFile.parse'
          end
          raise Error, "#{where}: attachment file must be a String" unless name.is_a?(String)
          unless !name.empty? && name == File.basename(name) && !name.start_with?('.')
            raise Error, "#{where}: attachment file #{name.inspect} must be a bare filename"
          end

          root = dir / ATTACHMENTS_DIR
          path = root / name
          raise Error, "#{where}: attachment #{name.inspect} is missing from #{root}" unless path.file?

          real = path.realpath
          unless real.dirname == root.realpath
            raise Error, "#{where}: attachment #{name.inspect} resolves to #{real}, outside #{root}"
          end

          bytes = real.binread
          expected = name[/\A[0-9a-f]{10}/]
          if expected && !Digest::SHA256.hexdigest(bytes).start_with?(expected)
            raise Error, "#{where}: attachment #{name.inspect} does not match its content digest"
          end

          bytes
        end

        def check_ids!(messages)
          seen = {}
          messages.each_with_index do |m, i|
            if (first = seen[m.id])
              raise Error, "message #{i}: duplicate id #{m.id} (already used by message #{first})"
            end

            seen[m.id] = i
          end
        end

        # Refuse a tool result nothing asked for, and one answered twice.
        #
        # The mirror case — a call with *no* result — is deliberately legal
        # here: that is what a process killed mid-batch leaves behind, and
        # +Agent.new(history:)+ repairs it by synthesizing an interrupted
        # result. Refusing it would make the crash case the one thing that
        # cannot be loaded.
        def check_tool_pairing!(messages)
          issued = {}
          answered = {}
          messages.each_with_index do |m, i|
            m.tool_calls.each { |c| issued[c.id] = i }
            next unless m.role == 'tool'

            unless issued.key?(m.tool_call_id)
              raise Error, "message #{i} (#{m.id}): tool_call_id #{m.tool_call_id} " \
                           'was never issued by a preceding assistant message'
            end
            if (prev = answered[m.tool_call_id])
              raise Error, "message #{i} (#{m.id}): tool_call_id #{m.tool_call_id} " \
                           "was already answered by message #{prev}"
            end

            answered[m.tool_call_id] = i
          end
        end
      end
    end
  end
end
