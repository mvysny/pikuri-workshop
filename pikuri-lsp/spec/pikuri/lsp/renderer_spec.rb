# frozen_string_literal: true

require 'tmpdir'

describe Pikuri::Lsp::Renderer do
  # A filesystem that denies one path, which is the shape the container wiring
  # produces: a scoped Filesystem answers +denied?+ +false+ for everything.
  denying = Class.new do
    def initialize(filesystem) = @filesystem = filesystem
    def denied?(path) = path.to_s.include?('secret')
    def project_root = @filesystem.project_root
    def resolve_for_read(path) = @filesystem.resolve_for_read(path)
    def private? = @filesystem.private?
  end

  built = lambda do |&block|
    Dir.mktmpdir do |tmp|
      filesystem = denying.new(Pikuri::Workspace::Filesystem.new(project_root: File.realpath(tmp)))
      block.call(described_class.new(sources: Pikuri::Lsp::Sources.new(filesystem: filesystem)),
                 File.realpath(tmp))
    end
  end

  item = lambda do |name, uri, line|
    { 'name' => name, 'kind' => 5, 'uri' => uri,
      'range' => { 'start' => { 'line' => line, 'character' => 0 },
                   'end' => { 'line' => line, 'character' => 5 } } }
  end

  describe '#finish' do
    it 'leaves a short answer alone' do
      built.call { |renderer| assert_equal 'body', renderer.finish('body').to_s }
    end

    it 'appends the notes after the cut, so a long answer cannot lose them' do
      built.call do |renderer|
        renderer.note('a match is outside the workspace.')

        answer = renderer.finish("x#{'y' * described_class::MAX_BYTES}").to_s

        assert_match(/bytes omitted/, answer)
        assert answer.end_with?("Notes:\n- a match is outside the workspace."),
               'the notes are what say a result was dropped; they go last, not first'
      end
    end
  end

  # A wiring that opens anything outside the root too — the +--yolo+ and OS-agent
  # shape, where an out-of-root definition *is* actionable.
  unrestricted = lambda do |&block|
    Dir.mktmpdir do |tmp|
      filesystem = Pikuri::Workspace::Filesystem::AllowAll.new(project_root: File.realpath(tmp))
      block.call(described_class.new(sources: Pikuri::Lsp::Sources.new(filesystem: filesystem)),
                 File.realpath(tmp))
    end
  end

  hovering = lambda do |renderer, markdown|
    renderer.hover({ 'contents' => { 'kind' => 'markdown', 'value' => markdown } },
                   operation: Pikuri::Lsp::Operation['hover'], symbol: 'Pikuri::VERSION')
  end

  describe '#hover' do
    it 'rewrites a definition link to the citation every other operation prints' do
      built.call do |renderer, root|
        answer = hovering.call(
          renderer, "**Definitions**: [version.rb](file://#{root}/lib/version.rb#L9,3-9,20)"
        )

        assert_match(/\*\*Definitions\*\*: \[version\.rb\]\(lib\/version\.rb:9\)$/, answer)
        refute_match(%r{file://}, answer)
      end
    end

    it 'drops the link where a read would be refused, keeping the provenance' do
      built.call do |renderer|
        answer = hovering.call(renderer, '[entry.rb](file:///opt/gems/entry.rb#L12,1-12,2)')

        assert_match(/outside the workspace: entry\.rb/, answer)
        refute_match(/\[entry\.rb\]\(/, answer,
                     'a link to a path read refuses is the dead-end citation Sources avoids')
      end
    end

    it 'links an out-of-root path this workspace would open' do
      unrestricted.call do |renderer|
        answer = hovering.call(renderer, '[entry.rb](file:///opt/gems/entry.rb#L12,1-12,2)')

        assert_match(%r{\[entry\.rb\]\(/opt/gems/entry\.rb:12\)}, answer)
      end
    end

    it 'replaces a denied path with the refusal, link text and all' do
      built.call do |renderer, root|
        answer = hovering.call(renderer, "[secret.rb](file://#{root}/secret.rb#L1,1-1,2)")

        assert_match(/\[a path this workspace will not read\]/, answer)
        refute_match(/secret/, answer)
      end
    end

    it 'rewrites a bare URI without inventing a link, and leaves the sentence intact' do
      built.call do |renderer, root|
        answer = hovering.call(renderer, "See file://#{root}/lib/version.rb#L3, and elsewhere.")

        assert_match(/See lib\/version\.rb:3, and elsewhere\./, answer)
      end
    end

    it 'cites a URI carrying no fragment as a bare path' do
      built.call do |renderer, root|
        answer = hovering.call(renderer, "[version.rb](file://#{root}/lib/version.rb)")

        assert_match(/\[version\.rb\]\(lib\/version\.rb\)/, answer)
      end
    end

    it 'leaves every other scheme exactly as the server wrote it' do
      built.call do |renderer|
        markdown = 'See https://example.com/x and ' \
                   'jdt://contents/rt.jar/java.lang/String.class?=proj/lib.jar'

        assert answer = hovering.call(renderer, markdown)
        assert answer.include?(markdown), 'a jdt: URI has no reliable end inside prose'
      end
    end

    it 'rewrites before truncating, so the cap is spent on documentation' do
      built.call do |renderer, root|
        link = "[version.rb](file://#{root}/lib/version.rb#L9,3-9,20)"
        markdown = "#{Array.new(200, link).join(' | ')}\ndocstring"

        answer = hovering.call(renderer, markdown)

        total = answer[/total was (\d+) bytes/, 1].to_i
        assert total.positive?, 'the fixture must be long enough to truncate'
        assert total < markdown.bytesize,
               'the reported total is the rewritten text, not the absolute paths'
      end
    end
  end

  describe '#supertypes' do
    it 'numbers the levels it shows, not the ones it dropped' do
      built.call do |renderer, root|
        levels = [[item.call('Middle', "file://#{root}/secret.rb", 0)],
                  [item.call('Object', "file://#{root}/object.rb", 1)]]

        answer = renderer.supertypes(levels, operation: Pikuri::Lsp::Operation['supertypes'],
                                             symbol: 'Read')

        assert_match(/— 1 level/, answer)
        assert_match(/1\. Object/, answer)
        refute_match(/secret/, answer)
        refute_match(/2\./, answer)
      end
    end
  end
end
