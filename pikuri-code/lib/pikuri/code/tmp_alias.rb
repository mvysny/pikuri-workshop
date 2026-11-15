# frozen_string_literal: true

require 'delegate'

module Pikuri
  module Code
    # A {Pikuri::Workspace::Filesystem} that reads +/tmp+ as a scratch folder,
    # the file tools' half of {Bash::Sandbox::Bubblewrap} binding that folder at
    # +/tmp+. The model can +curl -o /tmp/x+ in +bash+ and +read+ the same
    # +/tmp/x+, one path for both:
    #
    #   scratch    = Pikuri::Paths.new_temp
    #   filesystem = Pikuri::Workspace::Filesystem.new(project_root:, writable: [scratch])
    #   filesystem = Pikuri::Code::TmpAlias.new(filesystem, tmp: scratch)
    #   filesystem.resolve_for_read('/tmp/x')   # => <scratch>/x
    #   Pikuri::Code::Bash::Sandbox::Bubblewrap.new(filesystem:)   # binds <scratch> at /tmp
    #
    # Wire it only with the sandbox on: without it, +bash+'s +/tmp+ is the
    # host's, and the alias would lie about what +read('/tmp/x')+ opens.
    #
    # == Implementation details
    #
    # A path under a workspace root that itself lives in +/tmp+ (a project in
    # +/tmp/scratch+) is not rewritten. The sandbox binds the scratch folder
    # first and the roots over it, so +bash+ sees the real project at its own
    # name; rewriting it here would make the file tools and +bash+ disagree.
    # The check is lexical, since it only decides *whether* to rewrite: the
    # wrapped filesystem still realpaths and checks containment afterwards.
    class TmpAlias < SimpleDelegator
      # @return [Pathname] the scratch folder +/tmp+ stands for
      attr_reader :tmp

      # @param filesystem [Pikuri::Workspace::Filesystem] must list +tmp+ as writable
      # @param tmp [Pathname, String]
      # @raise [ArgumentError] if +filesystem+ can't write +tmp+, which would
      #   send every +/tmp+ path to an "outside the workspace" error
      def initialize(filesystem, tmp:)
        super(filesystem)
        @tmp = Pathname.new(tmp).realpath
        return if filesystem.writable.include?(@tmp)

        raise ArgumentError, "#{@tmp} is not among the filesystem's writable roots " \
                             "#{filesystem.writable.map(&:to_s)}"
      end

      # @param path [String, Pathname]
      # @return [Pathname]
      # @raise [Pikuri::Workspace::Filesystem::Error] as the wrapped filesystem
      def resolve_for_read(path) = super(rewrite(path))

      # @param path [String, Pathname]
      # @return [Pathname]
      # @raise [Pikuri::Workspace::Filesystem::Error] as the wrapped filesystem
      def resolve_for_write(path) = super(rewrite(path))

      private

      def rewrite(path)
        path = path.to_s
        return path if under_tmp_root?(path)
        return @tmp.to_s if path == '/tmp'
        return File.join(@tmp.to_s, path.delete_prefix('/tmp/')) if path.start_with?('/tmp/')

        path
      end

      def under_tmp_root?(path)
        readable.any? do |root|
          root = root.to_s
          root.start_with?('/tmp/') && (path == root || path.start_with?("#{root}/"))
        end
      end
    end
  end
end
