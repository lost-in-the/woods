# frozen_string_literal: true

require 'set'
require_relative 'graphql_document_paths'
require_relative 'git_source_filter'
# The Git filter asks the configuration extractors which paths they own, and a
# resident process (the watch daemon, a rake task) loads this file without them.
require_relative 'extractors/config_file_extractor'
require_relative 'extractors/configuration_extractor'

module Woods
  # Resolves a changed file path to the extraction work it implies.
  #
  # The incremental path used to route changes purely through
  # {DependencyGraph#affected_by}, which resolves a path via the graph's
  # file map — a map populated only from *already-registered* units. A file
  # that did not exist at the last extraction therefore routed nowhere and
  # was silently ignored (#164, gap 1). This class supplies the missing
  # direction: path → extractor, for files the index has never seen.
  #
  # Two rule sets:
  #
  # * {.file_rules} — file-based extractors, whose per-file method can be
  #   pointed straight at the new path.
  # * {.whole_app_rules} — extractors needing the complete runtime or source
  #   set (routes, middleware, merged Rake tasks, scheduled jobs, etc.). Their
  #   trigger paths map to a wholesale re-run of that extractor.
  #
  # Class-based extractors (models, controllers, mailers, components,
  # channels) are deliberately *absent* here. They are reconciled against
  # their own runtime discovery sets instead (see
  # {Extractor#reconcile_class_based_types}), which is exact by construction
  # and needs no path-to-constant guessing.
  #
  # Rules are built lazily and memoized: they reference the directory
  # constants owned by each extractor, so a directory added to (say)
  # +ServiceExtractor::SERVICE_DIRECTORIES+ flows into dispatch without a
  # second edit here.
  #
  # @example
  #   Woods::PathDispatcher.new.file_rules_for('app/services/checkout.rb')
  #   # => [#<Rule extractor_key=:services method_name=:extract_service_file ...>]
  #
  class PathDispatcher # rubocop:disable Metrics/ClassLength
    # A single path → extraction mapping.
    #
    # @!attribute extractor_key
    #   @return [Symbol] key into {Extractor::EXTRACTORS}
    # @!attribute method_name
    #   @return [Symbol] per-file extraction method (file rules only)
    # @!attribute dirs
    #   @return [Array<String>] Rails.root-relative directory prefixes
    # @!attribute extensions
    #   @return [Array<String>, nil] required filename suffixes (nil = any)
    # @!attribute exclude
    #   @return [Array<String>, nil] path substrings that disqualify a match
    # @!attribute require_segment
    #   @return [String, nil] path substring that must be present
    # @!attribute recursive
    #   @return [Boolean] false to match only files directly inside +dirs+
    # @!attribute exact_paths
    #   @return [Array<String>, nil] exact relative paths that match
    # @!attribute basenames
    #   @return [Array<String>, nil] file basenames that match anywhere under Rails.root (honors +exclude+)
    # @!attribute matcher
    #   @return [Symbol, nil] name of a {PathDispatcher} predicate that replaces
    #     every other attribute when set. A name, never a Proc: rules are
    #     serialized into the source-capture fingerprint, which must be equal
    #     across processes.
    Rule = Struct.new(
      :extractor_key, :method_name, :dirs, :extensions, :exclude,
      :require_segment, :recursive, :exact_paths, :basenames, :matcher,
      keyword_init: true
    ) do
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def matches?(relative_path)
        return PathDispatcher.public_send(matcher, relative_path) if matcher
        return true if exact_paths&.include?(relative_path)
        return basename_match?(relative_path) if basenames

        filters_pass?(relative_path) && under_a_directory?(relative_path)
      end

      private

      def basename_match?(relative_path)
        basenames.include?(File.basename(relative_path)) &&
          exclude.to_a.none? { |segment| relative_path.include?(segment) }
      end

      def filters_pass?(relative_path)
        (extensions.nil? || extensions.any? { |ext| relative_path.end_with?(ext) }) &&
          exclude.to_a.none? { |segment| relative_path.include?(segment) } &&
          (require_segment.nil? || relative_path.include?(require_segment))
      end

      def under_a_directory?(relative_path)
        dirs.to_a.any? do |dir|
          next false unless relative_path.start_with?("#{dir}/")

          recursive == false ? File.dirname(relative_path) == dir : true
        end
      end
    end

    # File rules that scan a path without owning the constants it declares:
    # the PORO sweep itself, the runtime model-mixin guard (it matches every
    # app/lib file and claims only live includes), and the cache-usage scan.
    NON_CLAIMING_RULES = [%i[poros extract_poro_units], %i[concerns extract_model_mixin_file],
                          %i[caching extract_caching_file]].freeze

    # Never swept, whatever +unclaimed_ruby_paths+ says.
    UNSWEPT_PREFIXES = %w[app/assets/ app/javascript/].freeze

    # Fixed glob flags: `**/` spans directories, `{a,b}` alternation works.
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    # Extractors whose directory constants the rules name. Loaded when the
    # rules are built, not at require time, so a process that loads only
    # the dispatcher (one extractor's specs, a resident daemon) still builds
    # them.
    RULE_EXTRACTORS = %w[
      caching config_file configuration database_table decorator event external_consumer factory graphql i18n
      job lib manager package policy pundit rake_task scheduled_job serializer service state_machine validator
      view_template
    ].freeze

    class << self
      # Paths introduced by configuration-source discovery, including generators.
      # @param path [String] root-relative path
      # @return [Boolean]
      def configuration_source_path?(path)
        Extractors::ConfigFileExtractor.config_file_path?(path) ||
          Extractors::ConfigurationExtractor.configuration_path?(path) ||
          path.match?(%r{\Aconfig/routes(?:\.rb|/.*\.rb)\z}) ||
          (path.start_with?('lib/') && path.include?('/generators/') && path.end_with?('.rb'))
      end

      # The extractor whose file rule owns +relative_path+, ignoring scans in
      # {NON_CLAIMING_RULES}. Static: it never consults extraction output.
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Symbol, nil]
      def claiming_key_for(relative_path)
        claiming_keys_for(relative_path).first
      end

      # Every extractor whose file rule owns +relative_path+, in rule order.
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Array<Symbol>]
      def claiming_keys_for(relative_path)
        file_rules.filter_map do |rule|
          next if NON_CLAIMING_RULES.include?([rule.extractor_key, rule.method_name])

          rule.extractor_key if rule.matches?(relative_path)
        end.uniq
      end

      # Is this a Ruby file the PORO extractor sweeps because nothing owns it?
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def unclaimed?(relative_path)
        sweepable?(relative_path) && claiming_key_for(relative_path).nil?
      end

      # Is this owned Ruby under the sweep globs? When its owners emit no unit
      # for it, the PORO extractor takes it (owner fallback).
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def fallback_candidate?(relative_path)
        sweepable?(relative_path) && !claiming_key_for(relative_path).nil?
      end

      # The PORO extractor's surface: app/models outside concerns, plus every
      # unclaimed path.
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def poro_path?(relative_path)
        model_path = relative_path.start_with?('app/models/') && relative_path.end_with?('.rb') &&
                     !relative_path.include?('/concerns/')
        model_path || unclaimed?(relative_path)
      end

      # Is this a client GraphQL operation document under the configured roots?
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def graphql_document_path?(relative_path)
        GraphQLDocumentPaths.match?(relative_path)
      end

      # Is this a YAML file ConfigFileExtractor indexes, under the configured globs?
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def config_file_path?(relative_path)
        Woods::Extractors::ConfigFileExtractor.config_file_path?(relative_path)
      end

      # Can this path change the table set or a table's owning model?
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def database_schema_path?(relative_path)
        Woods::Extractors::DatabaseTableExtractor.trigger_path?(relative_path)
      end

      # Is this the declared external consumers file?
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def external_consumers_path?(relative_path)
        Woods::Extractors::ExternalConsumerExtractor.trigger_path?(relative_path)
      end

      # Runtime-discovered classes have no per-file extractor method.
      def runtime_rules
        @runtime_rules ||= [Rule.new(dirs: %w[app], extensions: %w[.rb])].freeze
      end

      # Rules for extractors with a per-file entry point.
      #
      # @return [Array<Rule>]
      def file_rules
        @file_rules ||= build_file_rules.freeze
      end

      # Rules for extractors that must be re-run wholesale.
      #
      # Memoized per configured +event_paths+: the events rule's +dirs+ come
      # from configuration, which can change or be replaced after the first
      # call. Keying on the value keeps every rule plain serializable data.
      #
      # @return [Array<Rule>]
      def whole_app_rules
        roots = event_roots
        @whole_app_rules = nil unless @whole_app_rules_event_roots == roots
        @whole_app_rules_event_roots = roots
        require_rule_extractors
        @whole_app_rules ||= build_whole_app_rules.freeze
      end

      # Drop memoized rules. Used by specs that stub extractor constants.
      #
      # @return [void]
      def reset!
        @file_rules = nil
        @whole_app_rules = nil
        @whole_app_rules_event_roots = nil
      end

      private

      def event_roots
        Woods.configuration&.event_paths || Woods::Extractors::EventExtractor::APP_DIRECTORIES
      end

      def sweepable?(relative_path)
        relative_path.end_with?('.rb') &&
          UNSWEPT_PREFIXES.none? { |prefix| relative_path.start_with?(prefix) } &&
          unclaimed_globs.any? { |glob| File.fnmatch?(glob, relative_path, GLOB_FLAGS) }
      end

      def unclaimed_globs
        Woods.configuration&.unclaimed_ruby_paths || []
      end

      def build_file_rules
        require_rule_extractors
        plain_ruby_rules + configuration_rules + specialized_rules + caching_rules
      end

      def require_rule_extractors
        RULE_EXTRACTORS.each { |name| require_relative "extractors/#{name}_extractor" }
      end

      # Ruby and YAML configuration sources.
      def configuration_rules
        ex = Woods::Extractors

        [
          # Initializers and environments, plus the boot, seed, deploy and root
          # files ConfigurationExtractor names exactly.
          file_rule(:configurations, :extract_configuration_file,
                    ex::ConfigurationExtractor::DIRECTORY_TYPES.keys,
                    exact_paths: ex::ConfigurationExtractor::SOURCE_FILES),
          # YAML under the configured globs. The matcher reads them at call
          # time; the static attributes describe the defaults, for projections
          # that cannot call it.
          file_rule(:config_files, :extract_config_file, ex::ConfigFileExtractor::DEFAULT_ROOTS,
                    extensions: ex::ConfigFileExtractor::DEFAULT_EXTENSIONS,
                    exclude: ex::ConfigFileExtractor::PROJECTED_EXCLUSIONS, matcher: :config_file_path?)
        ]
      end

      # Extractors that glob `**/*.rb` under directories they own.
      def plain_ruby_rules
        ex = Woods::Extractors

        [
          [:services, :extract_service_file, ex::ServiceExtractor::SERVICE_DIRECTORIES],
          [:jobs, :extract_job_file, ex::JobExtractor::JOB_DIRECTORIES],
          [:serializers, :extract_serializer_file, ex::SerializerExtractor::SERIALIZER_DIRECTORIES],
          [:managers, :extract_manager_file, ex::ManagerExtractor::MANAGER_DIRECTORIES],
          [:policies, :extract_policy_file, ex::PolicyExtractor::POLICY_DIRECTORIES],
          [:validators, :extract_validator_file, ex::ValidatorExtractor::VALIDATOR_DIRECTORIES],
          [:pundit_policies, :extract_pundit_file, ex::PunditExtractor::PUNDIT_DIRECTORIES],
          [:decorators, :extract_decorator_file, ex::DecoratorExtractor::DECORATOR_DIRECTORIES]
        ].map { |key, method_name, dirs| file_rule(key, method_name, dirs) }
      end

      # Extractors with a narrower or wider surface than "*.rb under my dirs".
      def specialized_rules
        ex = Woods::Extractors

        [
          # ConcernExtractor globs app/**/concerns, not just the two canonical
          # directories — match any .rb under app/ inside a concerns/ segment.
          file_rule(:concerns, :extract_concern_file, %w[app], require_segment: '/concerns/'),
          file_rule(:concerns, :extract_model_mixin_file, %w[app lib], exclude: %w[/concerns/]),
          # GraphQL types sit outside FILE_BASED (they share one extractor
          # method across four unit types via GRAPHQL_TYPES), which is exactly
          # why the FILE_BASED-driven coverage guard never noticed they had no
          # rule: a *new* type/mutation/resolver routed nowhere and never
          # entered the index — the same failure #164 gap 1 exists to close.
          file_rule(:graphql, :extract_graphql_file,
                    [ex::GraphQLExtractor::GRAPHQL_DIRECTORY], extensions: %w[.rb]),
          file_rule(:i18n, :extract_i18n_file, ex::I18nExtractor::I18N_DIRECTORIES, extensions: %w[.yml]),
          file_rule(:view_templates, :extract_view_template_file,
                    ex::ViewTemplateExtractor::VIEW_DIRECTORIES, extensions: view_template_extensions),
          file_rule(:migrations, :extract_migration_file, %w[db/migrate], recursive: false),
          # POROs are app/models classes that are *not* ActiveRecord models,
          # plus Ruby no other rule owns (#672). The matcher reads the
          # configured globs at call time, so a memoized rule never goes stale.
          file_rule(:poros, :extract_poro_units, %w[app], matcher: :poro_path?),
          file_rule(:libs, :extract_lib_file, %w[lib], exclude: ex::LibExtractor::EXCLUDED_SEGMENTS),
          file_rule(:test_mappings, :extract_test_file, %w[spec], extensions: %w[_spec.rb]),
          file_rule(:test_mappings, :extract_test_file, %w[test], extensions: %w[_test.rb])
        ]
      end

      # CachingExtractor scans three separate globs with different extensions.
      def caching_rules
        Woods::Extractors::CachingExtractor::SCAN_PATTERNS.map do |_file_type, pattern|
          dir, glob = pattern.split('/**/', 2)
          file_rule(:caching, :extract_caching_file, [dir], extensions: [glob.delete_prefix('*')])
        end
      end

      def view_template_extensions
        Woods::Extractors::ViewTemplateExtractor::ENGINES.flat_map { |k| k.new.extensions }.uniq
      end

      def aggregate_source_rules
        [whole_app_rule(:libs, %w[lib], extensions: %w[.rb], exclude: Woods::Extractors::LibExtractor::EXCLUDED_SEGMENTS),
         whole_app_rule(:rake_tasks, Woods::Extractors::RakeTaskExtractor::RAKE_DIRECTORIES, extensions: %w[.rake])]
      end

      # Schedule files by name, plus any Ruby config source that can register
      # Sidekiq periodic jobs.
      def scheduled_job_rule
        schedules = Woods::Extractors::ScheduledJobExtractor
        exact_paths = schedules::SCHEDULE_FILES.keys + schedules::PERIODIC_SOURCE_FILES
        whole_app_rule(:scheduled_jobs, schedules::PERIODIC_SOURCE_DIRECTORIES,
                       extensions: %w[.rb], exact_paths: exact_paths)
      end

      # Operation documents resolve their selections against the booted
      # schema, so a server-side change re-runs them as well. The document rule
      # names its matcher: the roots are configuration, read at call time. Its
      # dirs and extensions are the defaults, for the generated hook predicate.
      def graphql_operation_rules
        [whole_app_rule(:graphql_operations, [Woods::Extractors::GraphQLExtractor::GRAPHQL_DIRECTORY],
                        extensions: %w[.rb]),
         whole_app_rule(:graphql_operations, %w[app/javascript app/frontend],
                        extensions: %w[.graphql .gql], exclude: [GraphQLDocumentPaths::EXCLUDED_SEGMENT],
                        matcher: :graphql_document_path?)]
      end

      # Named predicates, read at call time: the schema-dump globs live with
      # the table extractor, and the consumers file is configuration. The
      # directories and exact paths restate the table predicate for the shell
      # hook projection, which cannot call it.
      def schema_unit_rules
        [whole_app_rule(:database_tables, %w[db/migrate app/models],
                        extensions: %w[.rb], exact_paths: %w[db/schema.rb db/structure.sql],
                        matcher: :database_schema_path?),
         whole_app_rule(:external_consumers, [], matcher: :external_consumers_path?)]
      end

      # Families read from model and schema directories by their own globs.
      def model_adjacent_rules
        [whole_app_rule(:state_machines, Woods::Extractors::StateMachineExtractor::MODEL_DIRECTORIES,
                        extensions: %w[.rb]),
         whole_app_rule(:factories, Woods::Extractors::FactoryExtractor::FACTORY_DIRECTORIES,
                        extensions: %w[.rb]),
         whole_app_rule(:database_views, %w[db/views], extensions: %w[.sql])]
      end

      def build_whole_app_rules
        [
          # A task may combine definitions from several files; any change or
          # deletion must reconcile the complete task set, not its primary file.
          *aggregate_source_rules,
          whole_app_rule(:routes, %w[config/routes], exact_paths: %w[config/routes.rb]),
          whole_app_rule(:engines, %w[config/routes], exact_paths: %w[config/routes.rb Gemfile.lock]),
          whole_app_rule(:middleware, %w[config/initializers config/environments],
                         exact_paths: %w[config/application.rb Gemfile.lock]),
          scheduled_job_rule,
          *model_adjacent_rules,
          *graphql_operation_rules,
          *schema_unit_rules,
          # EventExtractor is a two-pass scan over its configured roots
          # (`event_paths`, default app/): any Ruby change under one can add
          # or remove a publish/subscribe site.
          whole_app_rule(:events, event_roots, extensions: %w[.rb]),
          # Framework/gem sources are a function of the installed dependency
          # set, so the lockfile is their one honest trigger (#169). The
          # `include_framework_sources` gate lives in the extractor
          # (Extractor#skip_by_configuration?), not here: rules are memoized
          # per-process while configuration can change, and `relevant?` is
          # correct either way because Gemfile.lock already triggers
          # :engines and :middleware.
          whole_app_rule(:rails_source, [], exact_paths: %w[Gemfile.lock]),
          # Packwerk boundaries: a package.yml anywhere re-runs the package
          # extractor wholesale (#280). Vendored and generated trees are the
          # same ones packwerk excludes by default.
          whole_app_rule(:packages, [],
                         basenames: [Woods::Extractors::PackageExtractor::PACKAGE_FILE,
                                     Woods::Extractors::PackageExtractor::PACKWERK_CONFIG],
                         exclude: %w[node_modules/ vendor/ tmp/ bin/ script/])
        ]
      end

      # File-based extractors glob `**/*.rb` unless they say otherwise, so
      # that is the default extension filter here too.
      def file_rule(key, method_name, dirs, **opts)
        opts[:extensions] ||= %w[.rb]
        Rule.new(extractor_key: key, method_name: method_name, dirs: Array(dirs), **opts)
      end

      def whole_app_rule(key, dirs, **opts)
        Rule.new(extractor_key: key, method_name: nil, dirs: Array(dirs), **opts)
      end
    end

    # @param root [String, Pathname, nil] application root (Rails.root by default)
    def initialize(root: nil)
      root ||= Rails.root if defined?(Rails) && Rails.respond_to?(:root)
      @git_filter = GitSourceFilter.new(root: root)
    end

    # @param path [String] root-relative path
    # @return [Boolean] whether a configuration source is excluded by Git
    def git_excluded?(path)
      self.class.configuration_source_path?(path) && !@git_filter.skip_reason(path).nil?
    end

    # File-based rules matching a path.
    #
    # @param relative_path [String] Rails.root-relative path
    # @return [Array<Rule>]
    def file_rules_for(relative_path)
      return [] if git_excluded?(relative_path)

      self.class.file_rules.select { |rule| rule.matches?(relative_path) }
    end

    # Extractor keys whose whole-app re-run is triggered by a path.
    #
    # @param relative_path [String] Rails.root-relative path
    # @return [Array<Symbol>]
    def whole_app_keys_for(relative_path)
      return [] if git_excluded?(relative_path)

      self.class.whole_app_rules
          .select { |rule| rule.matches?(relative_path) }
          .map(&:extractor_key).uniq
    end

    # Does this path imply any extraction work at all?
    #
    # Used to filter a raw git diff down to paths worth handing to
    # {Extractor#extract_changed}. It is deliberately derived from the rules
    # rather than from a second hand-maintained pattern list — the two would
    # drift, and a path the filter drops is a path that never reaches the
    # index no matter how good the dispatch behind it is.
    #
    # Paths under `app/` are relevant even without a rule match: class-based
    # types are discovered from runtime descendants, not from the path.
    #
    # @param relative_path [String] Rails.root-relative path
    # @return [Boolean]
    def relevant?(relative_path)
      return false if git_excluded?(relative_path)

      return true if self.class.runtime_rules.any? { |rule| rule.matches?(relative_path) }

      file_rules_for(relative_path).any? || whole_app_keys_for(relative_path).any?
    end

    # Extractor keys whose whole-app re-run is triggered by any path in a set.
    #
    # @param relative_paths [Enumerable<String>]
    # @return [Set<Symbol>]
    def whole_app_keys_for_all(relative_paths)
      relative_paths.each_with_object(Set.new) do |path, keys|
        whole_app_keys_for(path).each { |key| keys.add(key) }
      end
    end
  end
end
