# frozen_string_literal: true

require 'json'
require 'digest'

module CodebaseIndex
  module Resilience
    # Validates the integrity of a codebase index output directory.
    #
    # Checks that:
    # - Each type directory has a valid `_index.json`
    # - All files referenced in the index exist on disk
    # - Content hashes (source_hash) match the actual source_code
    # - No stale unit files exist that aren't listed in the index
    #
    # @example
    #   validator = IndexValidator.new(index_dir: "tmp/codebase_index")
    #   report = validator.validate
    #   puts report.errors if !report.valid?
    class IndexValidator
      # Report produced by {#validate}.
      #
      # @!attribute [r] valid?
      #   @return [Boolean] true if no errors were found
      # @!attribute [r] warnings
      #   @return [Array<String>] non-fatal issues (e.g., stale files)
      # @!attribute [r] errors
      #   @return [Array<String>] fatal integrity issues
      ValidationReport = Struct.new(:valid?, :warnings, :errors, keyword_init: true)

      # @param index_dir [String] Path to the codebase index output directory
      def initialize(index_dir:)
        @index_dir = index_dir
      end

      # Validate the index directory and return a report.
      #
      # @return [ValidationReport] the validation results
      def validate
        warnings = []
        errors = []

        unless Dir.exist?(@index_dir)
          errors << "Index directory does not exist: #{@index_dir}"
          return ValidationReport.new(valid?: false, warnings: warnings, errors: errors)
        end

        type_dirs = Dir.children(@index_dir).filter_map do |name|
          full_path = File.join(@index_dir, name)
          full_path if File.directory?(full_path)
        end

        type_dirs.each do |type_dir|
          validate_type_directory(type_dir, warnings, errors)
        end

        ValidationReport.new(valid?: errors.empty?, warnings: warnings, errors: errors)
      end

      private

      # Validate a single type directory (e.g., models/, controllers/).
      #
      # @param type_dir [String] Absolute path to the type directory
      # @param warnings [Array<String>] Accumulated warnings
      # @param errors [Array<String>] Accumulated errors
      def validate_type_directory(type_dir, warnings, errors)
        type_name = File.basename(type_dir)
        index_path = File.join(type_dir, '_index.json')

        unless File.exist?(index_path)
          errors << "Missing _index.json in #{type_name}/"
          return
        end

        index_entries = JSON.parse(File.read(index_path))
        indexed_identifiers = Set.new

        index_entries.each do |entry|
          identifier = entry['identifier']
          indexed_identifiers << identifier
          validate_index_entry(type_dir, type_name, identifier, errors)
        end

        check_stale_files(type_dir, type_name, indexed_identifiers, warnings)
      end

      # Validate that a single index entry has a corresponding unit file with correct hash.
      #
      # @param type_dir [String] Path to the type directory
      # @param type_name [String] Name of the type (for error messages)
      # @param identifier [String] The unit identifier from the index
      # @param errors [Array<String>] Accumulated errors
      def validate_index_entry(type_dir, type_name, identifier, errors)
        unit_file = find_unit_file(type_dir, identifier)

        unless unit_file
          errors << "Missing unit file for #{identifier} in #{type_name}/"
          return
        end

        validate_content_hash(unit_file, identifier, errors)
      end

      # Find the JSON file for a given identifier in a type directory.
      #
      # @param type_dir [String] Path to the type directory
      # @param identifier [String] The unit identifier
      # @return [String, nil] Path to the unit file, or nil if not found
      def find_unit_file(type_dir, identifier)
        # Try exact match first, then safe filename conversion (mirroring Extractor logic)
        candidates = [
          File.join(type_dir, "#{identifier}.json"),
          File.join(type_dir, safe_filename(identifier))
        ]

        candidates.find { |path| File.exist?(path) }
      end

      # Validate that the source_hash in a unit file matches the actual source_code.
      #
      # @param unit_file [String] Path to the unit JSON file
      # @param identifier [String] The unit identifier (for error messages)
      # @param errors [Array<String>] Accumulated errors
      def validate_content_hash(unit_file, identifier, errors)
        data = JSON.parse(File.read(unit_file))
        source_code = data['source_code']
        stored_hash = data['source_hash']

        return unless source_code && stored_hash

        expected_hash = Digest::SHA256.hexdigest(source_code)
        return if stored_hash == expected_hash

        errors << "Content hash mismatch for #{identifier}: expected #{expected_hash[0..7]}..., " \
                  "got #{stored_hash[0..7]}..."
      end

      # Check for unit files that exist on disk but aren't referenced in the index.
      #
      # @param type_dir [String] Path to the type directory
      # @param type_name [String] Name of the type (for warning messages)
      # @param indexed_identifiers [Set<String>] Identifiers listed in the index
      # @param warnings [Array<String>] Accumulated warnings
      def check_stale_files(type_dir, type_name, indexed_identifiers, warnings)
        Dir[File.join(type_dir, '*.json')].each do |file|
          basename = File.basename(file)
          next if basename == '_index.json'

          identifier = basename.sub(/\.json\z/, '')
          next if indexed_identifiers.include?(identifier)

          warnings << "Stale file not in index: #{type_name}/#{basename}"
        end
      end

      # Convert an identifier to a safe filename (mirrors Extractor#safe_filename exactly).
      #
      # @param identifier [String] The unit identifier (e.g., "Admin::UsersController")
      # @return [String] A filesystem-safe filename (e.g., "Admin__UsersController.json")
      def safe_filename(identifier)
        "#{identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}.json"
      end
    end
  end
end
