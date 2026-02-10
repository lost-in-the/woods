# frozen_string_literal: true

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
        class_name = extract_class_name(file_path, source)

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

      def extract_class_name(file_path, source)
        return ::Regexp.last_match(1) if source =~ /^\s*class\s+([\w:]+)/

        file_path
          .sub(Rails.root.to_s + '/', '')
          .sub(%r{^app/managers/}, '')
          .sub('.rb', '')
          .camelize
      end

      def manager_file?(source)
        source.match?(/< SimpleDelegator/) ||
          source.match?(/< DelegateClass\(/) ||
          source.match?(/include Delegator/)
      end

      def extract_namespace(class_name)
        parts = class_name.split('::')
        parts.size > 1 ? parts[0..-2].join('::') : nil
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
        inferred.empty? ? nil : inferred
      end

      def detect_delegation_type(source)
        return :delegate_class if source.match?(/< DelegateClass\(/)
        return :simple_delegator if source.match?(/< SimpleDelegator/)

        :unknown
      end

      def extract_public_methods(source)
        methods = []
        in_private = false
        in_protected = false

        source.each_line do |line|
          stripped = line.strip

          in_private = true if stripped == 'private'
          in_protected = true if stripped == 'protected'
          in_private = false if stripped == 'public'
          in_protected = false if stripped == 'public'

          if !in_private && !in_protected && stripped =~ /def\s+((?:self\.)?\w+[?!=]?)/
            method_name = ::Regexp.last_match(1)
            methods << method_name unless method_name.start_with?('_')
          end
        end

        methods
      end

      def extract_class_methods(source)
        source.scan(/def\s+self\.(\w+[?!=]?)/).flatten
      end

      def extract_initialize_params(source)
        init_match = source.match(/def\s+initialize\s*\((.*?)\)/m)
        return [] unless init_match

        params_str = init_match[1]
        params = []

        params_str.scan(/(\w+)(?::\s*([^,\n]+))?/) do |name, default|
          params << {
            name: name,
            has_default: !default.nil?,
            keyword: params_str.include?("#{name}:")
          }
        end

        params
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

      def extract_custom_errors(source)
        source.scan(/class\s+(\w+(?:Error|Exception))\s*</).flatten
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(source, class_name)
        deps = []

        # Wrapped model dependency
        wrapped = detect_wrapped_model(source, class_name)
        if wrapped
          deps << { type: :model, target: wrapped, via: :delegation }
        end

        # Model references (using precomputed regex)
        source.scan(ModelNameCache.model_names_regex).uniq.each do |model_name|
          deps << { type: :model, target: model_name, via: :code_reference }
        end

        # Service references
        source.scan(/(\w+Service)(?:\.|::new|\.call|\.perform)/).flatten.uniq.each do |service|
          deps << { type: :service, target: service, via: :code_reference }
        end

        # Job references
        source.scan(/(\w+Job)\.perform/).flatten.uniq.each do |job|
          deps << { type: :job, target: job, via: :code_reference }
        end

        # Mailer references
        source.scan(/(\w+Mailer)\./).flatten.uniq.each do |mailer|
          deps << { type: :mailer, target: mailer, via: :code_reference }
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
