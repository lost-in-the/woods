# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'atomic_file'
require_relative 'path_dispatcher'
require_relative 'extractors/poro_extractor'
require_relative 'extractors/graphql_operation_extractor'
require_relative 'extractors/lib_extractor'
require_relative 'graphql_document_paths'
require_relative 'extractors/template_extensions'

module Woods
  # Ruby files under the configured sweep roots, and GraphQL operation
  # documents under the configured document roots, that produced no unit,
  # each with the reason it was skipped. Generator templates under `lib/` are
  # listed too: they carry a Ruby extension and are never extracted.
  #
  # Configuration sources excluded by Git are listed too, including YAML
  # and root files without a Ruby extension.
  #
  # Reasons for Ruby files:
  # * +git_ignored+ — Git ignore rules exclude a configuration source
  # * +untracked+ — Git does not track a configuration source
  # * +template+ — a generator template, ERB that is not parseable Ruby
  # * +rejected_by:<key>+ — a file rule owns the path, or a class-discovered
  #   extractor owns the class, and that extractor emitted nothing for it
  # * +parse_error+ — Prism could not parse the file
  # * +no_declaration+ — no class, module, or Struct/Data assignment
  # * +namespace_only+ — modules with no methods, constants, classes, or hook blocks
  # * +not_owned+ — a declaration whose ownership could not be proven here
  #   (unloaded, reopened from another file, or methods defined elsewhere)
  #
  # Reasons for GraphQL documents (`config.graphql_document_paths`):
  # * +graphql_unavailable+ — the graphql gem is not loaded, so no document is read
  # * +schema_definitions+ — the file holds type definitions (an SDL dump), not operations
  # * +parse_error+ — graphql-ruby could not parse the file
  #
  # Template files (ERB, HAML, Jbuilder, Slim) are listed when a configured
  # sweep glob names them. Nothing sweeps them as Ruby, so they would
  # otherwise sit outside every unit with no record:
  # * +non_view_template+ — a template outside the view directories, such as
  #   a `config/*.erb` crontab
  # * +unsupported_template_engine+ — a view no registered engine reads
  # * +rejected_by:view_templates+ — a view its extractor emitted nothing for
  # A template beside the Ruby file of a unit (a component sidecar) counts as
  # covered by that unit.
  #
  # The report is a pure function of the tree and the published unit paths,
  # so full and incremental runs produce the same bytes.
  class SkippedFiles
    FILENAME = 'skipped_files.json'

    # @param root [String] application root
    # @param poro [Extractors::PoroExtractor] classifier for unowned files
    def initialize(root:, poro: Extractors::PoroExtractor.new)
      @root = root.to_s
      @poro = poro
      @git_filter = GitSourceFilter.new(root: @root)
    end

    # @param unit_paths [Enumerable<String, nil>] every unit's file_path, absolute or root-relative
    # @return [Hash] +total+, +counts+ by reason, and +files+ sorted by path
    def build(unit_paths)
      covered = unit_paths.compact.to_set { |path| relativize(path.to_s) }
      templates = template_candidates.reject { |relative| sidecar_of_unit?(relative, covered) }
      files = (candidates + templates).uniq.sort.reject { |relative| covered.include?(relative) }.map do |relative|
        { 'path' => relative, 'reason' => skip_reason(relative) }
      end
      counts = files.map { |entry| entry['reason'] }.tally.sort.to_h
      { 'total' => files.size, 'counts' => counts, 'files' => files }
    end

    # The report with the best-effort flow failures (W-14) under
    # +flow_failures+, sorted by entry point; without the key when there are
    # none. They are actions, not files, so +files+, +counts+ and +total+ keep
    # describing files alone.
    #
    # @param report [Hash] result of {#build}
    # @param failures [Array<Hash>] +entry_point+, +controller+, +action+, +reason+, +error+
    # @return [Hash]
    def self.with_flow_failures(report, failures)
      report = report.except('flow_failures')
      return report if failures.empty?

      report.merge('flow_failures' => failures.sort_by { |failure| failure['entry_point'] })
    end

    # @param payload_dir [Pathname] generation payload directory
    # @param report [Hash] result of {#build}
    # @param durable [Boolean] fsync the file before returning
    # @return [void]
    def self.write(payload_dir, report, durable:)
      AtomicFile.write(Pathname(payload_dir).join(FILENAME), JSON.generate(report), durable: durable)
    end

    # @param payload_dir [Pathname] generation payload directory
    # @return [Hash, nil] the published report, or nil when the generation has none
    def self.read(payload_dir)
      path = Pathname(payload_dir).join(FILENAME)
      path.file? ? JSON.parse(AtomicFile.read(path)) : nil
    end

    private

    def candidates
      (ruby_candidates + configuration_candidates + GraphQLDocumentPaths.under(@root)).uniq.sort
    end

    def ruby_candidates
      globs = [Extractors::PoroExtractor::MODELS_GLOB, *Woods.configuration&.unclaimed_ruby_paths,
               Extractors::LibExtractor::TEMPLATE_GLOB]
      globs.flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: @root) }.uniq.select do |relative|
        relative.end_with?('.rb') && PathDispatcher::UNSWEPT_PREFIXES.none? { |prefix| relative.start_with?(prefix) } &&
          File.file?(File.join(@root, relative))
      end
    end

    def configuration_candidates
      config = Extractors::ConfigurationExtractor
      globs = [*Extractors::ConfigFileExtractor.configured_paths, *config::SOURCE_FILES,
               *config::DIRECTORY_TYPES.keys.map { |dir| "#{dir}/**/*.rb" },
               'config/routes.rb', 'config/routes/**/*.rb', 'lib/**/generators/**/*.rb']
      globs.flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: @root) }.select do |relative|
        File.file?(File.join(@root, relative)) && PathDispatcher.configuration_source_path?(relative) &&
          @git_filter.skip_reason(relative)
      end
    end

    # The file's own shape decides first, so `module Admin; end` under an
    # owned directory reads namespace_only, not rejected_by its owner.
    def reason_for(relative)
      if PathDispatcher.configuration_source_path?(relative)
        reason = @git_filter.skip_reason(relative)
        return reason if reason
      end

      return 'template' if Extractors::LibExtractor.generator_template?(relative)

      path = File.join(@root, relative)
      return Extractors::GraphQLOperationExtractor.document_skip_reason(path) if GraphQLDocumentPaths.match?(relative)

      static = @poro.static_skip_reason(path)
      return static if static

      key = PathDispatcher.claiming_key_for(relative)
      key ? "rejected_by:#{key}" : @poro.skip_reason(path)
    end

    # Configuration sources are YAML or Ruby, so no path takes both branches.
    def skip_reason(relative)
      template?(relative) ? template_reason(relative) : reason_for(relative)
    end

    # Template files the configured globs name.
    def template_candidates
      globs = Woods.configuration&.unclaimed_ruby_paths || []
      globs.flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: @root) }.uniq
           .select { |relative| listable_template?(relative) }
    end

    def listable_template?(relative)
      template?(relative) && PathDispatcher::UNSWEPT_PREFIXES.none? { |prefix| relative.start_with?(prefix) } &&
        File.file?(File.join(@root, relative))
    end

    def template?(relative)
      Extractors::TemplateExtensions::DETECTED.any? { |extension| relative.end_with?(extension) }
    end

    def template_reason(relative)
      key = PathDispatcher.claiming_key_for(relative)
      return "rejected_by:#{key}" if key

      view = Extractors::ViewTemplateExtractor::VIEW_DIRECTORIES.any? { |dir| relative.start_with?("#{dir}/") }
      view ? 'unsupported_template_engine' : 'non_view_template'
    end

    # A sidecar sits beside a Ruby file of the same name, or in a directory
    # named for one.
    def sidecar_of_unit?(relative, covered)
      directory = File.dirname(relative)
      covered.include?("#{directory}/#{File.basename(relative)[/\A[^.]+/]}.rb") || covered.include?("#{directory}.rb")
    end

    def relativize(path)
      path.start_with?('/') ? path.delete_prefix("#{@root}/") : path
    end
  end
end
