# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'pathname'
require 'set'

require_relative 'extracted_unit'
require_relative 'dependency_graph'
require_relative 'extractors/model_extractor'
require_relative 'extractors/controller_extractor'
require_relative 'extractors/phlex_extractor'
require_relative 'extractors/service_extractor'
require_relative 'extractors/job_extractor'
require_relative 'extractors/mailer_extractor'
require_relative 'extractors/graphql_extractor'
require_relative 'extractors/serializer_extractor'
require_relative 'extractors/rails_source_extractor'
require_relative 'extractors/view_component_extractor'
require_relative 'extractors/manager_extractor'
require_relative 'extractors/policy_extractor'
require_relative 'extractors/validator_extractor'
require_relative 'extractors/concern_extractor'
require_relative 'extractors/route_extractor'
require_relative 'extractors/middleware_extractor'
require_relative 'extractors/i18n_extractor'
require_relative 'extractors/pundit_extractor'
require_relative 'extractors/configuration_extractor'
require_relative 'extractors/engine_extractor'
require_relative 'extractors/view_template_extractor'
require_relative 'extractors/migration_extractor'
require_relative 'extractors/action_cable_extractor'
require_relative 'extractors/scheduled_job_extractor'
require_relative 'extractors/rake_task_extractor'
require_relative 'extractors/state_machine_extractor'
require_relative 'extractors/event_extractor'
require_relative 'extractors/decorator_extractor'
require_relative 'extractors/database_view_extractor'
require_relative 'extractors/caching_extractor'
require_relative 'extractors/factory_extractor'
require_relative 'extractors/test_mapping_extractor'
require_relative 'extractors/poro_extractor'
require_relative 'extractors/lib_extractor'
require_relative 'graph_analyzer'
require_relative 'model_name_cache'
require_relative 'flow_precomputer'

