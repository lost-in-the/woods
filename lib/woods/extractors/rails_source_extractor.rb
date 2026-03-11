# frozen_string_literal: true

module CodebaseIndex
  module Extractors
    # RailsSourceExtractor indexes selected parts of the Rails framework
    # and key gems for version-specific accuracy.
    #
    # This enables queries like "what options does has_many support" or
    # "how does Rails implement callbacks" to return accurate answers
    # for the exact versions in use.
    #
    # Only high-value, frequently-referenced code is indexed to avoid bloat.
    #
    # @example
    #   extractor = RailsSourceExtractor.new
    #   units = extractor.extract_all
    #   # Returns units for ActiveRecord associations, callbacks, etc.
    #
    class RailsSourceExtractor
      # High-value Rails paths to index
      RAILS_PATHS = {
        'activerecord' => [
          'lib/active_record/associations',
          'lib/active_record/callbacks.rb',
          'lib/active_record/validations',
          'lib/active_record/relation',
          'lib/active_record/querying.rb',
          'lib/active_record/scoping',
          'lib/active_record/transactions.rb',
          'lib/active_record/persistence.rb',
          'lib/active_record/attribute_methods',
          'lib/active_record/enum.rb',
          'lib/active_record/store.rb',
          'lib/active_record/nested_attributes.rb'
        ],
        'actionpack' => [
          'lib/action_controller/metal',
          'lib/action_controller/callbacks.rb',
          'lib/abstract_controller/callbacks.rb',
          'lib/action_controller/rendering.rb',
          'lib/action_controller/redirecting.rb',
          'lib/action_controller/params_wrapper.rb'
        ],
        'activesupport' => [
          'lib/active_support/callbacks.rb',
          'lib/active_support/concern.rb',
          'lib/active_support/configurable.rb',
          'lib/active_support/core_ext/module/delegation.rb',
          'lib/active_support/core_ext/object/inclusion.rb'
        ],
        'activejob' => [
          'lib/active_job/callbacks.rb',
          'lib/active_job/enqueuing.rb',
          'lib/active_job/execution.rb',
          'lib/active_job/exceptions.rb'
        ],
        'actionmailer' => [
          'lib/action_mailer/base.rb',
          'lib/action_mailer/delivery_methods.rb',
          'lib/action_mailer/callbacks.rb'
        ]
      }.freeze

      # Common gems worth indexing (configure based on project)
      GEM_CONFIGS = {
        'devise' => {
          paths: ['lib/devise/models', 'lib/devise/controllers', 'lib/devise/strategies'],
          priority: :high
        },
        'pundit' => {
          paths: ['lib/pundit.rb', 'lib/pundit'],
          priority: :high
        },
        'sidekiq' => {
          paths: ['lib/sidekiq/worker.rb', 'lib/sidekiq/job.rb', 'lib/sidekiq/client.rb'],
          priority: :high
        },
        'activeadmin' => {
          paths: ['lib/active_admin/dsl.rb', 'lib/active_admin/resource_dsl.rb'],
          priority: :medium
        },
        'cancancan' => {
          paths: ['lib/cancan/ability.rb', 'lib/cancan/controller_additions.rb'],
          priority: :high
        },
        'friendly_id' => {
          paths: ['lib/friendly_id'],
          priority: :medium
        },
        'paper_trail' => {
          paths: ['lib/paper_trail/has_paper_trail.rb', 'lib/paper_trail/model_config.rb'],
          priority: :medium
        },
        'aasm' => {
          paths: ['lib/aasm'],
          priority: :high
        },
        'phlex' => {
          paths: ['lib/phlex'],
          priority: :high
        },
        'dry-monads' => {
          paths: ['lib/dry/monads'],
          priority: :medium
        }
      }.freeze

      def initialize
        @rails_version = Rails.version
        @gem_versions = {}
      end

      # Extract Rails framework and gem source
      #
      # @return [Array<ExtractedUnit>] List of framework/gem source units
      def extract_all
        units = []

        # Extract Rails framework sources
        units.concat(extract_rails_sources)

        # Extract configured gem sources
        units.concat(extract_gem_sources)

        units.compact
      end

      # ──────────────────────────────────────────────────────────────────────
      # Rails Framework Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Extract only Rails framework sources
      def extract_rails_sources
        units = []

        RAILS_PATHS.each do |gem_name, paths|
          gem_path = find_gem_path(gem_name)
          next unless gem_path

          paths.each do |relative_path|
            full_path = gem_path.join(relative_path)

            if full_path.directory?
              Dir[full_path.join('**/*.rb')].each do |file|
                unit = extract_framework_file(gem_name, file)
                units << unit if unit
              end
            elsif full_path.exist?
              unit = extract_framework_file(gem_name, full_path.to_s)
              units << unit if unit
            end
          end
        end

        units
      end

      # ──────────────────────────────────────────────────────────────────────
      # Gem Source Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Extract gem sources
      def extract_gem_sources
        units = []

        GEM_CONFIGS.each do |gem_name, config|
          gem_path = find_gem_path(gem_name)
          next unless gem_path

          @gem_versions[gem_name] = gem_version(gem_name)

          config[:paths].each do |relative_path|
            full_path = gem_path.join(relative_path)

            if full_path.directory?
              Dir[full_path.join('**/*.rb')].each do |file|
                unit = extract_gem_file(gem_name, config[:priority], file)
                units << unit if unit
              end
            elsif full_path.exist?
              unit = extract_gem_file(gem_name, config[:priority], full_path.to_s)
              units << unit if unit
            end
          end
        end

        units
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Gem Discovery
      # ──────────────────────────────────────────────────────────────────────

      def find_gem_path(gem_name)
        spec = Gem::Specification.find_by_name(gem_name)
        Pathname.new(spec.gem_dir)
      rescue Gem::MissingSpecError
        nil
      end

      def gem_version(gem_name)
        Gem::Specification.find_by_name(gem_name).version.to_s
      rescue StandardError
        'unknown'
      end

      # ──────────────────────────────────────────────────────────────────────
      # File Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_framework_file(component, file_path)
        source = File.read(file_path)
        relative = file_path.sub(%r{.*/gems/[^/]+/}, '')

        # Create a meaningful identifier
        identifier = "rails/#{component}/#{relative}"

        unit = ExtractedUnit.new(
          type: :rails_source,
          identifier: identifier,
          file_path: file_path
        )

        unit.source_code = annotate_framework_source(source, component, relative)

        public_methods = extract_public_api(source)
        dsl_methods = extract_dsl_methods(source)

        unit.metadata = {
          rails_version: @rails_version,
          component: component,
          relative_path: relative,

          # API extraction for retrieval
          defined_modules: extract_module_names(source),
          defined_classes: extract_class_names(source),
          public_methods: public_methods,
          dsl_methods: dsl_methods,

          # Common options/configurations
          option_definitions: extract_option_definitions(source),

          # For retrieval ranking
          is_public_api: public_api_file?(relative),
          importance: rate_importance(relative, source, public_methods: public_methods, dsl_methods: dsl_methods)
        }

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract Rails source #{file_path}: #{e.message}")
        nil
      end

      def extract_gem_file(gem_name, priority, file_path)
        source = File.read(file_path)
        relative = file_path.sub(%r{.*/gems/[^/]+/}, '')

        identifier = "gems/#{gem_name}/#{relative}"

        unit = ExtractedUnit.new(
          type: :gem_source,
          identifier: identifier,
          file_path: file_path
        )

        unit.source_code = annotate_gem_source(source, gem_name, relative)
        unit.metadata = {
          gem_name: gem_name,
          gem_version: @gem_versions[gem_name],
          relative_path: relative,
          priority: priority,

          defined_modules: extract_module_names(source),
          defined_classes: extract_class_names(source),
          public_methods: extract_public_api(source),

          # Gem-specific patterns
          mixins_provided: extract_mixins(source),
          configuration_options: extract_configuration(source)
        }

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract gem source #{file_path}: #{e.message}")
        nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      def annotate_framework_source(source, component, relative)
        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Rails #{@rails_version} - #{component.ljust(55)}║
          # ║ File: #{relative.ljust(62)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      def annotate_gem_source(source, gem_name, relative)
        version = @gem_versions[gem_name] || 'unknown'

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Gem: #{gem_name} v#{version.ljust(55 - gem_name.length)}║
          # ║ File: #{relative.ljust(62)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # ──────────────────────────────────────────────────────────────────────
      # Code Analysis
      # ──────────────────────────────────────────────────────────────────────

      def extract_module_names(source)
        source.scan(/^\s*module\s+([\w:]+)/).flatten.uniq
      end

      def extract_class_names(source)
        source.scan(/^\s*class\s+([\w:]+)/).flatten.uniq
      end

      def extract_public_api(source)
        methods = []
        in_private = false

        source.each_line do |line|
          stripped = line.strip

          in_private = true if stripped.match?(/^\s*private\s*$/)
          in_private = false if stripped.match?(/^\s*public\s*$/)

          next unless !in_private && stripped =~ /def\s+((?:self\.)?\w+[?!=]?)(\(.*?\))?/

          method_name = ::Regexp.last_match(1)
          signature = ::Regexp.last_match(2)
          next if method_name.start_with?('_')

          methods << {
            name: method_name,
            signature: signature,
            class_method: method_name.start_with?('self.')
          }
        end

        methods
      end

      # Extract DSL-style methods (like has_many, validates, etc.)
      def extract_dsl_methods(source)
        dsl_patterns = [
          /def\s+self\.(\w+).*?#.*?DSL/i,
          /def\s+(\w+)\(.*?\)\s*#\s*:call-seq:/,
          /class_methods\s+do.*?def\s+(\w+)/m
        ]

        methods = []
        dsl_patterns.each do |pattern|
          source.scan(pattern) { |m| methods.concat(Array(m)) }
        end

        methods.uniq
      end

      # Extract option hashes and their documentation
      def extract_option_definitions(source)
        options = []

        # Look for VALID_OPTIONS or similar constants
        source.scan(/(\w+_OPTIONS|VALID_\w+)\s*=\s*\[(.*?)\]/m) do |const, values|
          options << {
            constant: const,
            values: values.scan(/:(\w+)/).flatten
          }
        end

        # Look for documented options in comments
        source.scan(/# (\w+) - (.+)$/) do |opt, desc|
          options << { name: opt, description: desc }
        end

        options
      end

      # ──────────────────────────────────────────────────────────────────────
      # Importance Rating
      # ──────────────────────────────────────────────────────────────────────

      # Determine if this is a public API file worth prioritizing
      def public_api_file?(relative_path)
        public_patterns = [
          %r{associations/builder},
          /callbacks\.rb$/,
          /validations\.rb$/,
          /base\.rb$/,
          %r{/metal/[^/]+\.rb$}
        ]

        public_patterns.any? { |p| relative_path.match?(p) }
      end

      # Rate importance for retrieval ranking
      def rate_importance(relative_path, source, public_methods: nil, dsl_methods: nil)
        score = 0

        # High-traffic files
        score += 3 if relative_path.match?(/associations|callbacks|validations/)

        # Files with lots of public methods
        public_method_count = public_methods ? public_methods.size : extract_public_api(source).size
        score += 2 if public_method_count > 10

        # Files with DSL methods
        dsl = dsl_methods || extract_dsl_methods(source)
        score += 2 if dsl.any?

        # Files with option documentation
        score += 1 if source.include?('# Options:')

        case score
        when 0..2 then :low
        when 3..5 then :medium
        else :high
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Gem-Specific Analysis
      # ──────────────────────────────────────────────────────────────────────

      # Extract mixin modules provided by a gem
      def extract_mixins(source)
        mixins = []

        # Look for modules designed to be included
        source.scan(/module\s+(\w+).*?def\s+self\.included/m) do |mod|
          mixins << mod[0]
        end

        # ActiveSupport::Concern pattern
        source.scan(/extend\s+ActiveSupport::Concern.*?module\s+ClassMethods/m) do
          mixins << ::Regexp.last_match(1) if source =~ /module\s+(\w+).*?extend\s+ActiveSupport::Concern/m
        end

        mixins.uniq
      end

      # Extract configuration options provided by a gem
      def extract_configuration(source)
        configs = []

        # Railtie configuration
        source.scan(/config\.(\w+)\s*=/) do |cfg|
          configs << cfg[0]
        end

        # Class-level configuration
        source.scan(/(?:mattr|cattr)_accessor\s+:(\w+)/) do |cfg|
          configs << cfg[0]
        end

        configs.uniq
      end
    end
  end
end
