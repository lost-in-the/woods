# frozen_string_literal: true

module Woods
  # Which files are client-side GraphQL operation documents.
  #
  # One predicate shared by the extractor's discovery, the dispatcher rule and
  # the reload policy, so a full run, an incremental run and the watch daemon
  # agree per path. Loading this file does not boot Rails.
  module GraphQLDocumentPaths
    # Root-relative globs scanned when +config.graphql_document_paths+ is unset.
    DEFAULT = ['app/javascript/**/*.{graphql,gql}', 'app/frontend/**/*.{graphql,gql}'].freeze

    # Installed packages ship documents of their own; they are not the app's.
    EXCLUDED_SEGMENT = '/node_modules/'

    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    module_function

    # @return [Array<String>] the configured globs, or {DEFAULT}
    def globs
      configuration = Woods.configuration if Woods.respond_to?(:configuration)
      configuration ? configuration.graphql_document_paths : DEFAULT
    end

    # @param glob [Object] a candidate +graphql_document_paths+ entry
    # @return [Boolean] a non-empty, relative glob without `..`
    def valid_glob?(glob)
      glob.is_a?(String) && !glob.empty? && !glob.start_with?('/') && !glob.split('/').include?('..')
    end

    # @param relative_path [String] Rails.root-relative path
    # @return [Boolean]
    def match?(relative_path)
      return false if relative_path.include?(EXCLUDED_SEGMENT)

      globs.any? { |glob| File.fnmatch?(glob, relative_path, GLOB_FLAGS) }
    end

    # @param root [String] application root
    # @return [Array<String>] matching root-relative paths, sorted
    def under(root)
      matches = Dir.glob(globs, base: root).uniq
      matches.select { |relative| match?(relative) && File.file?(File.join(root, relative)) }.sort
    end
  end
end
