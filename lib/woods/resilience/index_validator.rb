# frozen_string_literal: true

require 'json'
require 'set'
require_relative '../filename_utils'
require_relative '../atomic_file'

require_relative '../generation'

module Woods
  module Resilience
    # Validates the integrity of a codebase index output directory.
    #
    # Checks that:
    # - Each type directory has a valid `_index.json`
    # - All files referenced in the index exist on disk
    # - Content hashes (source_hash) match the actual source_code
    # - No stale unit files exist that aren't listed in the index
    #
    # **This class knows nothing about vectors or embedding dimensions.** Six
    # documents used to credit it with detecting dimension mismatches; it never
    # did (#214). That check is {Woods::MCP::DimensionMismatch}, raised by
    # `Tasks.verify_store_dimensions!` before a durable embed run and by
    # {Woods::Storage::Snapshotter::Vector} at MCP boot.
    #
    # Consumed by `spec/integration/multi_worktree_spec.rb` as a per-worktree
    # integrity oracle. The `woods:validate` rake task performs an overlapping
    # check inline rather than calling this — deliberate duplication left alone
    # for now, since the task's output format is user-facing.
    #
    # @example
    #   validator = IndexValidator.new(index_dir: "tmp/woods")
    #   report = validator.validate
    #   puts report.errors if !report.valid?
    class IndexValidator # rubocop:disable Metrics/ClassLength
      include Woods::FilenameUtils

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
      # @param app_root [String, nil] the host application root; when given,
      #   a unit whose +file_path+ resolves neither as written nor under it
      #   is reported (the #169 staleness class: extracted elsewhere, or the
      #   source has since vanished)
      def initialize(index_dir:, app_root: nil)
        @index_dir = index_dir
        @app_root = app_root
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

        payload_type_dirs(errors).each do |type_dir|
          validate_type_directory(type_dir, warnings, errors)
        end
        validate_against_manifest(warnings, errors)

        ValidationReport.new(valid?: errors.empty?, warnings: warnings, errors: errors)
      end

      # The checks `woods:validate` used to carry inline: manifest counts
      # against the files on disk, every unit file parseable with an
      # identifier and source, file paths that resolve, and a parseable
      # dependency graph. Skipped when there is no manifest, so a bare
      # type-directory tree (older fixtures, partial writes) still validates
      # on the structural checks alone.
      #
      # @param warnings [Array<String>]
      # @param errors [Array<String>]
      def validate_against_manifest(warnings, errors)
        payload = payload_dir
        manifest_path = File.join(payload, 'manifest.json')
        return unless File.exist?(manifest_path)

        manifest = JSON.parse(Woods::AtomicFile.read(manifest_path))
        unresolvable = Hash.new { |hash, key| hash[key] = [] }

        (manifest['counts'] || {}).each do |type, expected_count|
          validate_manifest_type(payload, type, expected_count, unresolvable, warnings, errors)
        end

        unresolvable.each do |type, identifiers|
          sample = identifiers.first(3).join(', ')
          warnings << "#{type}: #{identifiers.size} unit(s) whose file_path resolves nowhere " \
                      "(e.g. #{sample}). Extracted in a different environment? Re-run extraction."
        end

        validate_dependency_graph(payload, errors)
      end

      # rubocop:disable-next Metrics/ParameterLists
      def validate_manifest_type(payload, type, expected_count, unresolvable, warnings, errors)
        type_dir = File.join(payload, type)
        unless File.directory?(type_dir)
          errors << "Missing directory: #{type}"
          return
        end

        unit_files = Dir[File.join(type_dir, '*.json')].reject { |f| f.end_with?('_index.json') }
        warnings << "#{type}: expected #{expected_count}, found #{unit_files.size}" if unit_files.size != expected_count
        unit_files.each { |file| validate_unit_file(file, type, unresolvable, errors) }
      end

      # @param file [String] unit JSON path
      # @param type [String] type directory name
      # @param unresolvable [Hash{String => Array<String>}] identifiers whose
      #   file_path resolves nowhere, keyed by type
      # @param errors [Array<String>]
      def validate_unit_file(file, type, unresolvable, errors)
        data = JSON.parse(Woods::AtomicFile.read(file))
        errors << "#{file}: missing identifier" unless data['identifier']
        errors << "#{file}: missing source_code" unless data['source_code']
        return if path_resolvable?(data['file_path'])

        unresolvable[type] << (data['identifier'] || File.basename(file))
      rescue JSON::ParserError => e
        errors << "#{file}: invalid JSON - #{e.message}"
      end

      # True when the check is off (no +app_root+), the unit has no path, or
      # the path exists as written or under the app root.
      def path_resolvable?(file_path)
        return true if @app_root.nil? || file_path.nil?

        File.exist?(file_path) || File.exist?(File.join(@app_root, file_path))
      rescue StandardError
        false
      end

      def validate_dependency_graph(payload, errors)
        graph_path = File.join(payload, 'dependency_graph.json')
        unless File.exist?(graph_path)
          errors << 'Missing dependency_graph.json'
          return
        end

        JSON.parse(Woods::AtomicFile.read(graph_path))
      rescue JSON::ParserError
        errors << 'dependency_graph.json: invalid JSON'
      end

      def payload_dir
        Woods::Generation.new(output_dir: @index_dir).payload_dir.to_s
      end

      private

      # Resolve the published generation's payload and list its type
      # directories (e.g. models/, controllers/) — an index that publishes
      # per-generation payloads keeps `payloads/`, `dumps/` and `tasks/`
      # beside them at the root, none of which are type directories.
      #
      # @param errors [Array<String>] accumulated errors; appended to if the
      #   payload directory named by the published generation isn't on disk
      # @return [Array<String>] absolute paths to type directories
      def payload_type_dirs(errors)
        payload = payload_dir
        Dir.children(payload).filter_map do |name|
          full_path = File.join(payload, name)
          full_path if File.directory?(full_path)
        end
      rescue Errno::ENOENT
        # A published `generation.json` pointing at a payload directory
        # that isn't actually on disk (e.g. a generation bump raced a
        # promote, or the payload was manually removed) is an index
        # integrity problem this validator exists to report — not a
        # crash for its caller to catch.
        errors << "Payload directory does not exist: #{payload}"
        []
      end

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

        index_entries = JSON.parse(Woods::AtomicFile.read(index_path))
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
        # Try collision-safe first (current format), then legacy safe_filename, then exact match
        candidates = [
          File.join(type_dir, collision_safe_filename(identifier)),
          File.join(type_dir, safe_filename(identifier)),
          File.join(type_dir, "#{identifier}.json")
        ]

        candidates.find { |path| File.exist?(path) }
      end

      # Validate that the source_hash in a unit file matches the actual source_code.
      #
      # @param unit_file [String] Path to the unit JSON file
      # @param identifier [String] The unit identifier (for error messages)
      # @param errors [Array<String>] Accumulated errors
      def validate_content_hash(unit_file, identifier, errors)
        data = JSON.parse(Woods::AtomicFile.read(unit_file))
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
        # Build a set of expected filenames from indexed identifiers (both current and legacy formats)
        expected_filenames = Set.new
        indexed_identifiers.each do |id|
          expected_filenames << collision_safe_filename(id)
          expected_filenames << safe_filename(id)
          expected_filenames << "#{id}.json"
        end

        Dir[File.join(type_dir, '*.json')].each do |file|
          basename = File.basename(file)
          next if basename == '_index.json'
          next if expected_filenames.include?(basename)

          warnings << "Stale file not in index: #{type_name}/#{basename}"
        end
      end
    end
  end
end
