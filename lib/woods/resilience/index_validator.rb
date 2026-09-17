# frozen_string_literal: true

require 'json'
require 'set'
require 'rubygems/version'
require_relative '../version'
require_relative '../filename_utils'
require_relative '../atomic_file'

require_relative '../generation'
require_relative '../published_index'
require_relative 'graph_invariant_validator'
require_relative 'index_validator/graph_checks'
require_relative '../source_inputs/manifest'

module Woods
  module Resilience
    # Validates the integrity of a codebase index output directory.
    #
    # Checks that:
    # - Each type directory has a valid `_index.json`
    # - All files referenced in the index exist on disk
    # - Content hashes (source_hash) match the actual source_code
    # - No stale unit files exist that aren't listed in the index
    # - Typed graph identities and reverse/file/type memberships agree
    # All checks share one pinned generation; the validator never repairs it.
    #
    # **This class knows nothing about vectors or embedding dimensions.** Six
    # documents used to credit it with detecting dimension mismatches; it never
    # did (#214). That check is {Woods::MCP::DimensionMismatch}, raised by
    # `Tasks.verify_store_dimensions!` before a durable embed run and by
    # {Woods::Storage::Snapshotter::Vector} at MCP boot.
    #
    # Shared by the `woods:validate` rake task and worktree integration checks.
    # Writer-version mismatches are advisory; structural errors still fail.
    #
    # @example
    #   validator = IndexValidator.new(index_dir: "tmp/woods")
    #   report = validator.validate
    #   puts report.errors if !report.valid?
    class IndexValidator # rubocop:disable Metrics/ClassLength
      include Woods::FilenameUtils
      include GraphChecks

      # Report produced by {#validate}.
      #
      # @!attribute [r] valid?
      #   @return [Boolean] true if no errors were found
      # @!attribute [r] warnings
      #   @return [Array<String>] non-fatal issues (e.g., stale files)
      # @!attribute [r] errors
      #   @return [Array<String>] fatal integrity issues
      ValidationReport = Struct.new(:valid?, :warnings, :errors, keyword_init: true)

      # The shared unit-type-directory contract, loadable without Rails:
      # exactly the directories extraction publishes unit types into,
      # derived from `Extractor::EXTRACTORS`. `woods/extractor` loads clean
      # without a booted Rails app (the unit suite proves it), so this stays
      # a plain require. A failure raises to the caller — it must convert
      # the failure into a validation error rather than degrade to a
      # silently empty allowlist, which would disable every structural
      # type-directory check without saying so.
      #
      # @return [Array<String>]
      # @raise [StandardError] when the extraction contract cannot be loaded
      def self.unit_type_directories
        require_relative '../extractor' unless defined?(Woods::Extractor::EXTRACTORS)

        Woods::Extractor::EXTRACTORS.keys.map(&:to_s).freeze
      end

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

        with_validation_payload do
          @graph_index_entries = []
          payload_type_dirs(errors).each do |type_dir|
            validate_type_directory(type_dir, warnings, errors)
          end
          validate_flow_artifacts(errors)
          validate_against_manifest(warnings, errors)
        end

        ValidationReport.new(valid?: errors.empty?, warnings: warnings, errors: errors)
      rescue IOError, SystemCallError, ArgumentError, JSON::ParserError, Woods::PublishedIndex::CorruptPointerError => e
        errors << "Cannot read published index: #{e.class}: #{e.message}"
        ValidationReport.new(valid?: false, warnings: warnings, errors: errors)
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

        manifest = read_validation_manifest(manifest_path, errors)
        return unless manifest

        validate_writer_version(manifest['woods_version'], warnings)
        unresolvable = Hash.new { |hash, key| hash[key] = [] }

        manifest.fetch('counts', {}).each do |type, expected_count|
          validate_manifest_type(payload, type, expected_count, unresolvable, warnings, errors)
        end

        warn_unresolvable_paths(warnings, unresolvable)
        validate_dependency_graph(payload, errors)
        validate_source_inputs(payload, errors)
      end

      # Optional for old generations; malformed new provenance is an artifact
      # integrity error. Source drift itself is advisory and belongs to status.
      def validate_source_inputs(payload, errors)
        path = File.join(payload, SourceInputs::Manifest::FILE_NAME)
        return unless File.exist?(path)

        File.open(path, File::RDONLY | File::NONBLOCK) do |file|
          raise SourceInputs::Manifest::Invalid unless file.stat.file?

          SourceInputs::Manifest.parse(file.read(SourceInputs::Manifest::MAX_BYTES + 1))
        end
      rescue SourceInputs::Manifest::Invalid, SystemCallError, IOError
        errors << 'Invalid source_inputs.json provenance artifact'
      end

      def read_validation_manifest(path, errors)
        manifest = JSON.parse(Woods::AtomicFile.read(path))
        unless manifest.is_a?(Hash)
          errors << 'manifest.json: expected an object'
          return
        end
        unless manifest.fetch('counts', {}).is_a?(Hash)
          errors << 'manifest.json counts: expected an object'
          return
        end

        manifest
      end

      # The version records the last publisher, not the producer of every
      # retained unit. Missing provenance is normal for older indexes.
      def validate_writer_version(value, warnings)
        return if value.nil?

        unless value.is_a?(String) && !value.strip.empty?
          warnings << 'Invalid manifest woods_version; writer provenance is unknown. Run a full woods:extract.'
          return
        end

        writer = Gem::Version.new(value)
        reader = Gem::Version.new(Woods::VERSION)
        return if writer.segments.first == reader.segments.first

        warnings << "Index last published by Woods #{value}; reader is Woods #{Woods::VERSION}. " \
                    'Major versions differ. Run a full woods:extract before relying on compatibility.'
      rescue ArgumentError
        warnings << 'Invalid manifest woods_version; writer provenance is unknown. Run a full woods:extract.'
      end

      # Split unresolvable app-tree paths from gem-owned paths so each warning
      # can distinguish a different filesystem environment from a changed bundle.
      #
      # @param warnings [Array<String>]
      # @param unresolvable [Hash{String => Array<Array(String, Boolean)>}]
      def warn_unresolvable_paths(warnings, unresolvable)
        unresolvable.each do |type, entries|
          inside, outside = entries.partition { |_identifier, outside_root| !outside_root }
          warn_unresolvable_app_paths(warnings, type, inside.map(&:first))
          warn_unresolvable_gem_paths(warnings, type, outside.map(&:first))
        end
      end

      # App-tree paths that do not exist under the app root: the index was
      # extracted from a different tree, and re-extracting here fixes it.
      def warn_unresolvable_app_paths(warnings, type, identifiers)
        return if identifiers.empty?

        warnings << "#{type}: #{identifiers.size} unit(s) whose file_path resolves nowhere " \
                    "(e.g. #{identifiers.first(3).join(', ')}). Extracted in a different environment? " \
                    'Re-run extraction.'
      end

      # Absolute paths outside the app root belong to a gem — an engine model,
      # a framework source — and resolve only where that gem is installed at
      # the extracting path. A changed bundle requires fresh extraction; a
      # reader on another filesystem instead needs the original gem paths.
      def warn_unresolvable_gem_paths(warnings, type, identifiers)
        return if identifiers.empty?

        warnings << "#{type}: #{identifiers.size} unit(s) whose file_path lies outside the app root " \
                    "and is absent here (e.g. #{identifiers.first(3).join(', ')}). Gem-owned units " \
                    '(engine models, framework sources) resolve only where that gem is installed at ' \
                    'the extracting path. After a bundle update, run woods:extract in a fresh process ' \
                    'with the updated bundle, then woods:validate.'
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
      # @param unresolvable [Hash{String => Array<Array(String, Boolean)>}]
      #   `[identifier, outside_app_root]` pairs whose file_path resolves
      #   nowhere, keyed by type
      # @param errors [Array<String>]
      def validate_unit_file(file, type, unresolvable, errors)
        data = JSON.parse(Woods::AtomicFile.read(file))
        unless data.is_a?(Hash)
          errors << "#{file}: expected a unit object"
          return
        end
        errors << "#{file}: missing identifier" unless data['identifier']
        errors << "#{file}: missing source_code" unless data['source_code']
        file_path = data['file_path']
        return if path_resolvable?(file_path)

        unresolvable[type] << [data['identifier'] || File.basename(file), outside_app_root?(file_path)]
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

      # True for an absolute path that is not under the app root. Extraction
      # relativizes every path under Rails.root, so an absolute path in the
      # index is one that was never in the app tree: a gem's.
      def outside_app_root?(file_path)
        return false unless file_path.to_s.start_with?('/')

        !file_path.start_with?("#{@app_root.to_s.chomp('/')}/")
      end

      def validate_dependency_graph(payload, errors)
        graph_path = File.join(payload, 'dependency_graph.json')
        unless File.exist?(graph_path)
          errors << 'Missing dependency_graph.json'
          return
        end

        graph = JSON.parse(Woods::AtomicFile.read(graph_path))
        errors.concat(GraphInvariantValidator.new(graph: graph, index_entries: @graph_index_entries).validate)
      rescue JSON::ParserError
        errors << 'dependency_graph.json: invalid JSON'
      end

      def payload_dir
        @validation_payload || Woods::Generation.new(output_dir: @index_dir).payload_dir.to_s
      end

      private

      # Resolve the published generation's payload and list its unit-type
      # directories (e.g. models/, controllers/). An index that publishes
      # per-generation payloads keeps `payloads/`, `dumps/` and `tasks/`
      # beside them at the root, none of which are type directories.
      #
      # The list is bounded by a type-directory allowlist (G-2): a directory
      # the allowlist does not claim — `flows/` above all — is not a unit-type
      # directory and never reaches {#validate_type_directory}, which demands
      # an `_index.json` no auxiliary artifact can satisfy. Before the
      # allowlist, every directory under the payload was treated as a unit
      # type, so any index published with flow precomputation enabled failed
      # validation with "Missing _index.json in flows/".
      #
      # @param errors [Array<String>] accumulated errors; appended to if the
      #   payload directory named by the published generation isn't on disk,
      #   or the shared type-directory allowlist cannot be derived (a
      #   silently empty allowlist would disable every structural
      #   type-directory check without saying so)
      # @return [Array<String>] absolute paths to type directories
      def payload_type_dirs(errors)
        payload = payload_dir
        allowlist = derive_type_directory_allowlist(errors)
        return [] if allowlist.nil?

        Dir.children(payload).filter_map do |name|
          full_path = File.join(payload, name)
          next unless File.directory?(full_path)
          next unless allowlist.include?(name)

          full_path
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

      # The allowlist, or nil — with a validation error recorded — when the
      # shared contract cannot be derived. A silently empty allowlist would
      # disable every structural type-directory check without saying so.
      #
      # @param errors [Array<String>] accumulated errors
      # @return [Array<String>, nil]
      def derive_type_directory_allowlist(errors)
        type_directory_allowlist
      rescue StandardError, ScriptError => e
        # ScriptError too: a require failure surfaces as LoadError, which
        # `rescue StandardError` does not catch.
        errors << 'Could not derive the unit-type directory allowlist ' \
                  "(#{e.class}: #{e.message}); structural checks disabled"
        nil
      end

      # @param name [String] directory basename under the payload
      # @return [Boolean] true when extraction publishes unit types here
      def unit_type_directory?(name)
        type_directory_allowlist.include?(name)
      end

      # The shared allowlist: exactly the directories extraction publishes
      # unit types into, derived from `Extractor::EXTRACTORS` so the two
      # cannot drift. Required lazily — {IndexValidator} deliberately loads
      # without Rails, and `woods/extractor` also loads clean. A derivation
      # failure RAISES: {#payload_type_dirs} converts it to a validation
      # error rather than degrading to a silently empty allowlist.
      #
      # The explicit Woods static-map provenance additionally admits the
      # GemMapper's own type families; arbitrary directories stay excluded.
      # `flows/` is deliberately absent: it holds `flow_index.json` and
      # per-flow documents, which {#validate_flow_artifacts} owns.
      #
      # @return [Array<String>]
      def type_directory_allowlist
        directories = self.class.unit_type_directories
        return directories unless static_source_map?

        require_relative '../gem_mapper'
        directories | Woods::GemMapper::TYPE_DIRECTORIES.values
      end

      # Validate the flows/ artifact family (G-2): `flow_index.json` parses,
      # and every entry points at a flow document that exists and parses.
      #
      # A payload from a run that never enabled flow precomputation has no
      # flows directory at all, and an empty one holds nothing — both are
      # absences. A POPULATED family with no index is corruption: the index
      # is what defines which documents are live, so documents without it
      # are unaccounted artifacts and are reported, not accepted.
      #
      # @param errors [Array<String>] accumulated errors
      def validate_flow_artifacts(errors)
        flows_dir = File.join(payload_dir, 'flows')
        return unless File.directory?(flows_dir)
        return if Dir.empty?(flows_dir)

        index_path = File.join(flows_dir, 'flow_index.json')
        unless File.exist?(index_path)
          errors << 'flows/ is populated but flow_index.json is missing'
          return
        end

        index = parse_artifact(index_path, 'flows/flow_index.json', errors)
        return unless index.is_a?(Hash)

        index.each_value do |relative|
          filename = File.basename(relative.to_s)
          document = File.join(flows_dir, filename)
          unless File.exist?(document)
            errors << "flow_index.json references missing document: flows/#{filename}"
            next
          end

          parse_artifact(document, "flows/#{filename}", errors)
        end
      end

      # @param path [String] artifact path
      # @param label [String] how to name the artifact in an error
      # @param errors [Array<String>] accumulated errors
      # @return [Object, nil] parsed JSON, or nil when it does not parse
      def parse_artifact(path, label, errors)
        JSON.parse(Woods::AtomicFile.read(path))
      rescue JSON::ParserError => e
        errors << "#{label}: invalid JSON - #{e.message}"
        nil
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

        indexed_identifiers = Set.new
        validation_index_entries(index_path, errors).each do |entry|
          identifier = entry['identifier']
          indexed_identifiers << identifier
          data = validate_index_entry(type_dir, type_name, identifier, errors)
          collect_graph_index_entry(type_dir, entry, data, errors)
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
        unless data.is_a?(Hash)
          errors << "#{unit_file}: expected a unit object"
          return
        end
        check_content_hash(data, identifier, errors)
        data
      end

      def check_content_hash(data, identifier, errors)
        source_code = data['source_code']
        stored_hash = data['source_hash']
        return unless source_code && stored_hash

        unless source_code.is_a?(String) && stored_hash.is_a?(String)
          errors << "#{identifier}: source_code and source_hash must be strings"
          return
        end
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
