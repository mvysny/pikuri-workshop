# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

RSpec.describe Pikuri::Skill::Catalog do
  FIXTURE_ROOT = File.expand_path('../../fixtures/skills', __dir__)

  # Capture warning log lines so collision / validation behavior can be
  # asserted instead of just observed in stderr. Pikuri's logger writes
  # through +Pikuri.log_io+; the spec_helper has already pointed that at
  # +/dev/null+, so we temporarily redirect to a +StringIO+ and restore.
  def captured_log
    captured = StringIO.new
    original = Pikuri.log_io
    Pikuri.log_io = captured
    yield
    captured.string
  ensure
    Pikuri.log_io = original if original
  end

  describe Pikuri::Skill::Catalog::EMPTY do
    it 'is the canonical empty singleton' do
      assert_kind_of Pikuri::Skill::Catalog, described_class
      assert described_class.empty?
      assert_equal [], described_class.list
      assert_nil described_class.get('anything')
      assert_equal [], described_class.roots
    end

    it 'is frozen' do
      assert described_class.frozen?
    end
  end

  describe Pikuri::Bundle::Base do
    it 'defaults trusted to false' do
      refute described_class.new(dir: '/tmp').trusted
    end

    it 'scans identically whether a base arrives as a Base or a bare path' do
      path = File.join(FIXTURE_ROOT, 'valid-tree')
      wrapped = Pikuri::Skill::Catalog::Bundled.new(search_bases: [described_class.new(dir: path)])
      bare = Pikuri::Skill::Catalog::Bundled.new(search_bases: [Pathname.new(path)])

      assert_equal bare.roots, wrapped.roots
      assert_equal bare.list.map(&:name), wrapped.list.map(&:name)
    end
  end

  describe '#roots on Bundled' do
    it 'returns the expanded skill subdirs that actually exist on disk' do
      catalog = Pikuri::Skill::Catalog::Bundled.new(
        search_bases: [File.join(FIXTURE_ROOT, 'valid-tree'), '/nonexistent/path']
      )
      # Only .pikuri/skills exists under valid-tree; the other subdir
      # conventions and the nonexistent base are filtered out.
      assert_equal [File.join(FIXTURE_ROOT, 'valid-tree/.pikuri/skills')],
                   catalog.roots
    end

    it 'returns [] for a Bundled catalog constructed with no search bases' do
      catalog = Pikuri::Skill::Catalog::Bundled.new(search_bases: [])
      assert_equal [], catalog.roots
    end
  end

  describe Pikuri::Skill::Catalog::Bundled do
    describe '#initialize with explicit search_bases' do
      it 'loads every SKILL.md found under .pikuri/skills, sorted by directory name' do
        catalog = described_class.new(search_bases: [File.join(FIXTURE_ROOT, 'valid-tree')])

        names = catalog.list.map(&:name)
        # Dir.children is filesystem-ordered; the scanner sorts so the
        # registered order is deterministic for tests + prompt rendering.
        assert_equal %w[data-viz pdf-tools], names

        pdf = catalog.get('pdf-tools')
        assert_kind_of Pikuri::Skill::Catalog::Skill, pdf
        assert_equal 'pdf-tools', pdf.name
        assert pdf.description.start_with?('Extracts text from PDF')
        assert pdf.body.include?('pdftotext')
        assert_equal File.join(FIXTURE_ROOT, 'valid-tree/.pikuri/skills/pdf-tools/SKILL.md'),
                     pdf.location
      end

      it 'returns nil from #get for unknown names' do
        catalog = described_class.new(search_bases: [File.join(FIXTURE_ROOT, 'valid-tree')])
        assert_nil catalog.get('does-not-exist')
      end

      it 'skips skills with missing description (logs a warning)' do
        log = captured_log do
          catalog = described_class.new(search_bases: [File.join(FIXTURE_ROOT, 'missing-description-tree')])
          assert catalog.empty?
        end
        assert_match(/missing required 'description'/, log)
      end

      it 'skips files without YAML frontmatter (logs a warning)' do
        log = captured_log do
          catalog = described_class.new(search_bases: [File.join(FIXTURE_ROOT, 'no-frontmatter-tree')])
          assert catalog.empty?
        end
        assert_match(/no YAML frontmatter/, log)
      end

      it 'still loads a skill whose frontmatter name disagrees with the dir, with a warning' do
        log = captured_log do
          catalog = described_class.new(search_bases: [File.join(FIXTURE_ROOT, 'name-mismatch-tree')])
          assert_equal ['totally-different'], catalog.list.map(&:name)
        end
        assert_match(/does not match parent directory/, log)
      end

      it 'silently ignores a search base with no skill subdirs' do
        log = captured_log do
          catalog = described_class.new(search_bases: ['/definitely/does/not/exist'])
          assert catalog.empty?
        end
        assert_equal '', log
      end

      it 'merges skills across multiple bases in the given order' do
        catalog = described_class.new(search_bases: [
                                        File.join(FIXTURE_ROOT, 'valid-tree'),
                                        File.join(FIXTURE_ROOT, 'name-mismatch-tree')
                                      ])
        assert_equal %w[data-viz pdf-tools totally-different].sort,
                     catalog.list.map(&:name).sort
      end

      it 'on a name collision keeps the first-listed base and logs a warning for the loser' do
        log = captured_log do
          catalog = described_class.new(search_bases: [
                                          File.join(FIXTURE_ROOT, 'collision-a'),
                                          File.join(FIXTURE_ROOT, 'collision-b')
                                        ])
          winner = catalog.get('pdf-tools')
          assert winner.description.include?('should win'),
                 "expected first-listed base to win, got description: #{winner.description.inspect}"
        end
        assert_match(/shadowed/, log)
        assert_match(/collision-b/, log)
      end

      it 'reads paths: and when-to-use: off the frontmatter' do
        catalog = described_class.new(search_bases: [File.join(FIXTURE_ROOT, 'paths-tree')])

        rdoc = catalog.get('rdoc-writer')
        assert_equal ['**/*.rb', 'lib'], rdoc.paths
        assert rdoc.gated?
        assert_equal 'Use when: about to write or edit a doc comment.', rdoc.when_to_use
      end

      it 'leaves a skill unconditional when it declared no paths:' do
        catalog = described_class.new(search_bases: [File.join(FIXTURE_ROOT, 'valid-tree')])

        pdf = catalog.get('pdf-tools')
        assert_equal [], pdf.paths
        refute pdf.gated?
        assert_nil pdf.when_to_use
      end

      it 'loads a skill whose paths: is unreadable, ungated, with a warning' do
        log = captured_log do
          catalog = described_class.new(search_bases: [File.join(FIXTURE_ROOT, 'paths-tree')])
          refute catalog.get('unreadable-paths').gated?
          # `**` normalizes away, so this one is ungated despite declaring paths:.
          refute catalog.get('star-star').gated?
        end
        assert_match(/'paths:' must be a string or a list of strings/, log)
      end

      it 'scans .pikuri before .claude before .agents within a single base' do
        Dir.mktmpdir do |base|
          %w[.pikuri/skills .claude/skills .agents/skills].each do |sub|
            dir = File.join(base, sub, 'shared')
            FileUtils.mkdir_p(dir)
            File.write(File.join(dir, 'SKILL.md'), <<~MD)
              ---
              name: shared
              description: From #{sub}.
              ---
              body from #{sub}
            MD
          end

          catalog = described_class.new(search_bases: [base])
          winner = catalog.get('shared')
          assert winner.description.include?('.pikuri/skills'),
                 "expected .pikuri to win over .claude/.agents, got: #{winner.description.inspect}"
        end
      end
    end

  end
end