module CodebaseIndex
  # Extractor is the main orchestrator for codebase extraction.
  #
  # It coordinates all individual extractors, builds the dependency graph,
  # enriches with git data, and outputs structured JSON for the indexing pipeline.
  #
  # @example Full extraction
  #   extractor = Extractor.new(output_dir: "tmp/codebase_index")
  #   results = extractor.extract_all
  #
  # @example Incremental extraction (for CI)
  #   extractor = Extractor.new
  #   extractor.extract_changed(["app/models/user.rb", "app/services/checkout.rb"])
  #
  class Extractor
    # Directories under app/ that contain classes we need to extract.
    # Used by eager_load_extraction_directories as a fallback when
    # Rails.application.eager_load! fails (e.g., NameError from graphql/).
    EXTRACTION_DIRECTORIES = %w[
      models
      controllers
      services
      jobs
      mailers
      components
      interactors
      operations
      commands
      use_cases
      serializers
      decorators
      blueprinters
      managers
      policies
      validators
      channels
      presenters
      form_objects
    ].freeze

    EXTRACTORS = {
      models: Extractors::ModelExtractor,
      controllers: Extractors::ControllerExtractor,
      graphql: Extractors::GraphQLExtractor,
      components: Extractors::PhlexExtractor,
      view_components: Extractors::ViewComponentExtractor,
      services: Extractors::ServiceExtractor,
      jobs: Extractors::JobExtractor,
      mailers: Extractors::MailerExtractor,
      serializers: Extractors::SerializerExtractor,
      managers: Extractors::ManagerExtractor,
      policies: Extractors::PolicyExtractor,
      validators: Extractors::ValidatorExtractor,
      concerns: Extractors::ConcernExtractor,
      routes: Extractors::RouteExtractor,
      middleware: Extractors::MiddlewareExtractor,
      i18n: Extractors::I18nExtractor,
      pundit_policies: Extractors::PunditExtractor,
      configurations: Extractors::ConfigurationExtractor,
      engines: Extractors::EngineExtractor,
      view_templates: Extractors::ViewTemplateExtractor,
      migrations: Extractors::MigrationExtractor,
      action_cable_channels: Extractors::ActionCableExtractor,
      scheduled_jobs: Extractors::ScheduledJobExtractor,
      rake_tasks: Extractors::RakeTaskExtractor,
      state_machines: Extractors::StateMachineExtractor,
      events: Extractors::EventExtractor,
      decorators: Extractors::DecoratorExtractor,
      database_views: Extractors::DatabaseViewExtractor,
      caching: Extractors::CachingExtractor,
      factories: Extractors::FactoryExtractor,
      test_mappings: Extractors::TestMappingExtractor,
      rails_source: Extractors::RailsSourceExtractor,
      poros: Extractors::PoroExtractor,
      libs: Extractors::LibExtractor
    }.freeze

    # Maps singular unit types (as stored in ExtractedUnit/graph nodes)
    # to the plural keys used in the EXTRACTORS constant.
    #
    # @return [Hash{Symbol => Symbol}]
    TYPE_TO_EXTRACTOR_KEY = {
      model: :models,
      controller: :controllers,
      service: :services,
      component: :components,
      view_component: :view_components,
      job: :jobs,
      mailer: :mailers,
      graphql_type: :graphql,
      graphql_mutation: :graphql,
      graphql_resolver: :graphql,
      graphql_query: :graphql,
      serializer: :serializers,
      manager: :managers,
      policy: :policies,
      validator: :validators,
      concern: :concerns,
      route: :routes,
      middleware: :middleware,
      i18n: :i18n,
      pundit_policy: :pundit_policies,
      configuration: :configurations,
      engine: :engines,
      view_template: :view_templates,
      migration: :migrations,
      action_cable_channel: :action_cable_channels,
      scheduled_job: :scheduled_jobs,
      rake_task: :rake_tasks,
      state_machine: :state_machines,
      event: :events,
      decorator: :decorators,
      database_view: :database_views,
      caching: :caching,
      factory: :factories,
      test_mapping: :test_mappings,
      rails_source: :rails_source,
      poro: :poros,
      lib: :libs
    }.freeze

    # Maps unit types to class-based extractor methods (constantize + call).
    CLASS_BASED = {
      model: :extract_model, controller: :extract_controller,
      component: :extract_component, view_component: :extract_component,
      mailer: :extract_mailer, action_cable_channel: :extract_channel
    }.freeze

    # Maps unit types to file-based extractor methods (pass file_path).
    FILE_BASED = {
      service: :extract_service_file, job: :extract_job_file,
      serializer: :extract_serializer_file, manager: :extract_manager_file,
      policy: :extract_policy_file, validator: :extract_validator_file,
      concern: :extract_concern_file,
      i18n: :extract_i18n_file,
      pundit_policy: :extract_pundit_file,
      configuration: :extract_configuration_file,
      view_template: :extract_view_template_file,
      migration: :extract_migration_file,
      rake_task: :extract_rake_file,
      decorator: :extract_decorator_file,
      database_view: :extract_view_file,
      caching: :extract_caching_file,
      test_mapping: :extract_test_file,
      poro: :extract_poro_file,
      lib: :extract_lib_file
    }.freeze

    # GraphQL types all use the same extractor method.
    GRAPHQL_TYPES = %i[graphql_type graphql_mutation graphql_resolver graphql_query].freeze

    attr_reader :output_dir, :dependency_graph

    def initialize(output_dir: nil)
      @output_dir = Pathname.new(output_dir || Rails.root.join('tmp/codebase_index'))
      @dependency_graph = DependencyGraph.new
      @results = {}
    end

    # ══════════════════════════════════════════════════════════════════════
    # Full Extraction
    # ══════════════════════════════════════════════════════════════════════

    # Perform full extraction of the codebase
    #
    # @return [Hash] Results keyed by extractor type
    def extract_all
      setup_output_directory
      ModelNameCache.reset!

      # Eager load once — all extractors need loaded classes for introspection.
      safe_eager_load!

      # Phase 1: Extract all units
      if CodebaseIndex.configuration.concurrent_extraction
        extract_all_concurrent
      else
        extract_all_sequential
      end

      # Phase 1.5: Deduplicate results
      Rails.logger.info '[CodebaseIndex] Deduplicating results...'
      deduplicate_results

      # Rebuild graph from deduped results — Phase 1 registered all units including
      # duplicates, and DependencyGraph has no remove/unregister API.
      @dependency_graph = DependencyGraph.new
      @results.each_value { |units| units.each { |u| @dependency_graph.register(u) } }

      # Phase 2: Resolve dependents (reverse dependencies)
      Rails.logger.info '[CodebaseIndex] Resolving dependents...'
      resolve_dependents

      # Phase 3: Graph analysis (PageRank, structural metrics)
      Rails.logger.info '[CodebaseIndex] Analyzing dependency graph...'
      @graph_analysis = GraphAnalyzer.new(@dependency_graph).analyze

      # Phase 3.5: Precompute request flows (opt-in)
      if CodebaseIndex.configuration.precompute_flows
        Rails.logger.info '[CodebaseIndex] Precomputing request flows...'
        precompute_flows
      end

      # Phase 4: Enrich with git data
      Rails.logger.info '[CodebaseIndex] Enriching with git data...'
      enrich_with_git_data

      # Phase 4.5: Normalize file_path to relative paths
      Rails.logger.info '[CodebaseIndex] Normalizing file paths...'
      normalize_file_paths

      # Phase 5: Write output
      Rails.logger.info '[CodebaseIndex] Writing output...'
      write_results
      write_dependency_graph
      write_graph_analysis
      write_manifest
      write_structural_summary

      log_summary

      @results
    end

    # ══════════════════════════════════════════════════════════════════════
    # Incremental Extraction
    # ══════════════════════════════════════════════════════════════════════

    # Extract only units affected by changed files
    # Used for incremental indexing in CI
    #
    # @param changed_files [Array<String>] List of changed file paths
    # @return [Array<String>] List of re-extracted unit identifiers
    def extract_changed(changed_files)
      # Load existing graph
      graph_path = @output_dir.join('dependency_graph.json')
      @dependency_graph = DependencyGraph.from_h(JSON.parse(File.read(graph_path))) if graph_path.exist?

      ModelNameCache.reset!

      # Eager load to ensure newly-added classes are discoverable.
      safe_eager_load!

      # Normalize relative paths (from git diff) to absolute (as stored in file_map)
      absolute_files = changed_files.map do |f|
        Pathname.new(f).absolute? ? f : Rails.root.join(f).to_s
      end

      # Compute affected units
      affected_ids = @dependency_graph.affected_by(absolute_files)
      Rails.logger.info "[CodebaseIndex] #{changed_files.size} changed files affect #{affected_ids.size} units"

      # Re-extract affected units
      affected_types = Set.new
      affected_ids.each do |unit_id|
        re_extract_unit(unit_id, affected_types: affected_types)
      end

      # Regenerate type indexes for affected types
      affected_types.each do |type_key|
        regenerate_type_index(type_key)
      end

      # Update graph, manifest, and summary
      write_dependency_graph
      write_manifest
      write_structural_summary

      affected_ids
    end

    private

    # ──────────────────────────────────────────────────────────────────────
    # Eager Loading
    # ──────────────────────────────────────────────────────────────────────

    # Attempt eager_load!, falling back to per-directory loading on NameError.
    #
    # A single NameError (e.g., app/graphql/ referencing an uninstalled gem)
    # aborts eager_load! entirely. Zeitwerk processes dirs alphabetically,
    # so graphql/ before models/ means models never load. The fallback
    # loads only the directories we actually need for extraction.
    def safe_eager_load!
      Rails.application.eager_load!
    rescue NameError => e
      Rails.logger.warn "[CodebaseIndex] eager_load! hit NameError: #{e.message}"
      Rails.logger.warn '[CodebaseIndex] Falling back to per-directory eager loading'
      eager_load_extraction_directories
    end

    # Load classes from each extraction-relevant app/ subdirectory individually.
    # Uses Zeitwerk's eager_load_dir when available (Rails 7.1+/Zeitwerk 2.6+),
    # otherwise falls back to Dir.glob + require.
    def eager_load_extraction_directories
      loader = Rails.autoloaders.main

      EXTRACTION_DIRECTORIES.each do |subdir|
        dir = Rails.root.join('app', subdir)
        next unless dir.exist?

        begin
          if loader.respond_to?(:eager_load_dir)
            loader.eager_load_dir(dir.to_s)
          else
            Dir.glob(dir.join('**/*.rb')).each do |file|
              require file
            rescue NameError, LoadError => e
              Rails.logger.warn "[CodebaseIndex] Skipped #{file}: #{e.message}"
            end
          end
        rescue NameError, LoadError => e
          Rails.logger.warn "[CodebaseIndex] Failed to eager load app/#{subdir}/: #{e.message}"
        end
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Extraction Strategies
    # ──────────────────────────────────────────────────────────────────────

    def extract_all_sequential
      EXTRACTORS.each do |type, extractor_class|
        Rails.logger.info "[CodebaseIndex] Extracting #{type}..."
        start_time = Time.current

        extractor = extractor_class.new
        units = extractor.extract_all

        @results[type] = units

        elapsed = Time.current - start_time
        Rails.logger.info "[CodebaseIndex] Extracted #{units.size} #{type} in #{elapsed.round(2)}s"

        # Register in dependency graph
        units.each { |unit| @dependency_graph.register(unit) }
      end
    end

    # Run each extractor in its own thread, then register results sequentially.
    #
    # Thread safety notes:
    # - ModelNameCache is pre-computed before threads start (avoids ||= race)
    # - Each thread gets its own extractor instance (no shared mutable state)
    # - Results collected via Mutex-protected Hash
    # - DependencyGraph registration is sequential (post-join)
    def extract_all_concurrent
      # Pre-compute ModelNameCache to avoid race on lazy memoization.
      # Multiple threads calling model_names concurrently could trigger
      # duplicate compute_model_names calls without this warm-up.
      ModelNameCache.model_names
      ModelNameCache.model_names_regex

      results_mutex = Mutex.new
      threads = EXTRACTORS.map do |type, extractor_class|
        Thread.new do
          Rails.logger.info "[CodebaseIndex] [Thread] Extracting #{type}..."
          start_time = Time.current

          extractor = extractor_class.new
          units = extractor.extract_all

          elapsed = Time.current - start_time
          Rails.logger.info "[CodebaseIndex] [Thread] Extracted #{units.size} #{type} in #{elapsed.round(2)}s"

          results_mutex.synchronize { @results[type] = units }
        rescue StandardError => e
          Rails.logger.error "[CodebaseIndex] [Thread] #{type} failed: #{e.message}"
          results_mutex.synchronize { @results[type] = [] }
        end
      end

      threads.each(&:join)

      # Register into dependency graph sequentially — DependencyGraph is not thread-safe
      EXTRACTORS.each_key do |type|
        (@results[type] || []).each { |unit| @dependency_graph.register(unit) }
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Setup
    # ──────────────────────────────────────────────────────────────────────

    def setup_output_directory
      FileUtils.mkdir_p(@output_dir)
      EXTRACTORS.each_key do |type|
        FileUtils.mkdir_p(@output_dir.join(type.to_s))
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Dependency Resolution
    # ──────────────────────────────────────────────────────────────────────

    def resolve_dependents
      # Build complete unit map first (cross-type dependencies require all units indexed).
      unit_map = @results.each_with_object({}) do |(_type, units), map|
        units.each { |u| map[u.identifier] = u }
      end

      # Resolve dependents using the complete map.
      @results.each_value do |units|
        units.each do |unit|
          unit.dependencies.each do |dep|
            target_unit = unit_map[dep[:target]]
            next unless target_unit

            target_unit.dependents ||= []
            target_unit.dependents << {
              type: unit.type,
              identifier: unit.identifier
            }
          end
        end
      end
    end

    # Remove duplicate units (same identifier) within each type, keeping the first occurrence.
    # Duplicates arise when multiple extractors produce the same unit (e.g., engine-mounted
    # routes duplicating app routes). Without dedup, downstream phases would produce inflated
    # counts, duplicate _index.json entries, and last-writer-wins file overwrites.
    def deduplicate_results
      @results.each do |type, units|
        deduped = units.uniq(&:identifier)
        dropped = units.size - deduped.size

        Rails.logger.warn "[CodebaseIndex] Deduplicated #{type}: dropped #{dropped} duplicate(s)" if dropped.positive?

        @results[type] = deduped
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Flow Precomputation
    # ──────────────────────────────────────────────────────────────────────

    def precompute_flows
      all_units = @results.each_value.flat_map(&:itself)
      precomputer = FlowPrecomputer.new(units: all_units, graph: @dependency_graph, output_dir: @output_dir.to_s)
      flow_map = precomputer.precompute
      Rails.logger.info "[CodebaseIndex] Precomputed #{flow_map.size} request flows"
    rescue StandardError => e
      Rails.logger.error "[CodebaseIndex] Flow precomputation failed: #{e.message}"
    end

    # ──────────────────────────────────────────────────────────────────────
    # Git Enrichment
    # ──────────────────────────────────────────────────────────────────────

    def enrich_with_git_data
      return unless git_available?

      # Collect all file paths that need git data
      file_paths = []
      @results.each do |type, units|
        next if %i[rails_source gem_source].include?(type)

        units.each do |unit|
          file_paths << unit.file_path if unit.file_path && File.exist?(unit.file_path)
        end
      end

      # Batch-fetch all git data in minimal subprocess calls
      git_data = batch_git_data(file_paths)
      root = "#{Rails.root}/"

      # Assign results to units
      @results.each do |type, units|
        next if %i[rails_source gem_source].include?(type)

        units.each do |unit|
          next unless unit.file_path

          relative = unit.file_path.sub(root, '')
          unit.metadata[:git] = git_data[relative] if git_data[relative]
        end
      end
    end

    # Normalize all unit file_paths to relative paths (relative to Rails.root).
    #
    # Extractors set file_path via source_location, which returns absolute paths.
    # This normalization ensures consistent relative paths (e.g., "app/models/user.rb")
    # across all environments (local, Docker, CI) where Rails.root differs.
    #
    # Must run after enrich_with_git_data, which needs absolute paths for
    # File.exist? checks and git log commands.
    def normalize_file_paths
      @results.each_value do |units|
        units.each do |unit|
          unit.file_path = normalize_file_path(unit.file_path)
        end
      end
    end

    # Strip Rails.root prefix from a file path, converting it to a relative path.
    #
    # @param path [String, nil] Absolute or relative file path
    # @return [String, nil] Relative path, or the original value if already relative,
    #   nil, or not under Rails.root (e.g., a gem path)
    def normalize_file_path(path)
      return path unless path

      root = Rails.root.to_s
      prefix = root.end_with?('/') ? root : "#{root}/"
      path.start_with?(prefix) ? path.sub(prefix, '') : path
    end

    def git_available?
      return @git_available if defined?(@git_available)

      @git_available = begin
        _, status = Open3.capture2('git', 'rev-parse', '--git-dir')
        status.success?
      rescue StandardError
        false
      end
    end

    # Safe git command execution — no shell interpolation
    #
    # @param args [Array<String>] Git command arguments
    # @return [String] Command output (empty string on failure)
    def run_git(*args)
      output, status = Open3.capture2('git', *args)
      status.success? ? output.strip : ''
    rescue StandardError
      ''
    end

    # Batch-fetch git data for all file paths in two git commands.
    #
    # @param file_paths [Array<String>] Absolute file paths
    # @return [Hash{String => Hash}] Keyed by relative path
    def batch_git_data(file_paths)
      return {} if file_paths.empty?

      root = "#{Rails.root}/"
      relative_paths = file_paths.map { |f| f.sub(root, '') }
      result = {}
      relative_paths.each { |rp| result[rp] = {} }

      path_set = relative_paths.to_set
      relative_paths.each_slice(500) do |batch|
        log_output = run_git(
          'log', '--all', '--name-only',
          '--format=__COMMIT__%H|||%an|||%cI|||%s',
          '--since=365 days ago',
          '--', *batch
        )
        parse_git_log_output(log_output, path_set, result)
      end

      ninety_days_ago = (Time.current - 90.days).iso8601
      result.each do |relative_path, data|
        result[relative_path] = build_file_metadata(data, ninety_days_ago)
      end

      result
    end

    # Parse git log output line-by-line, populating result with per-file commit data.
    def parse_git_log_output(log_output, path_set, result)
      current_commit = nil

      log_output.each_line do |line|
        line = line.strip
        next if line.empty?

        if line.start_with?('__COMMIT__')
          parts = line.sub('__COMMIT__', '').split('|||', 4)
          current_commit = { sha: parts[0], author: parts[1], date: parts[2], message: parts[3] }
        elsif current_commit && path_set.include?(line)
          entry = result[line] ||= {}
          unless entry[:last_modified]
            entry[:last_modified] = current_commit[:date]
            entry[:last_author] = current_commit[:author]
          end
          (entry[:commits] ||= []) << current_commit
          (entry[:contributors] ||= Hash.new(0))[current_commit[:author]] += 1
        end
      end
    end

    # Classify how frequently a file changes based on commit counts.
    def classify_change_frequency(total_count, recent_count)
      if total_count <= 2
        :new
      elsif recent_count >= 10
        :hot
      elsif recent_count >= 3
        :active
      elsif recent_count >= 1
        :stable
      else
        :dormant
      end
    end

    # Build final metadata hash from raw commit data.
    def build_file_metadata(data, ninety_days_ago)
      all_commits = data[:commits] || []
      contributor_counts = data[:contributors] || {}
      recent_count = all_commits.count { |c| c[:date] && c[:date] > ninety_days_ago }

      {
        last_modified: data[:last_modified],
        last_author: data[:last_author],
        commit_count: all_commits.size,
        contributors: contributor_counts
                      .sort_by { |_, count| -count }
                      .first(5)
                      .map { |name, count| { name: name, commits: count } },
        recent_commits: all_commits.first(5).map do |c|
          { sha: c[:sha]&.first(8), message: c[:message], date: c[:date], author: c[:author] }
        end,
        change_frequency: classify_change_frequency(all_commits.size, recent_count)
      }
    end

    # ──────────────────────────────────────────────────────────────────────
    # Output Writers
    # ──────────────────────────────────────────────────────────────────────

    def write_results
      @results.each do |type, units|
        type_dir = @output_dir.join(type.to_s)

        units.each do |unit|
          File.write(
            type_dir.join(collision_safe_filename(unit.identifier)),
            json_serialize(unit.to_h)
          )
        end

        # Also write a type index for fast lookups
        index = units.map do |u|
          {
            identifier: u.identifier,
            file_path: u.file_path,
            namespace: u.namespace,
            estimated_tokens: u.estimated_tokens,
            chunk_count: u.chunks.size
          }
        end

        File.write(
          type_dir.join('_index.json'),
          json_serialize(index)
        )
      end
    end

    def write_dependency_graph
      graph_data = @dependency_graph.to_h
      graph_data[:pagerank] = @dependency_graph.pagerank

      File.write(
        @output_dir.join('dependency_graph.json'),
        json_serialize(graph_data)
      )
    end

    def write_graph_analysis
      return unless @graph_analysis

      File.write(
        @output_dir.join('graph_analysis.json'),
        json_serialize(@graph_analysis)
      )
    end

    def write_manifest
      manifest = {
        extracted_at: Time.current.iso8601,
        rails_version: Rails.version,
        ruby_version: RUBY_VERSION,

        # Counts by type
        counts: @results.transform_values(&:size),

        # Total stats
        total_units: @results.values.sum(&:size),
        total_chunks: @results.sum { |_, units| units.sum { |u| u.chunks.size } },

        # Git info
        git_sha: run_git('rev-parse', 'HEAD').presence,
        git_branch: run_git('rev-parse', '--abbrev-ref', 'HEAD').presence,

        # For change detection
        gemfile_lock_sha: gemfile_lock_sha,
        schema_sha: schema_sha
      }

      File.write(
        @output_dir.join('manifest.json'),
        json_serialize(manifest)
      )
    end

    # Write a compact TOC-style summary of extracted units.
    #
    # Produces a SUMMARY.md under 8K tokens (~24KB) by listing one line per
    # category with count and top-5 namespace breakdown, rather than enumerating
    # every unit. Per-unit detail is available in the per-category _index.json files.
    #
    # @return [void]
    def write_structural_summary
      return if @results.empty?

      total_units    = @results.values.sum(&:size)
      total_chunks   = @results.sum { |_, units| units.sum { |u| [u.chunks.size, 1].max } }
      category_count = @results.count { |_, units| units.any? }

      summary = []
      summary << '# Codebase Index Summary'
      summary << "Generated: #{Time.current.iso8601}"
      summary << "Rails #{Rails.version} / Ruby #{RUBY_VERSION}"
      summary << "Units: #{total_units} | Chunks: #{total_chunks} | Categories: #{category_count}"
      summary << ''

      @results.each do |type, units|
        next if units.empty?

        summary << "## #{type.to_s.titleize} (#{units.size})"

        ns_counts = units
                    .group_by { |u| u.namespace.nil? || u.namespace.empty? ? '(root)' : u.namespace }
                    .transform_values(&:size)
                    .sort_by { |_, count| -count }
                    .first(5)

        ns_parts = ns_counts.map { |ns, count| "#{ns} #{count}" }
        summary << "Namespaces: #{ns_parts.join(', ')}" unless ns_parts.empty?
        summary << ''
      end

      summary << '## Dependency Overview'
      summary << ''

      graph_stats = @dependency_graph.to_h[:stats]
      if graph_stats
        summary << "- Total nodes: #{graph_stats[:node_count]}"
        summary << "- Total edges: #{graph_stats[:edge_count]}"
      end

      if @graph_analysis
        hub_nodes = @graph_analysis[:hubs]
        significant_hubs = hub_nodes&.select { |h| h[:dependent_count] > 20 }
        if significant_hubs&.any?
          hub_names = significant_hubs.map { |h| h[:identifier] }.join(', ')
          summary << "- Hub nodes (>20 dependents): #{hub_names}"
        end
      end

      summary << ''

      File.write(
        @output_dir.join('SUMMARY.md'),
        summary.join("\n")
      )
    end

    def regenerate_type_index(type_key)
      type_dir = @output_dir.join(type_key.to_s)
      return unless type_dir.directory?

      # Scan existing unit JSON files (exclude _index.json)
      index = Dir[type_dir.join('*.json')].filter_map do |file|
        next if File.basename(file) == '_index.json'

        data = JSON.parse(File.read(file))
        {
          identifier: data['identifier'],
          file_path: data['file_path'],
          namespace: data['namespace'],
          estimated_tokens: data['estimated_tokens'],
          chunk_count: (data['chunks'] || []).size
        }
      end

      File.write(
        type_dir.join('_index.json'),
        json_serialize(index)
      )
    end

    # ──────────────────────────────────────────────────────────────────────
    # Helpers
    # ──────────────────────────────────────────────────────────────────────

    def gemfile_lock_sha
      lock_path = Rails.root.join('Gemfile.lock')
      return nil unless lock_path.exist?

      Digest::SHA256.file(lock_path).hexdigest
    end

    def schema_sha
      schema_path = Rails.root.join('db/schema.rb')
      return nil unless schema_path.exist?

      Digest::SHA256.file(schema_path).hexdigest
    end

    # Generate a safe JSON filename from a unit identifier.
    #
    # @param identifier [String] Unit identifier (e.g., "Admin::UsersController")
    # @return [String] Safe filename (e.g., "Admin__UsersController.json")
    def safe_filename(identifier)
      "#{identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}.json"
    end

    # Generate a collision-safe JSON filename by appending a short digest.
    # Unlike safe_filename, this guarantees distinct filenames even when two
    # identifiers differ only in characters that safe_filename normalizes
    # (e.g., "GET /foo/bar" vs "GET /foo_bar" both become "GET__foo_bar.json").
    #
    # @param identifier [String] Unit identifier
    # @return [String] Collision-safe filename (e.g., "GET__foo_bar_a1b2c3d4.json")
    def collision_safe_filename(identifier)
      base = identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
      digest = ::Digest::SHA256.hexdigest(identifier)[0, 8]
      "#{base}_#{digest}.json"
    end

    def json_serialize(data)
      if CodebaseIndex.configuration.pretty_json
        JSON.pretty_generate(data)
      else
        JSON.generate(data)
      end
    end

    def log_summary
      total = @results.values.sum(&:size)
      chunks = @results.sum { |_, units| units.sum { |u| u.chunks.size } }

      Rails.logger.info '[CodebaseIndex] ═══════════════════════════════════════════'
      Rails.logger.info '[CodebaseIndex] Extraction Complete'
      Rails.logger.info '[CodebaseIndex] ═══════════════════════════════════════════'
      @results.each do |type, units|
        Rails.logger.info "[CodebaseIndex]   #{type}: #{units.size} units"
      end
      Rails.logger.info '[CodebaseIndex] ───────────────────────────────────────────'
      Rails.logger.info "[CodebaseIndex]   Total: #{total} units, #{chunks} chunks"
      Rails.logger.info "[CodebaseIndex]   Output: #{@output_dir}"
      Rails.logger.info '[CodebaseIndex] ═══════════════════════════════════════════'
    end

    # ──────────────────────────────────────────────────────────────────────
    # Incremental Re-extraction
    # ──────────────────────────────────────────────────────────────────────

    def re_extract_unit(unit_id, affected_types: nil)
      # Framework source only changes on version updates
      if unit_id.start_with?('rails/') || unit_id.start_with?('gems/')
        Rails.logger.debug "[CodebaseIndex] Skipping framework re-extraction for #{unit_id}"
        return
      end

      # Find the unit's type from the graph
      node = @dependency_graph.to_h[:nodes][unit_id]
      return unless node

      type = node[:type]&.to_sym
      file_path = node[:file_path]

      return unless file_path && File.exist?(file_path)

      # Re-extract based on type
      extractor_key = TYPE_TO_EXTRACTOR_KEY[type]
      return unless extractor_key

      extractor = EXTRACTORS[extractor_key]&.new
      return unless extractor

      unit = if (method = CLASS_BASED[type])
               klass = if unit_id.match?(/\A[A-Z][A-Za-z0-9_:]*\z/)
                         begin
                           unit_id.constantize
                         rescue StandardError
                           nil
                         end
                       end
               extractor.public_send(method, klass) if klass
             elsif (method = FILE_BASED[type])
               extractor.public_send(method, file_path)
             elsif GRAPHQL_TYPES.include?(type)
               extractor.extract_graphql_file(file_path)
             end

      return unless unit

      # Update dependency graph
      @dependency_graph.register(unit)

      # Track which type was affected
      affected_types&.add(extractor_key)

      # Write updated unit
      type_dir = @output_dir.join(extractor_key.to_s)

      File.write(
        type_dir.join(collision_safe_filename(unit.identifier)),
        json_serialize(unit.to_h)
      )

      Rails.logger.info "[CodebaseIndex] Re-extracted #{unit_id}"
    end
  end
end
