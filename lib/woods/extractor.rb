# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'pathname'
require 'set'

require_relative 'atomic_file'
require_relative 'filename_utils'
require_relative 'token_utils'
require_relative 'extracted_unit'
require_relative 'dependency_graph'
require_relative 'git_provenance'
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

module Woods
  # Extractor is the main orchestrator for codebase extraction.
  #
  # It coordinates all individual extractors, builds the dependency graph,
  # enriches with git data, and outputs structured JSON for the indexing pipeline.
  #
  # @example Full extraction
  #   extractor = Extractor.new(output_dir: "tmp/woods")
  #   results = extractor.extract_all
  #
  # @example Incremental extraction (for CI)
  #   extractor = Extractor.new
  #   extractor.extract_changed(["app/models/user.rb", "app/services/checkout.rb"])
  #
  class Extractor
    include FilenameUtils

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

    # Ordered path patterns (matched against Rails.root-relative paths)
    # mapping brand-new changed files — files with no file_map entry yet —
    # to the unit type to extract them as. First match wins, so concern
    # subdirectories must precede their parent model/controller patterns.
    NEW_FILE_TYPE_PATTERNS = [
      [%r{\Aapp/(?:models|controllers)/concerns/.+\.rb\z}, :concern],
      [%r{\Aapp/models/.+\.rb\z}, :model],
      [%r{\Aapp/controllers/.+\.rb\z}, :controller],
      [%r{\Aapp/(?:services|interactors|operations|commands|use_cases)/.+\.rb\z}, :service],
      [%r{\Aapp/(?:components|views)/.+\.rb\z}, :component],
      [%r{\Aapp/(?:jobs|workers)/.+\.rb\z}, :job],
      [%r{\Aapp/mailers/.+\.rb\z}, :mailer],
      [%r{\Aapp/graphql/.+\.rb\z}, :graphql_type],
      [%r{\Aapp/(?:serializers|blueprinters)/.+\.rb\z}, :serializer],
      [%r{\Aapp/(?:decorators|presenters|form_objects)/.+\.rb\z}, :decorator],
      [%r{\Aapp/policies/.+\.rb\z}, :policy],
      [%r{\Aapp/validators/.+\.rb\z}, :validator],
      [%r{\Aapp/channels/.+\.rb\z}, :action_cable_channel],
      [%r{\Aapp/views/.+\.(?:erb|haml|slim)\z}, :view_template],
      [%r{\Adb/migrate/.+\.rb\z}, :migration],
      [%r{\A(?:spec|test)/.+\.rb\z}, :test_mapping],
      [%r{\Alib/.+\.rb\z}, :lib]
    ].freeze

    # Autoload roots that Rails excludes from eager loading by default but
    # that can hold extractable classes. app/views is never eager-loaded,
    # yet phlex-rails autoloads components from it — a component that is
    # not constantized during boot (e.g. only referenced while rendering)
    # would be invisible to descendants-based extractors without this.
    LAZY_EAGER_LOAD_DIRS = %w[app/views].freeze

    # Types whose output directory is co-owned by another writer: the
    # woods:extract_framework task writes rails_source units with its own
    # filename scheme, so the stale-file sweep must leave them alone.
    SWEEP_EXEMPT_TYPES = %i[rails_source].freeze

    attr_reader :output_dir, :dependency_graph

    # Changed files from the last {#extract_changed} run that exist on disk
    # but could not be mapped to any unit (no file_map entry and no
    # extractable type) — they need a full extraction to be indexed.
    #
    # @return [Array<String>] Absolute file paths
    attr_reader :unhandled_changed_files

    # Units removed by the last {#extract_changed} run because their source
    # file was deleted (B-065). Without removal, deletions — and the delete
    # half of renames — left ghost units in the index until the next full
    # extraction's stale sweep.
    #
    # @return [Array<String>] Removed unit identifiers
    attr_reader :removed_unit_ids

    # Files under lazy eager-load roots (app/views + configured paths) that
    # failed to load during the last eager-load pass and were skipped. Their
    # classes never materialize, so they are invisible to descendants-based
    # extraction — a self-reported coverage gap rather than a silent one.
    #
    # @return [Array<String>] Absolute file paths
    attr_reader :lazy_load_skipped_files

    def initialize(output_dir: nil)
      @output_dir = Pathname.new(output_dir || Rails.root.join('tmp/woods'))
      @dependency_graph = DependencyGraph.new
      @results = {}
      @extractors = {}
      @unhandled_changed_files = []
      @removed_unit_ids = []
      @lazy_load_skipped_files = []
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
      if Woods.configuration.concurrent_extraction
        extract_all_concurrent
      else
        extract_all_sequential
      end

      # Phase 1.5: Deduplicate results
      Rails.logger.info '[Woods] Deduplicating results...'
      deduplicate_results

      # Rebuild graph from deduped results — Phase 1 registered all units including
      # duplicates, and DependencyGraph has no remove/unregister API.
      @dependency_graph = DependencyGraph.new
      @results.each_value { |units| units.each { |u| @dependency_graph.register(u) } }

      # Phase 2: Resolve dependents (reverse dependencies)
      Rails.logger.info '[Woods] Resolving dependents...'
      resolve_dependents

      # Phase 3: Graph analysis (PageRank, structural metrics)
      Rails.logger.info '[Woods] Analyzing dependency graph...'
      @graph_analysis = GraphAnalyzer.new(@dependency_graph).analyze

      # Phase 4: Enrich with git data
      Rails.logger.info '[Woods] Enriching with git data...'
      enrich_with_git_data

      # Phase 4.5: Normalize file_path to relative paths
      Rails.logger.info '[Woods] Normalizing file paths...'
      normalize_file_paths

      # Phase 5: Write output
      Rails.logger.info '[Woods] Writing output...'
      write_results

      # Phase 5.5: Precompute request flows (opt-in). Must run AFTER
      # write_results — FlowAssembler loads unit JSON from disk, so running
      # earlier assembled every flow from absent (fresh output dir) or
      # stale (previous run's) data. precompute_flows re-writes the
      # controller units it annotates with metadata[:flow_paths].
      if Woods.configuration.precompute_flows
        Rails.logger.info '[Woods] Precomputing request flows...'
        precompute_flows
      end

      write_dependency_graph
      write_graph_analysis
      write_manifest
      write_structural_summary
      capture_snapshot

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

      # Compute affected units. Files with no file_map entry are brand-new
      # (added since the last full extraction) — affected_by cannot see
      # them, so they get their own extraction pass below.
      affected_ids = @dependency_graph.affected_by(absolute_files)
      new_files = absolute_files.reject { |f| @dependency_graph.tracks_file?(f) }
      deleted_files = absolute_files.select do |f|
        @dependency_graph.tracks_file?(f) && !File.exist?(f)
      end
      Rails.logger.info(
        "[Woods] #{changed_files.size} changed files affect #{affected_ids.size} units " \
        "(#{new_files.size} not yet indexed, #{deleted_files.size} deleted)"
      )

      # Remove units whose source file was deleted — BEFORE re-extraction,
      # but AFTER affected_by, so the deleted unit's dependents (found via
      # its reverse edges) still get re-extracted below.
      affected_types = Set.new
      @removed_unit_ids = remove_deleted_file_units(deleted_files, affected_types: affected_types)
      affected_ids -= @removed_unit_ids

      # Re-extract affected units
      affected_ids.each do |unit_id|
        re_extract_unit(unit_id, affected_types: affected_types)
      end

      # Extract brand-new files as fresh units
      affected_ids += extract_new_files(new_files, affected_types: affected_types)

      # Regenerate type indexes for affected types
      affected_types.each do |type_key|
        regenerate_type_index(type_key)
      end

      # Update graph, manifest, and summary. No capture_snapshot here:
      # snapshots must hash the FULL unit set, and incremental runs only
      # re-extract affected units (@results stays empty) — capturing would
      # record a snapshot whose diff reports every unit as deleted.
      # Snapshots are captured on full extraction only.
      write_dependency_graph
      write_manifest(incremental: true)
      write_structural_summary
      if Woods.configuration.enable_snapshots
        Rails.logger.info '[Woods] Skipping snapshot capture — snapshots are captured on full extraction only'
      end

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
      begin
        Rails.application.eager_load!
      rescue NameError => e
        Rails.logger.warn "[Woods] eager_load! hit NameError: #{e.message}"
        Rails.logger.warn '[Woods] Falling back to per-directory eager loading'
        eager_load_extraction_directories
      end

      eager_load_lazy_roots
    end

    # Eager load autoloadable roots that eager_load! skips: app/views
    # (see LAZY_EAGER_LOAD_DIRS) plus any host-configured
    # extraction_eager_load_paths. Files that aren't managed by the main
    # autoloader (e.g. a plain-ERB app/views) or that fail to load are
    # skipped — extraction proceeds with whatever loaded.
    def eager_load_lazy_roots
      loader = Rails.autoloaders.main
      @lazy_load_skipped_files = []

      configured = Array(Woods.configuration&.extraction_eager_load_paths).map(&:to_s)
      (LAZY_EAGER_LOAD_DIRS + configured).uniq.each do |dir|
        path = Pathname.new(dir)
        path = Rails.root.join(dir) unless path.absolute?
        next unless path.directory?

        constantize_ruby_files_under(path, loader)
      end
    end

    # Load every Ruby file under +dir+ by constantizing the constant the
    # file is expected to define — Zeitwerk resolves the autoload, so the
    # class materializes for descendants-based extraction.
    #
    # Zeitwerk's eager_load_dir can NOT be used here — it silently no-ops
    # in both situations this method exists for: directories marked
    # do_not_eager_load (Rails marks every autoload-only path this way,
    # which is exactly what app/views is), and loaders that already
    # finished a full eager load (extraction runs right after eager_load!).
    #
    # @param dir [Pathname] Directory to load
    # @param loader [Zeitwerk::Loader, nil] The main autoloader (nil under
    #   classic autoloading, where constantize still resolves via const_missing)
    # @return [void]
    def constantize_ruby_files_under(dir, loader)
      Dir.glob(dir.join('**/*.rb').to_s).each do |file|
        expected_cpath_for(file, dir, loader)&.constantize
      rescue NameError, LoadError => e
        @lazy_load_skipped_files << file
        Rails.logger.warn "[Woods] Skipped #{file}: #{e.message}"
      rescue StandardError => e
        # Zeitwerk::Error — the file isn't managed by the main loader
        # (e.g. a stray .rb under a plain-ERB app/views). Not extractable.
        Rails.logger.debug { "[Woods] Skipped #{file}: #{e.class}: #{e.message}" }
      end
    end

    # Constant path a file is expected to define: Zeitwerk's own mapping
    # when available, else the plain convention (path relative to the
    # autoload root, camelized) — which is also how classic-mode
    # autoloading resolves it.
    #
    # @param file [String] Absolute path of a .rb file under +dir+
    # @param dir [Pathname] The autoload root being loaded
    # @param loader [Zeitwerk::Loader, nil]
    # @return [String, nil]
    def expected_cpath_for(file, dir, loader)
      return loader.cpath_expected_at(file) if loader.respond_to?(:cpath_expected_at)

      file.delete_prefix("#{dir}/").delete_suffix('.rb').camelize
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
              Rails.logger.warn "[Woods] Skipped #{file}: #{e.message}"
            end
          end
        rescue NameError, LoadError => e
          Rails.logger.warn "[Woods] Failed to eager load app/#{subdir}/: #{e.message}"
        end
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Extraction Strategies
    # ──────────────────────────────────────────────────────────────────────

    def extract_all_sequential
      EXTRACTORS.each do |type, extractor_class|
        Rails.logger.info "[Woods] Extracting #{type}..."
        start_time = Time.current

        extractor = extractor_class.new
        @extractors[type] = extractor
        units = extractor.extract_all

        @results[type] = units

        elapsed = Time.current - start_time
        Rails.logger.info "[Woods] Extracted #{units.size} #{type} in #{elapsed.round(2)}s"

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
      # duplicate compute_model_names calls without this warm-up. All four
      # derived caches must be warmed — `short_name_map` and
      # `short_names_regex` were added for the three-pass dependency
      # scanner and are reached from every extractor that calls
      # `scan_model_dependencies`.
      ModelNameCache.model_names
      ModelNameCache.model_names_regex
      ModelNameCache.short_name_map if ModelNameCache.respond_to?(:short_name_map)
      ModelNameCache.short_names_regex if ModelNameCache.respond_to?(:short_names_regex)

      results_mutex = Mutex.new
      threads = EXTRACTORS.map do |type, extractor_class|
        Thread.new do
          Rails.logger.info "[Woods] [Thread] Extracting #{type}..."
          start_time = Time.current

          extractor = extractor_class.new
          results_mutex.synchronize { @extractors[type] = extractor }

          units = extractor.extract_all

          elapsed = Time.current - start_time
          Rails.logger.info "[Woods] [Thread] Extracted #{units.size} #{type} in #{elapsed.round(2)}s"

          results_mutex.synchronize do
            @results[type] = units
          end
        rescue StandardError => e
          Rails.logger.error "[Woods] [Thread] #{type} failed: #{e.message}"
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

        Rails.logger.warn "[Woods] Deduplicated #{type}: dropped #{dropped} duplicate(s)" if dropped.positive?

        @results[type] = deduped
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Flow Precomputation
    # ──────────────────────────────────────────────────────────────────────

    def precompute_flows
      all_units = @results.values.flatten(1)
      precomputer = FlowPrecomputer.new(units: all_units, graph: @dependency_graph, output_dir: @output_dir.to_s)
      flow_map = precomputer.precompute
      rewrite_flow_annotated_units
      Rails.logger.info "[Woods] Precomputed #{flow_map.size} request flows"
    rescue StandardError => e
      Rails.logger.error "[Woods] Flow precomputation failed: #{e.message}"
    end

    # Precompute runs after write_results (FlowAssembler reads unit JSON
    # from disk), so units annotated in memory with metadata[:flow_paths]
    # must be re-written and their type index refreshed to pick up the
    # annotation.
    #
    # The index is rebuilt from the in-memory `units` (the authoritative
    # full-extraction `@results`), NOT from a disk glob: this is a full
    # extraction, the output dir is never wiped, and globbing would
    # resurrect stale unit files for app classes deleted since the last run.
    # (The incremental path, which only holds changed units in memory, still
    # rebuilds from disk via {#regenerate_type_index}.)
    def rewrite_flow_annotated_units
      @results.each do |type, units|
        annotated = units.select { |u| u.metadata[:flow_paths] }
        next if annotated.empty?

        type_dir = @output_dir.join(type.to_s)
        annotated.each do |unit|
          AtomicFile.write(
            type_dir.join(collision_safe_filename(unit.identifier)),
            json_serialize(unit.to_h)
          )
        end
        AtomicFile.write(
          type_dir.join('_index.json'),
          json_serialize(type_index_entries(units))
        )
      end
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
        FileUtils.mkdir_p(type_dir)

        units.each do |unit|
          AtomicFile.write(
            type_dir.join(collision_safe_filename(unit.identifier)),
            json_serialize(unit.to_h)
          )
        end

        # Also write a type index for fast lookups
        AtomicFile.write(
          type_dir.join('_index.json'),
          json_serialize(type_index_entries(units))
        )

        sweep_stale_unit_files(type, type_dir, units)
      end
    end

    # Delete per-unit JSON files left over from previous runs whose units no
    # longer exist (deleted or renamed app classes). The output dir is never
    # wiped between full extractions, so without this sweep woods:validate
    # reports expected-vs-found count drift forever, and the incremental
    # path's {#regenerate_type_index} (a disk glob) resurrects the stale
    # units into _index.json.
    #
    # Skipped when this run produced zero units of the type — a transient
    # extractor failure (extract_all_concurrent rescues to []) must not
    # wipe a previously good type directory.
    #
    # @param type [Symbol] Result type (plural EXTRACTORS key)
    # @param type_dir [Pathname] The type's output directory
    # @param units [Array<ExtractedUnit>] Units written this run
    # @return [void]
    def sweep_stale_unit_files(type, type_dir, units)
      return if SWEEP_EXEMPT_TYPES.include?(type) || units.empty?

      expected = units.to_set { |u| collision_safe_filename(u.identifier) }
      swept = 0

      Dir[type_dir.join('*.json').to_s].each do |file|
        basename = File.basename(file)
        next if basename == '_index.json' || expected.include?(basename)

        File.delete(file)
        swept += 1
      end

      Rails.logger.info "[Woods] Swept #{swept} stale #{type} unit file(s)" if swept.positive?
    end

    # Build the `_index.json` entry list for a set of in-memory units.
    # Shared by {#write_results} and {#rewrite_flow_annotated_units} so both
    # emit the index from the authoritative in-memory `@results` rather than
    # re-deriving it from disk.
    #
    # @param units [Array<ExtractedUnit>]
    # @return [Array<Hash>]
    def type_index_entries(units)
      units.map do |u|
        {
          identifier: u.identifier,
          file_path: u.file_path,
          namespace: u.namespace,
          estimated_tokens: u.estimated_tokens,
          chunk_count: u.chunks.size
        }
      end
    end

    def write_dependency_graph
      graph_data = @dependency_graph.to_h
      graph_data[:pagerank] = @dependency_graph.pagerank

      AtomicFile.write(
        @output_dir.join('dependency_graph.json'),
        json_serialize(graph_data)
      )
    end

    def write_graph_analysis
      return unless @graph_analysis

      enriched = @graph_analysis.merge(
        generated_at: Time.current.iso8601,
        graph_sha: Digest::SHA256.hexdigest(
          File.read(@output_dir.join('dependency_graph.json'))
        )
      )

      AtomicFile.write(
        @output_dir.join('graph_analysis.json'),
        json_serialize(enriched)
      )
    end

    def write_manifest(incremental: false)
      # Worktree-aware git provenance. In a linked worktree +.git+ is a file
      # pointing at the real git dir; when that dir is unreachable (e.g. an
      # unmounted host path inside a container) this resolves to "unknown"
      # rather than a stale GIT_BRANCH/GIT_SHA build arg. See GitProvenance (#137).
      provenance = GitProvenance.new(root: Rails.root).to_h

      # Incremental runs never populate @results — deriving counts from
      # memory would clobber a good manifest with zeros. Recompute from the
      # persisted per-type _index.json files instead.
      counts, total_chunks =
        if incremental
          persisted_counts
        else
          [@results.transform_values(&:size),
           @results.sum { |_, units| units.sum { |u| u.chunks.size } }]
        end

      manifest = {
        extracted_at: Time.current.iso8601,
        rails_version: Rails.version,
        ruby_version: RUBY_VERSION,

        # Counts by type
        counts: counts,

        # Total stats
        total_units: counts.values.sum,
        total_chunks: total_chunks,

        # Git provenance (branch/sha), or "unknown" when unresolvable
        git_sha: provenance[:git_sha],
        git_branch: provenance[:git_branch],

        # For change detection
        gemfile_lock_sha: gemfile_lock_sha,
        schema_sha: schema_sha
      }

      # Atomic (temp + fsync + rename): a live Index Server stats and
      # re-parses this exact file on every tool call (IndexAutoRefresh) —
      # a plain File.write could hand a concurrent reader a torn manifest.
      AtomicFile.write(
        @output_dir.join('manifest.json'),
        json_serialize(manifest)
      )
    end

    # Unit and chunk counts derived from the per-type _index.json files on
    # disk — the source of truth after an incremental run, where only the
    # affected units were re-extracted.
    #
    # @return [Array(Hash{Symbol => Integer}, Integer)] counts by type, total chunk count
    def persisted_counts
      counts = {}
      chunks = 0

      Dir[@output_dir.join('*/_index.json').to_s].each do |index_path|
        entries = JSON.parse(File.read(index_path))
        counts[File.basename(File.dirname(index_path)).to_sym] = entries.size
        chunks += entries.sum { |e| e['chunk_count'].to_i }
      rescue JSON::ParserError => e
        # An unreadable index silently drops that whole type from the manifest
        # counts — warn rather than undercount without a trace.
        type = File.basename(File.dirname(index_path))
        Rails.logger.warn("[Woods] Skipping unreadable #{type}/_index.json in manifest counts: #{e.message}")
        next
      end

      [counts, chunks]
    end

    # Capture a temporal snapshot after extraction completes.
    #
    # Reads the manifest and computes per-unit content hashes, then delegates
    # to the SnapshotStore for storage and diff computation. Requires
    # enable_snapshots and a valid git_sha in the manifest.
    #
    # @return [void]
    def capture_snapshot
      return unless Woods.configuration.enable_snapshots

      manifest_path = @output_dir.join('manifest.json')
      return unless manifest_path.exist?

      manifest = JSON.parse(File.read(manifest_path))
      # Snapshots are keyed on the commit SHA — an unresolvable provenance
      # ("unknown", see GitProvenance/#137) must not key or collide a snapshot.
      git_sha = manifest['git_sha']
      return if git_sha.nil? || git_sha == Woods::GitProvenance::UNKNOWN

      store = build_snapshot_store
      return unless store

      unit_hashes = @results.flat_map do |type, units|
        units.map do |unit|
          {
            'identifier' => unit.identifier,
            'type' => type.to_s,
            'source_hash' => Digest::SHA256.hexdigest(unit.source_code.to_s),
            'metadata_hash' => Digest::SHA256.hexdigest(unit.metadata.to_json),
            'dependencies_hash' => Digest::SHA256.hexdigest(unit.dependencies.to_json)
          }
        end
      end

      store.capture(manifest, unit_hashes)
      Rails.logger.info "[Woods] Snapshot captured for #{manifest['git_sha'][0..7]}"
    rescue StandardError => e
      Rails.logger.error "[Woods] Snapshot capture failed (#{e.class}): #{e.message}"
    end

    # Build a snapshot store, preferring SQLite with JSON file fallback.
    #
    # @return [Woods::Temporal::SnapshotStore, Woods::Temporal::JsonSnapshotStore, nil]
    def build_snapshot_store
      require 'sqlite3'
      require_relative 'db/migrator'
      require_relative 'temporal/snapshot_store'

      db_path = @output_dir.join('woods.sqlite3')
      db = SQLite3::Database.new(db_path.to_s)
      db.results_as_hash = true

      Db::Migrator.new(connection: db).migrate!
      Temporal::SnapshotStore.new(connection: db)
    rescue LoadError
      Rails.logger.info '[Woods] sqlite3 gem not available, using JSON snapshot store'
      require_relative 'temporal/json_snapshot_store'
      Temporal::JsonSnapshotStore.new(dir: @output_dir.to_s)
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

      AtomicFile.write(
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
          # Unit JSON has no estimated_tokens field (ExtractedUnit#to_h
          # doesn't emit one) — recompute it, or every unit of a type
          # touched by an incremental run would index as null.
          estimated_tokens: estimated_tokens_from(data),
          chunk_count: (data['chunks'] || []).size
        }
      end

      AtomicFile.write(
        type_dir.join('_index.json'),
        json_serialize(index)
      )
    end

    # Token estimate for a unit parsed back from JSON, mirroring
    # ExtractedUnit#estimated_tokens (see docs/TOKEN_BENCHMARK.md).
    #
    # @param data [Hash] Parsed unit JSON (string keys)
    # @return [Integer]
    def estimated_tokens_from(data)
      source = data['source_code']
      metadata = data['metadata'] || {}

      source_tokens = source ? TokenUtils.estimate_tokens(source) : 0
      metadata_tokens = metadata.any? ? TokenUtils.estimate_tokens(metadata.to_json) : 0
      source_tokens + metadata_tokens
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
      %w[db/schema.rb db/structure.sql].each do |path|
        full = Rails.root.join(path)
        return Digest::SHA256.file(full).hexdigest if full.exist?
      end
      nil
    end

    def json_serialize(data)
      if Woods.configuration.pretty_json
        JSON.pretty_generate(data)
      else
        JSON.generate(data)
      end
    end

    def log_summary
      total = @results.values.sum(&:size)
      chunks = @results.sum { |_, units| units.sum { |u| u.chunks.size } }

      Rails.logger.info '[Woods] ═══════════════════════════════════════════'
      Rails.logger.info '[Woods] Extraction Complete'
      Rails.logger.info '[Woods] ═══════════════════════════════════════════'
      @results.each do |type, units|
        Rails.logger.info "[Woods]   #{type}: #{units.size} units"
      end
      Rails.logger.info '[Woods] ───────────────────────────────────────────'
      Rails.logger.info "[Woods]   Total: #{total} units, #{chunks} chunks"
      Rails.logger.info "[Woods]   Output: #{@output_dir}"
      Rails.logger.info '[Woods] ═══════════════════════════════════════════'

      unless @lazy_load_skipped_files.empty?
        Rails.logger.warn '[Woods] ───────────────────────────────────────────'
        Rails.logger.warn(
          "[Woods]   #{@lazy_load_skipped_files.size} file(s) failed to load during " \
          'lazy eager-load and are NOT indexed:'
        )
        @lazy_load_skipped_files.each { |f| Rails.logger.warn "[Woods]     #{f}" }
      end

      all_warnings = @extractors.flat_map do |_type, ext|
        ext.respond_to?(:warnings) ? ext.warnings : []
      end

      return if all_warnings.empty?

      Rails.logger.warn '[Woods] ───────────────────────────────────────────'
      Rails.logger.warn "[Woods]   Warnings (#{all_warnings.size}):"
      all_warnings.each { |w| Rails.logger.warn "[Woods]     #{w}" }
    end

    # ──────────────────────────────────────────────────────────────────────
    # Incremental Re-extraction
    # ──────────────────────────────────────────────────────────────────────

    def re_extract_unit(unit_id, affected_types: nil)
      # Framework source only changes on version updates
      if unit_id.start_with?('rails/') || unit_id.start_with?('gems/')
        Rails.logger.debug "[Woods] Skipping framework re-extraction for #{unit_id}"
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

      persist_incremental_unit(unit, extractor_key)

      # Track which type was affected
      affected_types&.add(extractor_key)

      Rails.logger.info "[Woods] Re-extracted #{unit_id}"
    end

    # Register an incrementally (re-)extracted unit in the graph and write
    # its JSON. Registration happens BEFORE normalizing the path — the
    # graph's file_map stores absolute paths (affected_by matches changed
    # files against them), exactly as full extraction registers in Phase 1
    # and only normalizes in Phase 4.5. Unit JSON carries Rails.root-relative
    # paths; writing the raw absolute source_location would leak
    # container-absolute paths into the index after incremental runs.
    #
    # @param unit [ExtractedUnit] The freshly extracted unit
    # @param extractor_key [Symbol] Plural EXTRACTORS key (output subdirectory)
    # @return [void]
    def persist_incremental_unit(unit, extractor_key)
      @dependency_graph.register(unit)

      unit.file_path = normalize_file_path(unit.file_path)

      type_dir = @output_dir.join(extractor_key.to_s)
      FileUtils.mkdir_p(type_dir)
      AtomicFile.write(
        type_dir.join(collision_safe_filename(unit.identifier)),
        json_serialize(unit.to_h)
      )
    end

    # ──────────────────────────────────────────────────────────────────────
    # Incremental Removal of Deleted Files
    # ──────────────────────────────────────────────────────────────────────

    # Remove every unit registered against a source file that no longer
    # exists (B-065): delete its per-unit JSON, drop it from the dependency
    # graph (node, file-map, reverse indexes), and queue its type for index
    # regeneration. Scans graph nodes rather than the file_map alone — the
    # file_map holds one identifier per path, and co-located units (several
    # classes extracted from one file) must not survive as ghosts.
    #
    # @param deleted_files [Array<String>] Absolute paths that were changed
    #   but no longer exist on disk
    # @param affected_types [Set, nil] Accumulator for touched extractor keys
    # @return [Array<String>] Identifiers of removed units
    def remove_deleted_file_units(deleted_files, affected_types: nil)
      return [] if deleted_files.empty?

      deleted = deleted_files.to_set
      doomed = @dependency_graph.to_h[:nodes].filter_map do |unit_id, node|
        [unit_id, node] if deleted.include?(node[:file_path])
      end

      doomed.map do |unit_id, node|
        extractor_key = TYPE_TO_EXTRACTOR_KEY[node[:type]&.to_sym]
        delete_unit_file(unit_id, extractor_key)
        @dependency_graph.remove(unit_id)
        affected_types&.add(extractor_key) if extractor_key

        Rails.logger.info "[Woods] Removed #{unit_id} — source file deleted: #{node[:file_path]}"
        unit_id
      end
    end

    # Delete a removed unit's persisted JSON so the type-index rebuild
    # (which globs the type dir) drops it rather than resurrecting it.
    #
    # @param unit_id [String] Unit identifier
    # @param extractor_key [Symbol, nil] Plural EXTRACTORS key (output subdirectory)
    # @return [void]
    def delete_unit_file(unit_id, extractor_key)
      return unless extractor_key

      FileUtils.rm_f(@output_dir.join(extractor_key.to_s, collision_safe_filename(unit_id)))
    end

    # ──────────────────────────────────────────────────────────────────────
    # Incremental Extraction of New Files
    # ──────────────────────────────────────────────────────────────────────

    # Extract changed files that have no unit in the graph yet (brand-new
    # files added since the last full extraction). Deleted files are skipped
    # (nothing to extract, no unit to update); files that exist but can't be
    # mapped to any unit are recorded in {#unhandled_changed_files} so
    # callers can surface the coverage gap instead of dropping it silently.
    #
    # @param new_files [Array<String>] Absolute paths with no file_map entry
    # @param affected_types [Set, nil] Accumulator for touched extractor keys
    # @return [Array<String>] Identifiers of newly extracted units
    def extract_new_files(new_files, affected_types: nil)
      @unhandled_changed_files = []
      extracted = []

      new_files.each do |file_path|
        next unless File.file?(file_path)
        next if @dependency_graph.tracks_file?(file_path)

        unit = extract_new_file(file_path, affected_types: affected_types)
        if unit
          extracted << unit.identifier
        else
          @unhandled_changed_files << file_path
        end
      end

      unless @unhandled_changed_files.empty?
        Rails.logger.warn(
          "[Woods] #{@unhandled_changed_files.size} changed file(s) could not be mapped to any unit " \
          '— run a full extraction (woods:extract) to index them:'
        )
        @unhandled_changed_files.each { |f| Rails.logger.warn "[Woods]   #{f}" }
      end

      extracted
    end

    # Extract a single brand-new file as a fresh unit. The unit type is
    # inferred from the file's path (NEW_FILE_TYPE_PATTERNS); class-based
    # extractors resolve the class via Zeitwerk's expected constant path
    # (with a conventional camelize fallback).
    #
    # @param file_path [String] Absolute path to the new file
    # @param affected_types [Set, nil] Accumulator for touched extractor keys
    # @return [ExtractedUnit, nil] The extracted unit, or nil when the file
    #   couldn't be mapped to a unit
    def extract_new_file(file_path, affected_types: nil)
      type = detect_new_file_type(file_path)
      return nil unless type

      klass = constant_for_new_file(file_path) if CLASS_BASED.key?(type)
      return nil if CLASS_BASED.key?(type) && klass.nil?

      # A new file under a component root may be a ViewComponent rather
      # than a Phlex component — route it to the matching extractor.
      type = :view_component if type == :component && view_component_descendant?(klass)

      extractor_key = TYPE_TO_EXTRACTOR_KEY[type]
      extractor = EXTRACTORS[extractor_key]&.new
      return nil unless extractor

      unit = if (method = CLASS_BASED[type])
               extractor.public_send(method, klass)
             elsif (method = FILE_BASED[type])
               extractor.public_send(method, file_path)
             elsif GRAPHQL_TYPES.include?(type)
               extractor.extract_graphql_file(file_path)
             end
      return nil unless unit

      persist_incremental_unit(unit, extractor_key)
      affected_types&.add(extractor_key)

      Rails.logger.info "[Woods] Extracted new unit #{unit.identifier} from #{file_path}"
      unit
    rescue StandardError => e
      Rails.logger.error "[Woods] Failed to extract new file #{file_path}: #{e.message}"
      nil
    end

    # Infer the unit type for a file that isn't in the graph yet.
    #
    # @param file_path [String] Absolute file path
    # @return [Symbol, nil] Unit type, or nil when no pattern matches
    def detect_new_file_type(file_path)
      relative = normalize_file_path(file_path)
      # Paths outside Rails.root come back unchanged (still absolute) and
      # can't match the root-relative patterns.
      return nil if relative.nil? || Pathname.new(relative).absolute?

      match = NEW_FILE_TYPE_PATTERNS.find { |(pattern, _type)| relative.match?(pattern) }
      match && match[1]
    end

    # Resolve the class a brand-new file is expected to define, preferring
    # Zeitwerk's own path→constant mapping over naming conventions.
    #
    # @param file_path [String] Absolute file path
    # @return [Class, Module, nil] The loaded constant, or nil
    def constant_for_new_file(file_path)
      name = zeitwerk_cpath_for(file_path) || conventional_cpath_for(file_path)
      return nil unless name

      begin
        name.constantize
      rescue NameError, LoadError
        nil
      end
    end

    # @param file_path [String] Absolute file path
    # @return [String, nil] Zeitwerk's expected constant path, or nil when
    #   unsupported (Zeitwerk < 2.6.1) or the file isn't managed by the loader
    def zeitwerk_cpath_for(file_path)
      loader = Rails.autoloaders.main
      return nil unless loader.respond_to?(:cpath_expected_at)

      loader.cpath_expected_at(file_path)
    rescue StandardError
      nil
    end

    # Conventional path→constant fallback: strip the app/<subdir>/ prefix
    # and camelize (app/models/library/book.rb → Library::Book).
    #
    # @param file_path [String] Absolute file path
    # @return [String, nil]
    def conventional_cpath_for(file_path)
      relative = normalize_file_path(file_path)
      return nil unless relative&.start_with?('app/')

      relative.sub(%r{\Aapp/[^/]+/}, '').delete_suffix('.rb').camelize
    end

    # @param klass [Class, Module, nil]
    # @return [Boolean] true when the class is a ViewComponent subclass
    def view_component_descendant?(klass)
      defined?(ViewComponent::Base) && klass.is_a?(Class) && klass < ViewComponent::Base
    end
  end
end
