# frozen_string_literal: true

require 'set'

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
  # * {.whole_app_rules} — extractors with no per-file entry point (routes,
  #   middleware, engines, scheduled jobs, state machines, factories,
  #   events). Their trigger paths map to a wholesale re-run of that
  #   extractor, which is cheap in an already-booted process.
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
    Rule = Struct.new(
      :extractor_key, :method_name, :dirs, :extensions, :exclude,
      :require_segment, :recursive, :exact_paths,
      keyword_init: true
    ) do
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def matches?(relative_path)
        return true if exact_paths&.include?(relative_path)

        filters_pass?(relative_path) && under_a_directory?(relative_path)
      end

      private

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

    class << self
      # Rules for extractors with a per-file entry point.
      #
      # @return [Array<Rule>]
      def file_rules
        @file_rules ||= build_file_rules.freeze
      end

      # Rules for extractors that must be re-run wholesale.
      #
      # @return [Array<Rule>]
      def whole_app_rules
        @whole_app_rules ||= build_whole_app_rules.freeze
      end

      # Drop memoized rules. Used by specs that stub extractor constants.
      #
      # @return [void]
      def reset!
        @file_rules = nil
        @whole_app_rules = nil
      end

      private

      def build_file_rules
        plain_ruby_rules + specialized_rules + caching_rules
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
          [:decorators, :extract_decorator_file, ex::DecoratorExtractor::DECORATOR_DIRECTORIES],
          [:configurations, :extract_configuration_file, ex::ConfigurationExtractor::CONFIG_DIRECTORIES]
        ].map { |key, method_name, dirs| file_rule(key, method_name, dirs) }
      end

      # Extractors with a narrower or wider surface than "*.rb under my dirs".
      def specialized_rules
        ex = Woods::Extractors

        [
          # ConcernExtractor globs app/**/concerns, not just the two canonical
          # directories — match any .rb under app/ inside a concerns/ segment.
          file_rule(:concerns, :extract_concern_file, %w[app], require_segment: '/concerns/'),
          # GraphQL types sit outside FILE_BASED (they share one extractor
          # method across four unit types via GRAPHQL_TYPES), which is exactly
          # why the FILE_BASED-driven coverage guard never noticed they had no
          # rule: a *new* type/mutation/resolver routed nowhere and never
          # entered the index — the same failure #164 gap 1 exists to close.
          file_rule(:graphql, :extract_graphql_file,
                    [ex::GraphQLExtractor::GRAPHQL_DIRECTORY], extensions: %w[.rb]),
          file_rule(:i18n, :extract_i18n_file, ex::I18nExtractor::I18N_DIRECTORIES, extensions: %w[.yml]),
          file_rule(:rake_tasks, :extract_rake_file, ex::RakeTaskExtractor::RAKE_DIRECTORIES, extensions: %w[.rake]),
          file_rule(:view_templates, :extract_view_template_file,
                    ex::ViewTemplateExtractor::VIEW_DIRECTORIES, extensions: view_template_extensions),
          file_rule(:migrations, :extract_migration_file, %w[db/migrate], recursive: false),
          # POROs are app/models classes that are *not* ActiveRecord models;
          # the extractor makes that call itself given ar_names.
          file_rule(:poros, :extract_poro_file, %w[app/models], exclude: %w[/concerns/]),
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

      def build_whole_app_rules
        [
          whole_app_rule(:routes, %w[config/routes], exact_paths: %w[config/routes.rb]),
          whole_app_rule(:engines, %w[config/routes], exact_paths: %w[config/routes.rb Gemfile.lock]),
          whole_app_rule(:middleware, %w[config/initializers config/environments],
                         exact_paths: %w[config/application.rb Gemfile.lock]),
          whole_app_rule(:scheduled_jobs, [],
                         exact_paths: Woods::Extractors::ScheduledJobExtractor::SCHEDULE_FILES.keys),
          whole_app_rule(:state_machines, Woods::Extractors::StateMachineExtractor::MODEL_DIRECTORIES,
                         extensions: %w[.rb]),
          whole_app_rule(:factories, Woods::Extractors::FactoryExtractor::FACTORY_DIRECTORIES,
                         extensions: %w[.rb]),
          whole_app_rule(:database_views, %w[db/views], extensions: %w[.sql]),
          # EventExtractor is a two-pass scan over all of app/ — any Ruby
          # change can add or remove a publish/subscribe site.
          whole_app_rule(:events, Woods::Extractors::EventExtractor::APP_DIRECTORIES, extensions: %w[.rb])
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

    # File-based rules matching a path.
    #
    # @param relative_path [String] Rails.root-relative path
    # @return [Array<Rule>]
    def file_rules_for(relative_path)
      self.class.file_rules.select { |rule| rule.matches?(relative_path) }
    end

    # Extractor keys whose whole-app re-run is triggered by a path.
    #
    # @param relative_path [String] Rails.root-relative path
    # @return [Array<Symbol>]
    def whole_app_keys_for(relative_path)
      self.class.whole_app_rules.select { |rule| rule.matches?(relative_path) }
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
      return true if relative_path.start_with?('app/') && relative_path.end_with?('.rb')

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
