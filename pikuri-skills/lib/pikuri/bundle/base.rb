# frozen_string_literal: true

module Pikuri
  # Discovery vocabulary shared by pikuri's *bundles* — Markdown files with
  # YAML frontmatter, found by scanning a list of search bases rather than by
  # being registered one at a time.
  module Bundle
    # One search base: a directory to scan, plus whether the bytes under it
    # are the user's own.
    #
    #   Bundle::Base.new(dir: project_root, trusted: repo_sources_are_mine)
    #   Bundle::Base.new(dir: Dir.home)              # trusted: false
    #
    # +trusted+ asks what +Pikuri::Workspace::Filesystem#trusted?+ asks for
    # the file tools — user-authored bytes, or bytes that arrived with a
    # clone? — but about *this root alone*. That is why it is a value the
    # host passes rather than a reach into the workspace: the two objects
    # reach different bytes, so a workspace whose +readable:+ carries
    # +~/.m2/repository+ is honestly untrusted while the project's own
    # +.pikuri/skills+ beside it is honestly the user's. Like +private:+, it
    # is unverifiable, so silence buys +false+.
    #
    # A scanner grades its own untrusted trifecta leg by unioning this flag
    # over the bundles it actually stored, so an untrusted base costs nothing
    # while it holds nothing.
    Base = Data.define(:dir, :trusted) do
      # @param dir [String, Pathname] directory to scan for bundle subdirs
      # @param trusted [Boolean] every byte under +dir+ is user-authored
      # @return [Base]
      def initialize(dir:, trusted: false) = super
    end
  end
end
