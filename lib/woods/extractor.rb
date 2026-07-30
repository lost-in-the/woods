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
require_relative 'change_set'
require_relative 'generation'
require_relative 'path_dispatcher'

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
      # RailsSourceExtractor emits BOTH :rails_source and :gem_source units
      # into the rails_source/ output directory. Without this entry the
      # wholesale-replacement path could not prune a stale gem_source unit
      # ({EXTRACTOR_KEY_TO_TYPES} would not list the type) and {#remove_unit}
      # could not resolve its JSON file on disk (#169) — the GraphQL history
      # in CLAUDE.md is the cautionary tale for an extractor whose emitted
      # types are not all mapped.
      gem_source: :rails_source,
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

    # Unit types each extractor owns — the inverse of {TYPE_TO_EXTRACTOR_KEY}.
    #
    # Wholesale replacement of an extractor's output has to know every type it
    # can produce, and one extractor can own several (`graphql` covers types,
    # mutations, resolvers and queries).
    #
    # @return [Hash{Symbol => Array<Symbol>}]
    EXTRACTOR_KEY_TO_TYPES = TYPE_TO_EXTRACTOR_KEY.each_with_object({}) do |(type, key), map|
      (map[key] ||= []) << type
    end.freeze

    # Class-based extractors, which discover their units by walking runtime
    # descendants rather than by globbing files. The incremental path
    # reconciles each extractor's `discoverable_classes` against the
    # identifiers already in the graph, so a class added since the last
    # extraction is found without having to guess a constant name from a
    # path (#164, gap 1).
    #
    # `reconcile_removals: false` opts an entry out of the removal half. Only
    # GraphQL sets it, and the reason is that its unit type is produced by two
    # independent discovery mechanisms whose union is the truth: runtime schema
    # introspection *and* a static file pass over `app/graphql`. Every other
    # entry here owns its type outright, which is what makes
    # "in the graph but not in `discoverable_classes`" mean "deleted".
    #
    # For GraphQL that inference is wrong twice over. Without graphql-ruby
    # loaded the runtime set is empty, so removal would delete every GraphQL
    # unit in the index; with it loaded, a type defined in a file but not
    # attached to the schema is legitimately absent from the type map, so
    # removal would delete units a full extraction still emits. Additions are
    # safe in both worlds — they are exactly the runtime-only types no changed
    # path can dispatch to, which is the #167 divergence.
    #
    # The consequence, stated so it does not read as a bug later: a runtime-only
    # type that *disappears* is never removed by an incremental run. It survives
    # until a full extraction rebuilds the type. Confirmed against a live schema
    # during review — probe units outlived deletion of the file that defined
    # them. That is the cost of the opt-out, and it is the right side to err on:
    # a stale unit is recoverable by one full run, whereas the removal half
    # would delete units a full extraction still emits.
    #
    # @return [Hash{Symbol => Hash}] extractor key => { type:, method: }
    CLASS_BASED_DISCOVERY = {
      models: { type: :model, method: :extract_model },
      controllers: { type: :controller, method: :extract_controller },
      mailers: { type: :mailer, method: :extract_mailer },
      components: { type: :component, method: :extract_component },
      view_components: { type: :view_component, method: :extract_component },
      action_cable_channels: { type: :action_cable_channel, method: :extract_channel },
      # Additions only — see `reconcile_removals: false`. GraphQL is the one
      # entry whose discovery set is not authoritative for its unit type
      # (#167).
      # `types:` because this extractor emits four unit types, not one:
      # `classify_runtime_type` returns :graphql_type, :graphql_mutation,
      # :graphql_resolver or :graphql_query. Declaring only :graphql_type made
      # `known` miss the others — the schema's query root is always in
      # `Schema.types` and classifies as :graphql_query — so they were
      # re-"discovered" and re-added on *every* incremental run. That leaves
      # `touched` non-empty on a genuine no-op, which rewrites the manifest and
      # bumps the generation each cycle: the #164 gap-4 symptom, reintroduced.
      graphql: { type: :graphql_type, types: GRAPHQL_TYPES,
                 method: :extract_from_runtime_type, reconcile_removals: false }
    }.freeze

    # Extractors with no per-file entry point: they scan the whole app (or
    # introspect the whole runtime) in one pass, so an incremental run
    # replaces their output wholesale rather than per unit. Before #164
    # these types were simply skipped by incremental runs while
    # `config/routes.rb` still triggered one — the run rewrote the manifest,
    # zeroing the staleness clock, without updating the data.
    #
    # @return [Hash{Symbol => Symbol}] extractor key => unit type
    WHOLE_APP_EXTRACTORS = {
      routes: :route,
      middleware: :middleware,
      engines: :engine,
      scheduled_jobs: :scheduled_job,
      state_machines: :state_machine,
      factories: :factory,
      events: :event,
      # DatabaseViewExtractor keeps only the highest `_vNN` of each Scenic
      # view, so its unit set is a function of the whole directory rather
      # than of each file independently: dispatching db/views/foo_v01.sql to
      # the per-file method would index a version a full extraction drops.
      database_views: :database_view,
      # Framework/gem sources are a function of the installed dependency set,
      # so `Gemfile.lock` is their trigger path (#169). Before this the only
      # incremental writer was `woods:extract_framework`, which hand-wrote
      # JSON around the whole pipeline — no AtomicFile, no _index.json, no
      # manifest counts, no lock, no generation bump — and its output then
      # sat stale forever. The value here names the primary unit type, like
      # every other entry; the extractor also owns :gem_source, and
      # {EXTRACTOR_KEY_TO_TYPES} (which wholesale replacement consults) lists
      # both. Participation is gated by `include_framework_sources` — see
      # {#skip_by_configuration?}.
      rails_source: :rails_source
    }.freeze

    # Extractors whose output embeds the route table, and which therefore go
    # stale when routes change even though none of their own files did.
    #
    # ControllerExtractor writes each action's routes into unit metadata and
    # into the action chunks; everything that includes `RouteHelperResolver`
    # resolves `_path`/`_url` references into navigation edges against the
    # same table. The dependency graph can't express this — a route unit
    # depends *on* its controller, so walking dependents from
    # `config/routes.rb` never reaches it — so the relationship is declared
    # here instead and these types are re-extracted wholesale whenever the
    # route set is re-run (#164).
    #
    # @return [Array<Symbol>] extractor keys
    ROUTE_CONSUMER_EXTRACTORS = %i[
      controllers
      mailers
      components
      view_components
      view_templates
    ].freeze

    attr_reader :output_dir, :dependency_graph

    def initialize(output_dir: nil)
      @output_dir = Pathname.new(output_dir || Rails.root.join('tmp/woods'))
      @dependency_graph = DependencyGraph.new
      @results = {}
      @extractors = {}
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

      # Rebuild the graph from deduped results. #164 gave DependencyGraph
      # `#remove`/`#unregister`, so surgical removal is now possible — but a
      # full extraction has just registered every unit including duplicates,
      # and rebuilding from the deduped set is both cheaper and less
      # error-prone than unwinding registrations one at a time.
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

      # Phase 5.1: Sweep unit files no current unit accounts for (#177). Must
      # run after write_results — the just-written set is what defines
      # "legitimate" — and belongs to the full path only; the incremental path
      # deletes through the graph instead. See {#sweep_orphaned_unit_files}.
      sweep_orphaned_unit_files

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
      publish_generation('full')

      log_summary

      @results
    end

    # ══════════════════════════════════════════════════════════════════════
    # Incremental Extraction
    # ══════════════════════════════════════════════════════════════════════

    # Extract only units affected by changed files.
    #
    # Used for incremental indexing in CI and by any caller that maintains a
    # live index. The goal is equivalence: after this returns, the on-disk
    # index should match what a cold full extraction of the same tree would
    # have produced.
    #
    # The run proceeds in a fixed order, and the order matters:
    #
    # 1. Blast radius is computed against the *pre-change* graph, so
    #    dependents of a file that just disappeared still get re-extracted.
    # 2. Known units in the blast radius are re-extracted.
    # 3. Changed paths the index has never seen are dispatched to an
    #    extractor by path ({PathDispatcher}).
    # 4. Class-based types are reconciled against their runtime discovery
    #    sets, catching classes added since the last extraction.
    # 5. Whole-app extractors whose trigger paths changed are re-run and
    #    their type replaced wholesale.
    # 6. Units whose source file has vanished are pruned last, so anything
    #    resurrected by steps 2–5 against a deleted file is swept in the
    #    same run rather than surviving as a ghost until the next one.
    #
    # @param changed_files [Array<String>] List of changed file paths
    # @return [Array<String>] Identifiers of units re-extracted, added, or removed
    def extract_changed(changed_files)
      prepare_incremental_run

      change_set = ChangeSet.new(paths: changed_files, root: Rails.root)
      affected_types = Set.new

      # Blast radius from the pre-change graph.
      affected_ids = @dependency_graph.affected_by(change_set.absolute_paths)
      Rails.logger.info "[Woods] #{change_set.size} changed files affect #{affected_ids.size} units"

      touched = reconcile_changed_paths(change_set, affected_types)

      (affected_ids - touched.to_a).each do |unit_id|
        touched.add(unit_id) if re_extract_unit(unit_id, affected_types: affected_types)
      end

      touched.merge(reconcile_class_based_types(affected_types))
      touched.merge(rerun_whole_app_extractors(change_set, affected_types))
      pruned = prune_vanished_units(change_set, affected_types)
      touched.merge(pruned)

      # Reconcile once more, because pruning can un-know a class the first pass
      # skipped. A class-based file moved between autoload directories with its
      # constant unchanged is still registered under the old path when
      # reconciliation runs, so it looks known and is not re-extracted; the prune
      # that follows then removes it for its vanished path. One pass leaves the
      # unit missing until some later run happens to notice — this pass closes it
      # in the same run. Idempotent when nothing was pruned: the discovery set is
      # compared against the graph, so an already-registered class is skipped.
      #
      # `except:` is what keeps it from undoing a *deletion*. Without a reload,
      # a constant outlives the file that defined it — so deleting
      # `app/models/user.rb` prunes `User` and then this pass finds `User` still
      # in `ActiveRecord::Base.descendants` and re-registers it against a path
      # that no longer exists. From then on nothing can remove it: the sweep
      # excludes class-based units and no future change set names that path
      # again. A resident daemon processing a batch before its reload hits this
      # every time.
      touched.merge(reconcile_class_based_types(affected_types, except: pruned))

      finalize_incremental_unit_json(affected_types)

      # Regenerate type indexes for affected types
      affected_types.each do |type_key|
        regenerate_type_index(type_key)
      end

      finalize_incremental_run(touched)

      touched.to_a
    end

    # ══════════════════════════════════════════════════════════════════════
    # Targeted Refresh
    # ══════════════════════════════════════════════════════════════════════

    # Re-run one or more extractors wholesale against the already-booted app,
    # replacing every unit of the types they own.
    #
    # This is the escape hatch for the unit types that have no per-file entry
    # point — routes are derived from `Rails.application.routes`, the
    # middleware unit from the live stack, events from a two-pass scan of all
    # of `app/`. Incremental runs reach them by trigger path
    # ({PathDispatcher.whole_app_rules}); this reaches them by name, for a
    # caller that already knows what went stale: a resident process that just
    # reloaded, a `woods:refresh` invocation after editing `config/routes.rb`,
    # a deploy hook after a dependency bump.
    #
    # "Full extraction required for these types" was always a cold-boot
    # artifact rather than something inherent: in a booted process re-running
    # one extractor is seconds.
    #
    # Any extractor key works, not just the whole-app ones — `refresh(:models)`
    # is a legitimate way to re-derive every model after a schema change.
    #
    # @example After editing config/routes.rb
    #   Woods::Extractor.new(output_dir: "tmp/woods").refresh(:routes)
    #
    # @param keys [Array<Symbol>] keys into {EXTRACTORS}
    # @return [Hash] `{ types:, touched:, unknown: }` — the extractors that
    #   ran, the identifiers written or removed, and any key that isn't an
    #   extractor
    # @raise [ArgumentError] when no recognized key is given
    def refresh(*keys)
      keys = Array(keys).flatten.map(&:to_sym).uniq
      known, unknown = keys.partition { |key| EXTRACTORS.key?(key) }
      raise ArgumentError, "No known extractor in #{keys.inspect}" if known.empty?

      known += ROUTE_CONSUMER_EXTRACTORS if known.include?(:routes)
      known.uniq!

      prepare_incremental_run
      affected_types = Set.new
      touched = known.each_with_object(Set.new) do |key, acc|
        acc.merge(replace_type_wholesale(key, affected_types))
      end

      finalize_incremental_unit_json(affected_types)
      affected_types.each { |type_key| regenerate_type_index(type_key) }
      finalize_incremental_run(touched, reason: "refresh:#{known.sort.join(',')}")

      { types: known, touched: touched.to_a, unknown: unknown }
    end

    private

    # Load the persisted graph and reset the per-run bookkeeping that the
    # incremental helpers read. Shared by {#extract_changed} and {#refresh};
    # calling either without this leaves `@dependents_dirty` and
    # `@incremental_written` holding a previous run's state.
    #
    # @return [void]
    def prepare_incremental_run
      graph_path = @output_dir.join('dependency_graph.json')
      @dependency_graph = DependencyGraph.from_h(JSON.parse(File.read(graph_path))) if graph_path.exist?

      ModelNameCache.reset!
      safe_eager_load!

      @dependents_dirty = Set.new
      @incremental_written = {}
      @incremental_extractors = nil
      @active_record_names = nil
    end

    # Write the graph and the derived artifacts after an incremental run.
    #
    # The manifest is rewritten only when the run actually changed something.
    # `staleness_seconds` is derived from the manifest timestamp, so touching
    # it after a no-op run reports the index as freshly synced when nothing
    # was re-read — the misleading half of #164 gap 4. The graph is written
    # unconditionally: it is cheap, idempotent, and carries the PageRank
    # recomputation.
    #
    # No `capture_snapshot` here: snapshots must hash the FULL unit set, and
    # incremental runs only hold changed units in memory — capturing would
    # record a snapshot whose diff reports every other unit as deleted.
    #
    # @param touched [Set<String>] identifiers added, re-extracted, or removed
    # @param reason [String] what produced this run, recorded on the generation
    #   so `woods_status` can distinguish a targeted refresh from a file-driven
    #   incremental run — they have different blast radii and an operator
    #   reading "incremental" after a `woods:refresh[routes]` is being misled
    # @return [void]
    def finalize_incremental_run(touched, reason: 'incremental')
      write_dependency_graph

      if touched.empty?
        Rails.logger.info '[Woods] Incremental run changed nothing — leaving manifest timestamp untouched'
        return
      end

      write_incremental_graph_analysis
      write_manifest(incremental: true)
      write_structural_summary
      publish_generation(reason)

      return unless Woods.configuration.enable_snapshots

      Rails.logger.info '[Woods] Skipping snapshot capture — snapshots are captured on full extraction only'
    end

    # Publish a new generation — the last write of any successful run.
    #
    # Every extraction mode does this, so a long-lived reader can detect that
    # the index moved without stat-ing the whole directory, whatever produced
    # the change: a full run, an incremental run, a targeted refresh, or the
    # watch daemon. Ordering is the contract: the generation goes last, so a
    # reader that sees generation N knows N's files are already on disk. A run
    # that raised, or that changed nothing, never reaches this.
    #
    # @param reason [String] what produced this generation
    # @return [void]
    def publish_generation(reason)
      Generation.new(output_dir: @output_dir).bump!(reason: reason)
    rescue StandardError => e
      # A failed bump must not fail the extraction that produced a perfectly
      # good index. But "readers keep their current view until the next run" is
      # too comfortable a way to put it: the generation *is* the freshness
      # contract, so readers keep serving the old index for as long as the
      # cause persists, and the next incremental may be a no-op that bumps
      # nothing either. Error, not warn — and `Watch::Daemon` cross-checks that
      # the number actually moved so the daemon reports degraded rather than
      # running.
      Rails.logger.error "[Woods] Could not publish generation: #{e.message}"
    end

    # Recompute graph_analysis.json after an incremental graph write.
    #
    # Structural analysis (orphans, hubs, cycles, bridges) is derived purely
    # from the graph, so leaving it at the last full extraction's values let
    # it drift continuously between full runs (#164 gap 5).
    #
    # @return [void]
    def write_incremental_graph_analysis
      @graph_analysis = GraphAnalyzer.new(@dependency_graph).analyze
      write_graph_analysis
    rescue StandardError => e
      Rails.logger.error "[Woods] Incremental graph analysis failed: #{e.message}"
    end

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
      # Recorded because it decides whether the runtime discovery sets are
      # *complete*. On the fallback path they are known-partial — whole
      # directories may have failed to load — and treating "absent from
      # descendants" as "deleted" would then erase live units by the type.
      # See {#stale_class_based_units}.
      @eager_load_complete = true
    rescue NameError => e
      Rails.logger.warn "[Woods] eager_load! hit NameError: #{e.message}"
      Rails.logger.warn '[Woods] Falling back to per-directory eager loading'
      @eager_load_complete = false
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

    # Should this extractor be skipped under the current configuration?
    #
    # `include_framework_sources` (default: true — see
    # docs/CONFIGURATION_REFERENCE.md) was documented and consumed by nothing
    # (#169). It now gates both automatic paths at once: the full-run pass
    # over {EXTRACTORS} and the `Gemfile.lock` whole-app trigger
    # ({#rerun_whole_app_extractors}). The {PathDispatcher} rule itself stays
    # ungated — rules are memoized per-process while configuration is not,
    # and `relevant?` stays correct either way because `Gemfile.lock` already
    # triggers :engines and :middleware — so the gate sits where the
    # extractor would actually run. Gating only one side would either extract
    # units a knob-off full run does not produce (a phantom `touched` cycle
    # bumping the generation) or leave a knob-on host with framework sources
    # that never refresh on a dependency bump.
    #
    # A by-name {#refresh} (and its `woods:extract_framework` alias) is
    # deliberately NOT gated: the knob controls automatic participation, and
    # the explicit refresh is the escape hatch for hosts that want framework
    # sources on demand without paying for them every run.
    #
    # @param key [Symbol] key into {EXTRACTORS}
    # @return [Boolean]
    def skip_by_configuration?(key)
      key == :rails_source && !Woods.configuration.include_framework_sources
    end

    def extract_all_sequential
      EXTRACTORS.each do |type, extractor_class|
        next if skip_by_configuration?(type)

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
      active = EXTRACTORS.reject { |type, _| skip_by_configuration?(type) }
      threads = active.map do |type, extractor_class|
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
    # Write a unit's JSON, unless the bytes on disk are already exactly that.
    #
    # A routes change replaces every `ROUTE_CONSUMER_EXTRACTORS` type wholesale
    # — on a production-shaped host that measured 1,707 units, roughly a quarter
    # of the index — and almost all of them re-serialize to the bytes already
    # there. `AtomicFile.write` is a tempfile plus an fsync plus a rename each
    # time, so the fsync is the cost being avoided here; the comparison read is
    # cheaper than the write it replaces.
    #
    # Only the *write* is skipped. Graph registration, the dependents marking
    # and `@incremental_written` all still happen for every unit, because those
    # are what equivalence and the git-enrichment pass depend on — skipping any
    # of them would make an unchanged unit differ from a full extraction.
    #
    # Compared as bytes: `AtomicFile.write` is binmode, and the encoding a read
    # comes back tagged with depends on the process's default external encoding
    # (US-ASCII under `LANG=C`, which is where the daemon runs).
    #
    # @param path [Pathname] destination
    # @param unit [ExtractedUnit] unit to serialize
    # @return [void]
    def write_unit_file(path, unit)
      payload = json_serialize(unit.to_h)
      return if identical_on_disk?(path, payload)

      AtomicFile.write(path, payload)
    end

    # The serialized `extracted_at` scalar as {ExtractedUnit#to_h} +
    # {#json_serialize} emit it, compact or pretty. `Time#iso8601` produces
    # exactly this value shape — no fractional seconds, `Z` or a `±hh:mm`
    # offset — and `spec/extracted_unit_spec.rb` pins that, so a change to the
    # stamp's shape fails a spec instead of quietly un-matching this mask.
    # The value constraint is what keeps the mask honest against user code: a
    # bare `"extracted_at":` cannot occur inside any JSON *string* value
    # (interior quotes serialize as `\"`), so only a real JSON key can match,
    # and only when it holds a timestamp — which no extractor emits below the
    # top level.
    EXTRACTED_AT_SCALAR =
      /("extracted_at":\s*")\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})(?=")/
    # An implementation detail of the byte comparison, not part of the
    # extractor's surface (`private` does not scope constants).
    private_constant :EXTRACTED_AT_SCALAR

    # @return [Boolean] true when the file already holds exactly these bytes,
    #   the `extracted_at` stamp aside
    def identical_on_disk?(path, payload)
      return false unless File.exist?(path)

      mask_extracted_at(AtomicFile.read(path).b) == mask_extracted_at(payload.b)
    rescue StandardError
      # An unreadable or half-written file is not a match; fall through and
      # rewrite it.
      false
    end

    # Blank the `extracted_at` value so the byte comparison ignores it.
    #
    # {ExtractedUnit#to_h} stamps `extracted_at: Time.now.iso8601` on every
    # serialization, so compared raw the two sides *always* differed across
    # runs and the skip was inert (#208): every write did the comparison read
    # and then paid the fsync anyway. Masked with a regex rather than parsed,
    # because a JSON parse of both sides would cost more than the write being
    # avoided. A skipped write leaves the older stamp on disk deliberately —
    # the equivalence oracle (`spec/support/index_comparison.rb`) lists
    # `extracted_at` in `VOLATILE_UNIT_KEYS`: "a unit an incremental run
    # correctly left alone keeps an older stamp".
    #
    # @param bytes [String] serialized unit JSON, binary-tagged (`.b`) — the
    #   ASCII-only pattern matches bytewise regardless of the content's
    #   original encoding
    # @return [String] the bytes with the stamp's value removed
    def mask_extracted_at(bytes)
      bytes.gsub(EXTRACTED_AT_SCALAR, '\1')
    end

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
      end
    end

    # Delete unit JSON files in the just-written type directories that this
    # full run did not write (#177).
    #
    # A full extraction never wipes the output directory —
    # {#setup_output_directory} only mkdir_p's — so extracting into a
    # directory that saw a different version of the app left the previous
    # run's `<Unit>_<digest>.json` files behind. The manifest and the freshly
    # written `_index.json` were correct, but the NEXT incremental run's
    # {#regenerate_type_index} rebuilds the index from a disk glob of the type
    # dir, resurrecting every orphan into the listed index, and
    # {#persisted_counts} then writes the inflated counts into the manifest —
    # orphans became listed, retrievable-by-listing units the graph knows
    # nothing about. On a full run the in-memory `@results` are authoritative
    # — the same argument {#rewrite_flow_annotated_units} makes for refusing
    # the disk glob — so a unit file no current unit accounts for is stale by
    # definition and is removed here.
    #
    # The boundary is deliberately narrow:
    #
    # * Only the per-type directories this run produced — `@results` keys —
    #   are entered. When `include_framework_sources` gates rails_source out
    #   of the run ({#skip_by_configuration?}), `@results` holds no
    #   `:rails_source` key, so a knob-off full run leaves explicitly
    #   extracted framework units (`woods:extract_framework`) alone — the
    #   #169 preservation decision. Nothing outside those directories is
    #   reachable: manifest, graph, generation, `woods.json`, `dumps/`,
    #   `flows/` and the lock/status files all live in the output root or in
    #   directories no extractor key names.
    # * Only `*.json` directly inside a type dir is considered, and
    #   `_index.json` is always kept. Non-JSON files and subdirectories are
    #   never touched.
    # * Legitimate names are exactly what {#write_results} just wrote —
    #   {FilenameUtils#collision_safe_filename} over the type's deduped units
    #   (which covers every unit type the extractor emits: gem_source shares
    #   `@results[:rails_source]`). Legacy {FilenameUtils#safe_filename} names
    #   carry no digest suffix, so they never match a current name and are by
    #   definition orphans of a pre-collision-safe run.
    #
    # The incremental path deliberately has no counterpart: it holds only
    # changed units in memory, so "not in memory" means nothing there —
    # deletion on that path is driven by the graph and the change set
    # ({#prune_vanished_units}, {#remove_replaced_units}).
    #
    # @return [void]
    def sweep_orphaned_unit_files
      @results.each do |type, units|
        type_dir = @output_dir.join(type.to_s)
        next unless type_dir.directory?

        keep = units.to_set { |unit| collision_safe_filename(unit.identifier) }
        keep << '_index.json'

        orphans = Dir[type_dir.join('*.json').to_s].reject { |file| keep.include?(File.basename(file)) }
        next if orphans.empty?

        orphans.each { |file| FileUtils.rm_f(file) }
        Rails.logger.info "[Woods] Swept #{orphans.size} orphaned unit file(s) from #{type}/"
      end
    rescue StandardError => e
      # The extraction itself already succeeded; aborting the run over cleanup
      # would trade orphaned files for a lost index. Error, not warn: the
      # files this leaves behind are exactly what the next incremental run's
      # disk glob resurrects.
      Rails.logger.error "[Woods] Orphaned-unit sweep failed: #{e.message}"
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
    # `JSON.generate`, not `Hash#to_json`: with ActiveSupport loaded the
    # latter applies HTML-safe escaping, rendering `>` as `\\u003e` — six
    # characters where the file on disk has one. A model with
    # `scope :recent, -> { ... }` in its metadata therefore estimated one
    # token higher here than {ExtractedUnit#estimated_tokens} did over the
    # same content, so a full and an incremental run disagreed on that unit's
    # `_index.json` entry (#164). Both sides now measure the serialization
    # {#json_serialize} actually writes.
    #
    # @param data [Hash] Parsed unit JSON (string keys)
    # @return [Integer]
    def estimated_tokens_from(data)
      source = data['source_code']
      metadata = data['metadata'] || {}

      source_tokens = source ? TokenUtils.estimate_tokens(source) : 0
      metadata_tokens = metadata.any? ? TokenUtils.estimate_tokens(JSON.generate(metadata)) : 0
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

    # Extractor instances are reused across a single incremental run, the way
    # full extraction uses one instance per type. Several of them do real
    # setup work in `initialize` (route-helper maps, routes maps), so a fresh
    # instance per file would make an N-file change N times more expensive.
    #
    # @param key [Symbol] key into {EXTRACTORS}
    # @return [Object, nil] the memoized extractor instance
    def extractor_for(key)
      @incremental_extractors ||= {}
      return @incremental_extractors[key] if @incremental_extractors.key?(key)

      @incremental_extractors[key] = EXTRACTORS[key]&.new
    rescue StandardError => e
      Rails.logger.warn "[Woods] Could not build #{key} extractor: #{e.message}"
      @incremental_extractors[key] = nil
    end

    # ActiveRecord model names, needed by PoroExtractor to tell a plain class
    # under app/models apart from a persisted model. Computed once per run.
    #
    # @return [Set<String>]
    def active_record_names
      @active_record_names ||=
        if defined?(ActiveRecord::Base)
          ActiveRecord::Base.descendants.filter_map(&:name).to_set
        else
          Set.new
        end
    end

    # Re-extract every file-based unit defined by the changed paths that still
    # exist on disk, and prune the ones those paths no longer define.
    #
    # This is the fix for #164 gap 1 (a path the index has never seen routed
    # nowhere, so new files were silently ignored) and the per-path half of
    # gap 3 (a file that defines several units — a `.rake` file with multiple
    # tasks, an i18n YAML — could only ever resolve to one identifier).
    # Reconciling the whole path at once means a task deleted from a
    # multi-task file is removed rather than left behind.
    #
    # Removal is scoped to the unit types the matching rules could have
    # produced, so a class-based unit sharing the path (the `User` model unit
    # for `app/models/user.rb`) is never collaterally deleted here.
    #
    # @param change_set [ChangeSet]
    # @param affected_types [Set<Symbol>] out-param of touched extractor keys
    # @return [Set<String>] identifiers written or removed
    def reconcile_changed_paths(change_set, affected_types)
      dispatcher = PathDispatcher.new
      touched = Set.new

      change_set.existing_paths.each do |absolute_path|
        rules = dispatcher.file_rules_for(change_set.relativize(absolute_path))
        next if rules.empty?

        produced = Set.new
        # A rule whose extraction *raised* tells us nothing about what the path
        # defines, so it must not license pruning what the path defined before.
        raised = false
        rules.each do |rule|
          units = extract_with_rule(rule, absolute_path)
          if units.nil?
            raised = true
            next
          end

          produced.merge(units.map(&:identifier))
          touched.merge(register_and_write(rule.extractor_key, units, affected_types))
        end

        next if raised

        touched.merge(
          prune_path_leftovers(absolute_path, rules, produced, affected_types)
        )
      end

      touched
    end

    # Run one {PathDispatcher::Rule} against one file.
    #
    # @param rule [PathDispatcher::Rule]
    # @param absolute_path [String]
    # @return [Array<ExtractedUnit>, nil] the units the path defines, or nil
    #   when the attempt says nothing about what it defines (see the rescue)
    def extract_with_rule(rule, absolute_path)
      extractor = extractor_for(rule.extractor_key)
      # nil, not [] — the same distinction the rescue below defends (#198).
      # {#extractor_for} rescues a raising *constructor* and memoizes nil, and
      # nil fails the respond_to? guard — so a failed construction used to fall
      # through to the [] "this path defines nothing any more" answer, and one
      # broken constructor licensed pruning every previously-registered unit
      # on every changed path of that type, with the generation bumped over
      # the loss. Construction failure tells us nothing about the path; only
      # a genuinely constructed extractor that lacks the method earns the [].
      return nil if extractor.nil?
      return [] unless extractor.respond_to?(rule.method_name)

      result =
        if rule.extractor_key == :poros
          # PoroExtractor needs the AR name set to reject persisted models;
          # its default is an empty set, which would misfile every model
          # under app/models as a PORO on the incremental path.
          extractor.public_send(rule.method_name, absolute_path, ar_names: active_record_names)
        else
          extractor.public_send(rule.method_name, absolute_path)
        end

      Array(result).compact
    rescue StandardError => e
      Rails.logger.warn "[Woods] #{rule.extractor_key} re-extraction of #{absolute_path} failed: #{e.message}"
      # `nil`, not `[]`. The caller treats an empty result as "this path defines
      # nothing any more" and prunes the units previously registered to it — so
      # returning [] here turns a *transient* failure (a watcher batch catching
      # an editor mid-write, an encoding hiccup) into silent deletion of a
      # perfectly good unit, which nothing restores until that file is next
      # touched. "Extraction raised" and "extracted successfully, defines
      # nothing" are different answers and only the second licenses a prune.
      nil
    end

    # Remove units the graph still attributes to a path that the path no
    # longer produces — but only for the types the matching rules cover.
    #
    # @param absolute_path [String]
    # @param rules [Array<PathDispatcher::Rule>]
    # @param produced [Set<String>] identifiers just extracted from the path
    # @param affected_types [Set<Symbol>]
    # @return [Set<String>] identifiers removed
    def prune_path_leftovers(absolute_path, rules, produced, affected_types)
      covered_keys = rules.to_set(&:extractor_key)
      removed = Set.new

      @dependency_graph.identifiers_for_path(absolute_path).each do |identifier|
        next if produced.include?(identifier)

        node_type = @dependency_graph.node(identifier)&.fetch(:type, nil)
        next unless covered_keys.include?(TYPE_TO_EXTRACTOR_KEY[node_type])

        removed.add(identifier) if remove_unit(identifier, affected_types)
      end

      removed
    end

    # Reconcile class-based types against their runtime discovery sets.
    #
    # Models, controllers, mailers, components and channels are discovered by
    # walking descendants, not by globbing files, so a class added since the
    # last extraction is invisible to any path-based dispatch. Comparing each
    # extractor's `discoverable_classes` against the identifiers already in
    # the graph finds exactly those additions, using the same discovery code
    # a full extraction uses.
    #
    # Removals are handled here too, but only against a *complete* discovery
    # set — see {#stale_class_based_units} for why that qualifier carries the
    # whole safety argument.
    #
    # @param affected_types [Set<Symbol>]
    # @return [Set<String>] identifiers added or removed
    def reconcile_class_based_types(affected_types, except: nil)
      touched = Set.new
      excluded = except&.to_set || Set.new

      CLASS_BASED_DISCOVERY.each do |key, spec|
        extractor = extractor_for(key)
        next unless extractor.respond_to?(:discoverable_classes)

        discovered = extractor.discoverable_classes.reject { |k| k.name.nil? }
        known = Array(spec[:types] || spec[:type])
                .flat_map { |type| @dependency_graph.units_of_type(type) }.to_set

        touched.merge(add_discovered_classes(key, spec, discovered, known, excluded, affected_types))
        next if spec[:reconcile_removals] == false

        touched.merge(remove_stale_classes(spec, discovered, known, affected_types))
      end

      touched
    end

    def add_discovered_classes(key, spec, discovered, known, excluded, affected_types)
      new_classes = discovered.reject { |k| known.include?(k.name) || excluded.include?(k.name) }
      return Set.new if new_classes.empty?

      units = new_classes.filter_map do |klass|
        extractor_for(key).public_send(spec[:method], klass)
      rescue StandardError => e
        Rails.logger.warn "[Woods] #{key} extraction of #{klass} failed: #{e.message}"
        nil
      end

      register_and_write(key, units, affected_types)
    end

    def remove_stale_classes(spec, discovered, known, affected_types)
      stale = stale_class_based_units(spec[:type], discovered, known)
      return Set.new if stale.empty?

      Rails.logger.info "[Woods] removing #{stale.size} #{spec[:type]} unit(s) whose class no longer exists"
      stale.each_with_object(Set.new) do |identifier, removed|
        removed.add(identifier) if remove_unit(identifier, affected_types)
      end
    end

    # Class-based units the graph still holds that a full extraction would not
    # produce.
    #
    # {#prune_vanished_units} keys on the source file being gone, which cannot
    # see this case: a class removed from a file that still exists leaves no
    # missing path, and class-based units register a *convention* path derived
    # from the constant name, so a class defined somewhere unconventional was
    # never attributed to the file it actually lived in. Two models in one
    # `.rb`, one of them deleted, and the survivor's own re-extraction says
    # nothing about the other. Nothing else in the run removes it, so it
    # outlives every subsequent incremental — a permanent divergence from a
    # full run, not a transient one.
    #
    # For all six class-based extractors `extract_all` is literally
    # `discoverable_classes.map { ... }.compact`, so absence from that set is
    # exactly "a full extraction would not produce this" — the equivalence the
    # incremental path is held to.
    #
    # The `@eager_load_complete` gate is the whole safety argument, and it is
    # why this is not simply the inverse of the addition pass:
    #
    # * **A partial eager load.** The documented NameError fallback loads only
    #   `EXTRACTION_DIRECTORIES`, so descendants are known-incomplete and the
    #   difference here would be most of the app. Deleting by the type is far
    #   worse than a stale unit, so a partial load removes nothing.
    # * **A constant outliving its file.** A resident daemon that has not
    #   reloaded still holds a deleted class as a descendant, so it is *in* the
    #   set and not stale — which is correct for that process, and the
    #   subsequent reload is what makes it removable.
    #
    # @param type [Symbol] unit type
    # @param discovered [Array<Class>] the extractor's current discovery set
    # @param known [Set<String>] identifiers of that type already in the graph
    # @return [Array<String>] identifiers to remove
    def stale_class_based_units(type, discovered, known)
      return [] unless @eager_load_complete

      live = discovered.to_set(&:name)
      known.reject { |identifier| live.include?(identifier) }
           # Not redundant with `units_of_type`. The graph keys nodes on the
           # bare identifier (B-062), so a same-named unit of another type can
           # overwrite this node while the type index still lists it — and
           # removing it here would delete that other unit instead.
           .select { |identifier| @dependency_graph.node(identifier)&.fetch(:type, nil) == type }
    end

    # Re-run whole-app extractors whose trigger paths changed, replacing that
    # unit type wholesale.
    #
    # These extractors have no per-file entry point — a route unit is derived
    # from `Rails.application.routes`, the middleware unit from the live
    # stack, events from a two-pass scan of all of `app/`. Before this,
    # incremental runs skipped them entirely, so a routes-only change
    # triggered a run that re-extracted nothing while still rewriting the
    # manifest (#164 gap 4). In an already-booted process re-running them is
    # cheap, which is what makes wholesale replacement the right shape.
    #
    # @param change_set [ChangeSet]
    # @param affected_types [Set<Symbol>]
    # @return [Set<String>] identifiers written or removed
    def rerun_whole_app_extractors(change_set, affected_types)
      keys = PathDispatcher.new.whole_app_keys_for_all(change_set.relative_paths)
      # The dispatch rules are configuration-blind (memoized per-process), so
      # the configuration gate applies here — a knob-off host must not re-run
      # an extractor whose units a full extraction of the same tree would not
      # produce. See {#skip_by_configuration?}.
      keys = keys.reject { |key| skip_by_configuration?(key) }.to_set
      return Set.new if keys.empty?

      keys += ROUTE_CONSUMER_EXTRACTORS if keys.include?(:routes)

      keys.each_with_object(Set.new) do |key, touched|
        touched.merge(replace_type_wholesale(key, affected_types))
      end
    end

    # Replace every unit an extractor owns with a fresh extraction.
    #
    # Units of the extractor's types that the fresh run no longer produces are
    # removed, which is what makes this a replacement rather than an upsert —
    # subject to the same eager-load gate the reconciler applies, see
    # {#remove_replaced_units}.
    #
    # @param key [Symbol] extractor key
    # @param affected_types [Set<Symbol>]
    # @return [Set<String>] identifiers written or removed
    def replace_type_wholesale(key, affected_types)
      extractor = extractor_for(key)
      return Set.new unless extractor.respond_to?(:extract_all)

      units = Array(extractor.extract_all).compact.uniq(&:identifier)
      Rails.logger.info "[Woods] Re-ran #{key} wholesale: #{units.size} units"

      touched = register_and_write(key, units, affected_types)
      touched.merge(remove_replaced_units(key, units, affected_types))
    rescue StandardError => e
      Rails.logger.error "[Woods] Wholesale re-run of #{key} failed: #{e.message}"
      Set.new
    end

    # The removal half of a wholesale replacement: drop every unit of `key`'s
    # types that the fresh run no longer produced.
    #
    # Gated exactly the way {#stale_class_based_units} is, and for the same
    # reason (#198): for the extractors in {CLASS_BASED_DISCOVERY},
    # `extract_all` is `discoverable_classes.map { ... }` — a function of the
    # runtime descendants — so on the documented NameError-fallback boot the
    # fresh set is known-partial and "absent from it" does not mean "deleted".
    # The reconciler's gate ("the whole safety argument") never protected this
    # path, and {ROUTE_CONSUMER_EXTRACTORS} routes four descendants-discovered
    # types through here on *every* routes change — so one routes edit on a
    # fallback boot mass-deleted most controller units. Registration above is
    # not gated: additions are safe against a partial set (the same asymmetry
    # {#reconcile_class_based_types} relies on); only removal needs the
    # complete one.
    #
    # File-derived whole-app types (routes, view_templates, events, ...) keep
    # unconditional removal — their `extract_all` globs files or introspects
    # structures that do not depend on eager loading, so their fresh set is
    # authoritative on any boot.
    #
    # The skip is warned, not silent: until a run with a clean boot removes
    # them, the type may hold stale units, and an operator chasing a ghost
    # unit needs to know which run declined to delete it and why.
    #
    # @param key [Symbol] extractor key
    # @param units [Array<ExtractedUnit>] the fresh extraction
    # @param affected_types [Set<Symbol>]
    # @return [Set<String>] identifiers removed
    def remove_replaced_units(key, units, affected_types)
      if CLASS_BASED_DISCOVERY.key?(key) && !@eager_load_complete
        Rails.logger.warn(
          "[Woods] Skipping stale-unit removal for #{key}: the eager load was incomplete, " \
          'so its discovery set is known-partial — the type may hold stale units until a clean boot'
        )
        return Set.new
      end

      fresh = units.to_set(&:identifier)
      EXTRACTOR_KEY_TO_TYPES.fetch(key, []).each_with_object(Set.new) do |unit_type, removed|
        (@dependency_graph.units_of_type(unit_type) - fresh.to_a).each do |stale|
          removed.add(stale) if remove_unit(stale, affected_types)
        end
      end
    end

    # Prune units whose source file no longer exists (#164 gap 2).
    #
    # Two inputs, with deliberately different authority:
    #
    # * **The change set.** A path the caller reports as changed which is no
    #   longer on disk is authoritative — every unit the graph attributes to
    #   it goes, whatever its type. This is the path that handles a deleted
    #   model or controller, and the old side of a rename (git's
    #   `--no-renames` semantics).
    # * **A sweep** over registered paths, for callers whose change set is
    #   incomplete: a git diff that omits deletions, a watcher that missed an
    #   unlink, a branch switch. The sweep is a heuristic, so it is bounded
    #   twice — see {#sweep_candidates} and the class-based exclusion below.
    #
    # Only paths under `Rails.root` are considered either way. Framework
    # units point at gem paths, and an index restored from a CI artifact can
    # carry paths produced under a different root; neither is a deletion.
    #
    # @param change_set [ChangeSet]
    # @param affected_types [Set<Symbol>]
    # @return [Set<String>] identifiers removed
    def prune_vanished_units(change_set, affected_types)
      removed = prune_paths(change_set.missing_paths, affected_types, class_based: true)
      removed.merge(prune_paths(sweep_candidates(change_set), affected_types, class_based: false))

      Rails.logger.info "[Woods] Pruned #{removed.size} unit(s) whose source file is gone" if removed.any?
      removed
    end

    # Registered paths that have vanished and that the sweep is allowed to act
    # on: under Rails.root, gone from disk, and claimed by a file dispatch
    # rule.
    #
    # The file-rule bound exists because some units point at a *nominal* path
    # rather than a source file — `BehavioralProfile` names
    # `config/application.rb`, which no rule claims — and sweeping those would
    # delete units a full extraction still produces.
    #
    # @param change_set [ChangeSet]
    # @return [Array<String>] absolute paths
    def sweep_candidates(change_set)
      root_prefix = "#{Rails.root}/"
      dispatcher = PathDispatcher.new
      already_named = change_set.missing_paths.to_set

      @dependency_graph.registered_paths.reject do |path|
        already_named.include?(path) ||
          !path.to_s.start_with?(root_prefix) ||
          File.exist?(path) ||
          dispatcher.file_rules_for(change_set.relativize(path)).empty?
      end
    end

    # Remove every unit the graph attributes to each of `paths`.
    #
    # @param paths [Enumerable<String>] absolute paths believed to be gone
    # @param affected_types [Set<Symbol>]
    # @param class_based [Boolean] whether class-based units may be pruned
    # @return [Set<String>] identifiers removed
    def prune_paths(paths, affected_types, class_based:)
      root_prefix = "#{Rails.root}/"

      paths.each_with_object(Set.new) do |path, removed|
        next unless path.to_s.start_with?(root_prefix)
        next if File.exist?(path)

        @dependency_graph.identifiers_for_path(path).each do |identifier|
          next if !class_based && convention_path_unit?(identifier)

          removed.add(identifier) if remove_unit(identifier, affected_types)
        end
      end
    end

    # Does this unit's `file_path` name a *convention* that need not exist?
    #
    # The sweep deletes units whose file is gone, which is wrong for anything
    # that derives its path from a constant name rather than from a file it was
    # read out of. Class-based types have always been excluded for that reason.
    #
    # GraphQL joins them (#167): `source_file_for_class` falls back to
    # `app/graphql/<underscored>.rb` when it cannot resolve a source location,
    # and a runtime-defined type — the exact case #167 exists to index — has no
    # such file. Without this the sweep pruned those units in the *same run*
    # that added them, and `reconcile_class_based_types(..., except: pruned)`
    # then refused to re-add them, so #167's target case never survived.
    #
    # The original case: on Rails < 7.1 `ActiveRecord::SchemaMigration` and
    # `InternalMetadata` are real `ActiveRecord::Base` descendants a full
    # extraction emits with `app/models/active_record/schema_migration.rb` as
    # their path — a file no application has, and one the PORO rule *does*
    # claim, so the sweep's file-rule bound doesn't cover it and this check has
    # to. Deleting such a unit requires the caller to name the path; the sweep
    # never infers it.
    #
    # KNOWN COST (B-070 / #171): this keys on unit *type*, but the property is
    # per-unit — GRAPHQL_TYPES is also true of units the static file pass
    # produced, whose path is a real file. So a deleted `app/graphql/**.rb`
    # survives an unnamed-path sweep. Named-path deletion still works, so
    # `woods:incremental` on a git diff is unaffected; the exposed caller is the
    # daemon's catch-up, which runs an empty change set precisely because
    # deletions leave no mtime.
    #
    # Two obvious fixes were tried and **both are wrong** — do not re-attempt
    # them without reading this:
    #
    # 1. *Compare the recorded path against the convention path derived from the
    #    constant.* `Types::ForgottenType` conventionally lives at
    #    `app/graphql/types/forgotten_type.rb`, which IS its convention path — so
    #    a conventionally-named file-defined type is indistinguishable from a
    #    runtime-defined one, and the common case stays spared. Disproven by
    #    `spec/integration/incremental_equivalence_spec.rb`'s pending example.
    # 2. *Let the sweep prune GraphQL and rely on the reconciler's addition half
    #    to re-add whatever the schema still holds.* This is what `except: pruned`
    #    exists to prevent (see the comment at its call site): without a reload a
    #    constant outlives its deleted file, and the schema attachment survives in
    #    memory too, so the re-add resurrects the deleted unit against a path that
    #    no longer exists — permanently, since the sweep then spares it.
    #
    # What would actually work is provenance: record at extraction time whether a
    # source file existed for the unit (`extract_from_runtime_type` already knows
    # — it falls back to a convention path only when `File.exist?` fails) and
    # spare only the units that never had one. That needs the graph node to carry
    # the flag, so it is a serialization change rather than a predicate tweak.
    #
    # @param identifier [String]
    # @return [Boolean]
    def convention_path_unit?(identifier)
      node = @dependency_graph.node(identifier)
      return false unless node

      CLASS_BASED.key?(node[:type])
    end

    # Is this GraphQL unit's recorded path the convention derived from its
    # constant, rather than a file it was read out of?
    #
    # Keying the whole question on unit *type* was wrong (B-070 / #171): the
    # property is per-unit. `GRAPHQL_TYPES` is equally true of units the static
    # file pass produced, whose `file_path` is a real file — so sparing the type
    # wholesale meant a deleted `app/graphql/**.rb` survived an unnamed-path
    # sweep forever, with the daemon's empty-change-set catch-up as the exposed
    # caller.
    #
    # `GraphQLExtractor#source_file_for_class` derives exactly one fallback:
    # `app/graphql/#{constant.underscore}.rb`. A unit whose path is that
    # fallback has no file behind it and must be spared; any other path came
    # from the file pass and is sweepable like anything else.
    # Register a batch of freshly-extracted units and write their JSON.
    #
    # Registration happens BEFORE path normalization — the graph's file map
    # stores absolute paths (that is what changed files are matched against),
    # exactly as full extraction registers in Phase 1 and only normalizes in
    # Phase 4.5. Unit JSON carries the relative path.
    #
    # @param extractor_key [Symbol]
    # @param units [Array<ExtractedUnit>]
    # @param affected_types [Set<Symbol>]
    # @return [Set<String>] identifiers written
    def register_and_write(extractor_key, units, affected_types)
      units = Array(units).compact
      return Set.new if units.empty?

      affected_types&.add(extractor_key)
      type_dir = @output_dir.join(extractor_key.to_s)
      FileUtils.mkdir_p(type_dir)

      units.each_with_object(Set.new) do |unit, written|
        mark_dependents_dirty(unit.identifier)
        @dependency_graph.register(unit)
        mark_dependents_dirty(unit.identifier)

        unit.file_path = normalize_file_path(unit.file_path)
        # Keyed by relative path, which is how batch_git_data keys its result.
        (@incremental_written ||= {})[unit.identifier] = unit.file_path

        write_unit_file(type_dir.join(collision_safe_filename(unit.identifier)), unit)
        written.add(unit.identifier)
      end
    end

    # Remove a unit from the graph and delete its JSON from the index.
    #
    # @param identifier [String]
    # @param affected_types [Set<Symbol>]
    # @return [String, nil] the identifier when it existed and was removed
    def remove_unit(identifier, affected_types)
      node = @dependency_graph.node(identifier)
      return nil unless node

      extractor_key = TYPE_TO_EXTRACTOR_KEY[node[:type]]
      mark_dependents_dirty(identifier)

      if extractor_key
        affected_types&.add(extractor_key)
        path = @output_dir.join(extractor_key.to_s, collision_safe_filename(identifier))
        FileUtils.rm_f(path)
      end

      @dependency_graph.remove(identifier)
      Rails.logger.debug { "[Woods] Removed #{identifier}" }
      identifier
    end

    # Record that a unit's edges changed, so every target it points at (and
    # the unit itself) has its `dependents` list rewritten at the end of the
    # run.
    #
    # @param identifier [String]
    # @return [void]
    def mark_dependents_dirty(identifier)
      @dependents_dirty ||= Set.new
      @dependents_dirty.add(identifier)
      @dependency_graph.dependencies_of(identifier).each { |target| @dependents_dirty.add(target) }
    end

    # Second pass over the unit JSON an incremental run touched, mirroring the
    # two full-extraction phases that operate on already-extracted units:
    # {#resolve_dependents} (Phase 2) and {#enrich_with_git_data} (Phase 4).
    #
    # Both were full-extraction-only, so incremental runs left `dependents`
    # and `metadata.git` frozen at whatever the last full run wrote —
    # divergence that compounds run over run in an incremental CI chain.
    #
    # @param affected_types [Set<Symbol>]
    # @return [void]
    def finalize_incremental_unit_json(affected_types)
      dependents_dirty = @dependents_dirty || Set.new
      git_dirty = @incremental_written || {}
      git_data = incremental_git_data(git_dirty.keys)

      (dependents_dirty | git_dirty.keys).each do |identifier|
        rewrite_unit_json(identifier, affected_types,
                          refresh_dependents: dependents_dirty.include?(identifier),
                          git: git_dirty.key?(identifier) ? git_data[git_dirty[identifier]] : nil)
      end
    end

    # Read one unit's JSON, apply the second-pass patches, and write it back
    # only if something actually changed.
    #
    # @param identifier [String]
    # @param affected_types [Set<Symbol>]
    # @param refresh_dependents [Boolean]
    # @param git [Hash, nil] git metadata for the unit's file, if any
    # @return [void]
    def rewrite_unit_json(identifier, affected_types, refresh_dependents:, git:)
      node = @dependency_graph.node(identifier)
      return unless node

      extractor_key = TYPE_TO_EXTRACTOR_KEY[node[:type]]
      return unless extractor_key

      path = @output_dir.join(extractor_key.to_s, collision_safe_filename(identifier))
      return unless File.exist?(path)

      data = JSON.parse(File.read(path))
      # Serialized comparison, not `data.dup`: the git patch mutates the
      # nested metadata hash in place, which a shallow copy would follow.
      before = JSON.generate(data)

      if refresh_dependents
        data['dependents'] = @dependency_graph.dependents_detail(identifier)
                                              .map { |d| { 'type' => d[:type].to_s, 'identifier' => d[:identifier] } }
      end
      (data['metadata'] ||= {})['git'] = JSON.parse(JSON.generate(git)) if git

      return if JSON.generate(data) == before

      AtomicFile.write(path, json_serialize(data))
      affected_types&.add(extractor_key)
    rescue JSON::ParserError => e
      Rails.logger.warn "[Woods] Could not finalize #{identifier}: #{e.message}"
    end

    # Batch-fetch git metadata for the units written by this run, in a single
    # git invocation, keyed by Rails.root-relative path the way
    # {#batch_git_data} returns it.
    #
    # @param identifiers [Array<String>]
    # @return [Hash{String => Hash}]
    def incremental_git_data(identifiers)
      return {} if identifiers.empty? || !git_available?

      paths = identifiers.filter_map do |identifier|
        node = @dependency_graph.node(identifier)
        next if node.nil? || %i[rails_source gem_source].include?(node[:type])

        node[:file_path] if node[:file_path] && File.exist?(node[:file_path])
      end

      batch_git_data(paths.uniq)
    rescue StandardError => e
      Rails.logger.warn "[Woods] Incremental git enrichment failed: #{e.message}"
      {}
    end

    # Re-extract a single known unit, identified by its graph node.
    #
    # Used for the transitive half of the blast radius — units whose own file
    # did not change but which depend on something that did. Files that *did*
    # change go through {#reconcile_changed_paths} instead, which reconciles
    # the whole path rather than one identifier.
    #
    # @param unit_id [String]
    # @param affected_types [Set<Symbol>, nil]
    # @return [String, nil] the identifier when it was re-extracted and written
    def re_extract_unit(unit_id, affected_types: nil)
      # Framework source only changes on version updates
      if unit_id.start_with?('rails/') || unit_id.start_with?('gems/')
        Rails.logger.debug { "[Woods] Skipping framework re-extraction for #{unit_id}" }
        return nil
      end

      # Find the unit's type from the graph
      node = @dependency_graph.node(unit_id)
      return nil unless node

      type = node[:type]&.to_sym
      file_path = node[:file_path]

      # A vanished file is not re-extractable; {#prune_vanished_units} owns it.
      return nil unless file_path && File.exist?(file_path)

      extractor_key = TYPE_TO_EXTRACTOR_KEY[type]
      return nil unless extractor_key

      extractor = extractor_for(extractor_key)
      return nil unless extractor

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
               extract_file_based_unit(extractor, method, file_path, extractor_key)
             elsif GRAPHQL_TYPES.include?(type)
               extractor.extract_graphql_file(file_path)
             end

      # File-based extractors can return several units from one file (a .rake
      # file defining multiple tasks, etc.); class-based extractors return one.
      units = Array(unit).compact
      return nil if units.empty?

      register_and_write(extractor_key, units, affected_types)
      Rails.logger.info "[Woods] Re-extracted #{unit_id}"
      unit_id
    end

    # Invoke a file-based extraction method, supplying the extra arguments
    # the handful of non-uniform signatures need.
    #
    # @return [ExtractedUnit, Array<ExtractedUnit>, nil]
    def extract_file_based_unit(extractor, method, file_path, extractor_key)
      if extractor_key == :poros
        extractor.public_send(method, file_path, ar_names: active_record_names)
      else
        extractor.public_send(method, file_path)
      end
    end
  end
end
