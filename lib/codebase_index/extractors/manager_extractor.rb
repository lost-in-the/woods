# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # ManagerExtractor handles SimpleDelegator subclass extraction.
    #
    # Manager/delegator objects wrap a model and provide a richer interface
    # for specific contexts (e.g., OrderManager wrapping Order with
    # checkout-specific methods). They live in `app/managers/`.
    #
    # We extract:
    # - Wrapped model (via SimpleDelegator superclass or initializer)
    # - Public methods (the manager's added interface)
    # - Delegation chain (what gets delegated vs overridden)
    # - Dependencies (what models/services they reference)
    #
    # @example
    #   extractor = ManagerExtractor.new
    #   units = extractor.extract_all
    #   order_mgr = units.find { |u| u.identifier == "OrderManager" }
    #
    class ManagerExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Directories to scan for manager/delegator objects
      MANAGER_DIRECTORIES = %w[
        app/managers
      ].freeze

      def initialize
        @directories = MANAGER_DIRECTORIES.map { |d| Rails.root.join(d) }
                                          .select(&:directory?)
      end

      # Extract all manager/delegator objects
      #
      # @return [Array<ExtractedUnit>] List of manager units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.rb')].filter_map do |file|
            extract_manager_file(file)
          end
        end
      end

      # Extract a single manager file
      #
      # @param file_path [String] Path to the manager file
      # @return [ExtractedUnit, nil] The extracted unit or nil if not a manager
      def extract_manager_file(file_path)
        source = File.read(file_path)
        class_name = extract_class_name(file_path, source, 'managers')

        return nil unless class_name
        return nil unless manager_file?(source)

        unit = ExtractedUnit.new(
          type: :manager,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name)
        unit.metadata = extract_metadata(source, class_name)
        unit.dependencies = extract_dependencies(source, class_name)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract manager #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      def manager_file?(source)
        source.match?(/< SimpleDelegator/) ||
          source.match?(/< DelegateClass\(/) ||
          source.match?(/include Delegator/)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      def annotate_source(source, class_name)
        wrapped = detect_wrapped_model(source, class_name)

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Manager: #{class_name.ljust(60)}║
          # ║ Wraps: #{(wrapped || 'unknown').ljust(61)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_metadata(source, class_name)
        {
          wrapped_model: detect_wrapped_model(source, class_name),
          delegation_type: detect_delegation_type(source),
          public_methods: extract_public_methods(source),
          class_methods: extract_class_methods(source),
          initialize_params: extract_initialize_params(source),
          delegated_methods: extract_delegated_methods(source),
          overridden_methods: extract_overridden_methods(source),
          custom_errors: extract_custom_errors(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') },
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size
        }
      end

      def detect_wrapped_model(source, class_name)
        # DelegateClass(ModelName) pattern
        return ::Regexp.last_match(1) if source =~ /< DelegateClass\((\w+)\)/

        # super(model) in initialize
        return ::Regexp.last_match(1).capitalize if source =~ /super\((\w+)\)/

        # @model = model; super(model) — look for param name
        if source =~ /def\s+initialize\s*\((\w+)/
          param = ::Regexp.last_match(1)
          return param.capitalize unless %w[args options params attributes].include?(param)
        end

        # Infer from class name: OrderManager -> Order
        stripped = class_name.split('::').last
        inferred = stripped.sub(/Manager\z/, '')
        # Return nil if no suffix was removed (not a FooManager pattern)
        return nil if inferred == stripped || inferred.empty?

        inferred
      end

      def detect_delegation_type(source)
        return :delegate_class if source.match?(/< DelegateClass\(/)
        return :simple_delegator if source.match?(/< SimpleDelegator/)

        :unknown
      end

      def extract_delegated_methods(source)
        methods = []

        # delegate :foo, :bar, to: :something
        source.scan(/delegate\s+(.+?)(?:,\s*to:)/) do |match|
          match[0].scan(/:(\w+)/).flatten.each { |m| methods << m }
        end

        methods
      end

      def extract_overridden_methods(source)
        # Methods that call super — these override delegated behavior
        source.scan(/def\s+(\w+[?!=]?).*?\n.*?super/m).flatten
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(source, class_name)
        deps = []

        # Wrapped model dependency (specific :via)
        wrapped = detect_wrapped_model(source, class_name)
        deps << { type: :model, target: wrapped, via: :delegation } if wrapped

        deps.concat(scan_common_dependencies(source))

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
