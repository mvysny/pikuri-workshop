# frozen_string_literal: true

require 'yaml'

module Pikuri
  module Bundle
    # Splits a bundle file into its YAML frontmatter and its body.
    #
    #   Frontmatter.split(File.read(path), path: path)
    #   # => [{"description" => "Weekly work log"}, "# Weekly work log\n…"]
    #
    # A file with no +---+ block splits as +[nil, body]+ — the caller decides
    # whether that is a skipped file or an ordinary one, and the two bundle
    # surfaces answer differently. Malformed YAML degrades to +[{}, body]+
    # with a warning rather than raising: a frontmatter typo should cost the
    # keys, not the file.
    module Frontmatter
      LOGGER = Pikuri.logger_for('Bundles')
      private_constant :LOGGER

      module_function

      # @param content [String] the whole file
      # @param path [String] used in warnings only
      # @return [Array(Hash{String=>Object}, String)] parsed keys and body
      # @return [Array(nil, String)] when no frontmatter block is present
      def split(content, path:)
        normalized = content.gsub(/\r\n?/, "\n")
        return [nil, normalized] unless normalized.start_with?("---\n")

        end_marker = normalized.index("\n---", 4)
        return [nil, normalized] unless end_marker

        body = normalized[(end_marker + 4)..].to_s.sub(/\A\n/, '')
        [parse(normalized[4...end_marker], path: path), body]
      end

      # @param yaml_str [String]
      # @param path [String]
      # @return [Hash{String=>Object}] +{}+ on a parse error or a non-Hash document
      def parse(yaml_str, path:)
        parsed =
          begin
            YAML.safe_load(yaml_str) || {}
          rescue Psych::SyntaxError => e
            LOGGER.warn("#{path}: frontmatter YAML parse error: #{e.message}")
            {}
          end
        parsed.is_a?(Hash) ? parsed : {}
      end
      private_class_method :parse
    end
  end
end
