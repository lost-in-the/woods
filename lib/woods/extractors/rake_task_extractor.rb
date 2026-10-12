# frozen_string_literal: true

require_relative '../source_file'
require_relative '../source_inputs/consumer_errors'

require_relative 'config_source_guard'
require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'rake_task_paths'
require_relative 'rake_source_parser'
require_relative 'rake_runtime_index'
require_relative 'rake_task_catalog'

module Woods
  module Extractors
    # RakeTaskExtractor indexes rake tasks and the Ruby that supports them.
    #
    # It reads the files named by +config.rake_task_paths+ (by default
    # `lib/tasks/**/*.rake`, `rake/**/*.rake` and the `Rakefile`) with Prism
    # and never runs them. One unit per task: a task defined or enhanced in
    # several files is one unit carrying every site. Ruby files under a
    # configured directory become `rake_support` units, so a task's calls
    # into its helpers are edges.
    #
    # The loaded Rake application resolves what a file computes (a task name
    # built in a loop); everything a file states literally comes from the
    # file. See {RakeTaskCatalog}.
    #
    # Rake files and their helpers are where a deploy password or an API
    # token tends to be written down, so the raw text is parsed and the text
    # published as `source_code` has passed through {ConfigSourceGuard.redact}.
    #
    # @example
    #   extractor = RakeTaskExtractor.new
    #   units = extractor.extract_all
    #   cleanup = units.find { |u| u.identifier == "cleanup:stale_orders" }
    #   cleanup.metadata[:description] # => "Remove orders older than 30 days"
    #
    class RakeTaskExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Namespaces to exclude from extraction (this gem's own tasks)
      EXCLUDED_NAMESPACES = %w[woods].freeze

      # Definition kinds Rake keeps outside namespaces.
      UNSCOPED_KINDS = RakeSourceParser::UNSCOPED_KINDS

      SUPPORT_KIND = 'rake_support'

      def initialize
        @root = Rails.root
        @paths = RakeTaskPaths.configured
      end

      # Extract every rake task and support file under the configured paths.
      #
      # @return [Array<ExtractedUnit>] task units, then support units
      def extract_all
        tasks = catalog.names.filter_map { |name| build_unit(name) }
        (tasks + support_paths.filter_map { |relative| build_support_unit(relative) }).uniq(&:identifier)
      end

      # Extract the units one file contributes to: every task it defines or
      # enhances (each built from all of that task's files), or the support
      # unit of a Ruby file.
      #
      # @param file_path [String] Path to a rake file or a support file
      # @return [Array<ExtractedUnit>] List of rake task units
      def extract_rake_file(file_path)
        file = file_path.to_s
        relative = relative_path(file)
        return [build_support_unit(relative)].compact if support_paths.include?(relative)
        return [] unless task_source?(file, relative) && rake_file_data(file)

        names = catalog.names_in(file)
        Rails.logger.debug("Woods: no rake tasks parsed from #{file_path}") if names.empty?
        names.filter_map { |name| build_unit(name) }
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract rake tasks from #{file_path}: #{e.message}")
        []
      end

      private

      def task_source?(file, relative)
        file.end_with?('.rake') || RakeTaskPaths.task_file?(relative, @paths)
      end

      def rake_files
        @rake_files ||= RakeTaskPaths.task_files(@root, @paths)
      end

      # Support files no other extractor owns, root-relative and sorted. A
      # configured directory inside `lib/` holds Ruby the lib extractor
      # already indexes.
      def support_paths
        @support_paths ||= RakeTaskPaths.support_files(@root, @paths)
                                        .map { |file| relative_path(file) }
                                        .reject { |relative| claimed_elsewhere?(relative) }
      end

      def claimed_elsewhere?(relative)
        return false unless defined?(Woods::Extractor::EXTRACTORS) && defined?(Woods::PathDispatcher)

        !Woods::PathDispatcher.claiming_key_for(relative).nil?
      end

      # One read and one parse per file per extractor instance. Both
      # {#extract_rake_file} and the catalog need every file; the bytes cannot
      # change mid-run, so the first read answers both.
      #
      # A file that fails to read is memoized as nil and contributes nothing.
      #
      # @param file [String] Absolute path
      # @return [Hash{Symbol => Object}, nil] `{ source:, parsed: }`
      def rake_file_data(file)
        @rake_file_data ||= {}
        return @rake_file_data[file] if @rake_file_data.key?(file)

        @rake_file_data[file] = begin
          source = SourceFile.read(file)
          { source: source, parsed: parse_tasks(source) }
        rescue StandardError, SystemStackError => e
          # Pathologically nested source overflows the stack inside the walk.
          SourceInputs::ConsumerErrors.log(self, "Failed to scan rake tasks in #{file}: #{e.message}")
          nil
        end
      end

      # The file text as published, credentials redacted. Parsing reads the raw text.
      #
      # @param data [Hash] {#rake_file_data} entry
      # @return [String]
      def published_source(data)
        data[:published] ||= ConfigSourceGuard.redact(data[:source])
      end

      # @param source [String] Ruby source
      # @return [RakeSourceParser::Result]
      def parse_tasks(source)
        RakeSourceParser.parse(source)
      end

      def catalog
        @catalog ||= RakeTaskCatalog.new(
          task_files: parsed_files(rake_files),
          support_files: parsed_files(support_paths.map { |relative| @root.join(relative).to_s })
                         .transform_keys { |file| relative_path(file) },
          runtime: RakeRuntimeIndex.current
        )
      end

      def parsed_files(files)
        files.each_with_object({}) do |file, parsed|
          data = rake_file_data(file)
          parsed[file] = data[:parsed] if data
        end
      end

      # Check if a task name falls under an excluded namespace.
      #
      # @param full_name [String] e.g. "woods:extract"
      # @return [Boolean]
      def excluded_namespace?(full_name)
        EXCLUDED_NAMESPACES.any? { |ns| full_name.start_with?("#{ns}:") }
      end

      # Build the unit for one task from every record of it.
      #
      # @param name [String] full task name
      # @return [ExtractedUnit, nil]
      def build_unit(name)
        records = catalog.records_for(name)
        return nil if records.empty? || excluded_namespace?(name)

        primary = records.find { |record| !record[:enhancement] } || records.first
        unit = ExtractedUnit.new(type: :rake_task, identifier: name, file_path: primary[:file])
        unit.namespace = split_name(name, primary).first
        unit.source_code = records.map { |record| record[:file] }.uniq
                                  .map { |file| build_source_annotation(name, records, file) }.join("\n\n")
        unit.metadata = build_metadata(name, primary, records)
        unit.dependencies = records.flat_map { |record| extract_dependencies(record) }
                                   .then { |dependencies| consolidate_dependencies(dependencies) }
                                   .reject { |dependency| dependency[:target] == name }
        unit
      end

      # @return [Array(String, String), Array(nil, String)] namespace and short name
      def split_name(name, primary)
        return [nil, name] if UNSCOPED_KINDS.include?(primary[:kind])

        namespace, _, short = name.rpartition(':')
        [namespace.empty? ? nil : namespace, short]
      end

      def relative_path(file)
        file.to_s.sub("#{@root}/", '')
      end

      # Build annotated source code for one file of the unit.
      #
      # @return [String]
      def build_source_annotation(name, records, file)
        description = records.select { |record| record[:file] == file }.filter_map { |record| record[:description] }.first
        header = "# Rake task: #{name}"
        header += "\n# #{description}" if description
        "#{header}\n#{published_source(rake_file_data(file))}"
      end

      # Build metadata hash for the unit.
      #
      # @return [Hash]
      def build_metadata(name, primary, records)
        namespace, short = split_name(name, primary)
        prerequisites = records.flat_map { |record| record[:prerequisites] }.uniq
        {
          task_name: short, full_name: name,
          description: records.filter_map { |record| record[:description] }.first,
          task_namespace: namespace, task_dependencies: prerequisites,
          arguments: records.map { |record| record[:arguments] }.find(&:any?) || [],
          has_environment_dependency: prerequisites.include?('environment'),
          source_lines: primary[:body].lines.size, line_number: primary[:line],
          kind: primary[:kind].to_s,
          shell_commands: records.flat_map { |record| catalog.shell_commands(record[:facts]) }.uniq
        }.merge(optional_metadata(primary, records))
      end

      # Keys present only when they say something.
      def optional_metadata(primary, records)
        definitions, enhancements = records.partition { |record| !record[:enhancement] }
        defined_in = definitions.map { |record| relative_path(record[:file]) }.uniq
        {
          task_class: primary[:task_class],
          conditions: (primary[:conditions] unless primary[:conditions].empty?),
          name_source: primary[:name_source],
          defined_in: (defined_in if defined_in.size > 1),
          enhanced_in: (enhancements.map { |record| relative_path(record[:file]) }.uniq unless enhancements.empty?)
        }.compact
      end

      # Dependencies of one definition or enhancement: what its body
      # references, the tasks it invokes, its prerequisites, and the support
      # files it reaches.
      #
      # @param record [Hash] a {RakeTaskCatalog} record
      # @return [Array<Hash>]
      def extract_dependencies(record)
        deps = scan_common_dependencies(record[:body])
        record[:facts][:invocations].each do |target|
          deps << { type: :rake_task, target: target, via: :task_invoke }
        end
        record[:prerequisites].each do |dep|
          next if dep == 'environment'

          deps << { type: :rake_task, target: catalog.resolve(dep, record[:namespace]), via: :task_dependency }
        end
        deps + catalog.support_dependencies(record[:facts])
      end

      # Build the unit for one support file.
      #
      # @param relative [String] root-relative path, which is also the identifier
      # @return [ExtractedUnit, nil]
      def build_support_unit(relative)
        file = @root.join(relative).to_s
        data = rake_file_data(file)
        return nil unless data

        facts = data[:parsed].facts
        unit = ExtractedUnit.new(type: :rake_task, identifier: relative, file_path: file)
        unit.source_code = published_source(data)
        unit.metadata = {
          kind: SUPPORT_KIND, constants: data[:parsed].constants.uniq,
          methods: data[:parsed].method_definitions.map { |definition| definition[:name] }.uniq,
          shell_commands: catalog.shell_commands(facts), source_lines: data[:source].lines.size
        }
        unit.dependencies = consolidate_dependencies(
          scan_common_dependencies(data[:source]), catalog.support_dependencies(facts, except: relative)
        )
        unit
      end
    end
  end
end
