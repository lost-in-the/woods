# frozen_string_literal: true

require_relative 'changelog'

module Woods
  module Release
    # Optional, flat entry files consumed only by release:prepare. Validate the
    # entire input set before the preparer writes or removes anything.
    module Fragments
      class InvalidEntry < Error; end

      HEADINGS = ['Added', 'Build', 'Changed', 'Dependencies', 'Documentation', 'Fixed',
                  'Performance', 'Security', 'Testing', 'Upgrade Notes'].to_h do |heading|
        [heading.downcase.tr(' ', '-'), heading]
      end.freeze
      FILENAME = /\A(?<type>[a-z-]+)_[a-z0-9][a-z0-9_-]*\.md\z/

      HEADING = /(?:^ {0,3}\#{1,6}(?:\s|$)|^ {0,3}\S[^\n]*\n {0,3}(?:=+|-+)[ \t]*\r?$)/

      module_function

      # @return [Hash<String, Array(String, String)>] relative path to heading/body
      def read(root)
        directory = File.join(root, 'changelog')
        return {} unless File.exist?(directory) || File.symlink?(directory)

        unless File.lstat(directory).directory?
          raise InvalidEntry, 'changelog must be a real directory, not a symlink or file'
        end

        flat_entry_names(directory).grep(/\.md\z/).to_h do |name|
          path = "changelog/#{name}"
          [path, read_entry(root, path, name)]
        end
      end

      # @return [Array<String>] direct names after refusing unsupported nested inputs
      def flat_entry_names(directory)
        Dir.children(directory).sort.each do |name|
          entry = File.lstat(File.join(directory, name))
          next unless entry.directory? || entry.symlink?

          raise InvalidEntry,
                "changelog/#{name}: changelog entries must be flat; directories and symlinks are refused"
        end
      end

      def read_entry(root, path, name)
        match = FILENAME.match(name)
        heading = match && HEADINGS[match[:type]]
        raise InvalidEntry, "#{path}: expected <type>_<slug>.md; types: #{HEADINGS.keys.join(', ')}" unless heading
        unless File.lstat(File.join(root, path)).file?
          raise InvalidEntry, "#{path}: entry must be a regular file, not a symlink or directory"
        end

        body = File.read(File.join(root, path), encoding: Encoding::UTF_8)
        validate_body!(body, path)
        [heading, body.strip]
      end

      def validate_body!(body, path)
        unless body.valid_encoding? && !body.strip.empty? && !body.match?(HEADING)
          raise InvalidEntry, "#{path}: entry must be nonempty UTF-8 Markdown without headings"
        end
        return if body.lstrip.match?(/\A-[ \t]+\S/)

        raise InvalidEntry, "#{path}: entry must begin with a '- ' list item"
      end
    end
  end
end
