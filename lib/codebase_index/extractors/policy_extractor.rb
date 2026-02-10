# frozen_string_literal: true

module CodebaseIndex
  module Extractors
    # PolicyExtractor handles domain policy class extraction.
    #
    # Policy classes encode business eligibility rules — "can this user
    # upgrade?", "is this order refundable?". These are NOT Pundit
    # authorization policies. They live in `app/policies/`.
    #
    # We extract:
    # - Policy name and namespace
    # - Decision methods (allowed?, eligible?, valid?, etc.)
    # - Models they evaluate (from initializer params and method bodies)
    # - Dependencies (what models/services they reference)
    #
    # @example
    #   extractor = PolicyExtractor.new
    #   units = extractor.extract_all
    #   refund = units.find { |u| u.identifier == "RefundPolicy" }
    #
    class PolicyExtractor
      # Directories to scan for policy classes
      POLICY_DIRECTORIES = %w[
        app/policies
      ].freeze

      # Method name patterns that indicate decision/eligibility logic
      DECISION_METHOD_PATTERN = /\b(allowed|eligible|valid|permitted|can_\w+|should_\w+|qualifies|meets_\w+|satisfies)\?/

      def initialize
        @directories = POLICY_DIRECTORIES.map { |d| Rails.root.join(d) }
                                         .select(&:directory?)
      end

      # Extract all policy classes
      #
      # @return [Array<ExtractedUnit>] List of policy units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.rb')].filter_map do |file|
            extract_policy_file(file)
          end
        end
      end

      # Extract a single policy file
      #
      # @param file_path [String] Path to the policy file
      # @return [ExtractedUnit, nil] The extracted unit or nil if not a policy
      def extract_policy_file(file_path)
        source = File.read(file_path)
        class_name = extract_class_name(file_path, source)

        return nil unless class_name
        return nil if skip_file?(source)

        unit = ExtractedUnit.new(
          type: :policy,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name)
        unit.metadata = extract_metadata(source, class_name)
        unit.dependencies = extract_dependencies(source, class_name)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract policy #{file_path}: #{e.message}")
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
          .sub(%r{^app/policies/}, '')
          .sub('.rb', '')
          .camelize
      end

      def skip_file?(source)
        # Skip module-only files (concerns, base modules)
        source.match?(/^\s*module\s+\w+\s*$/) && !source.match?(/^\s*class\s+/)
      end

      def extract_namespace(class_name)
        parts = class_name.split('::')
        parts.size > 1 ? parts[0..-2].join('::') : nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      def annotate_source(source, class_name)
        decisions = detect_decision_methods(source)
        evaluated = detect_evaluated_models(source, class_name)

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Policy: #{class_name.ljust(60)}║
          # ║ Evaluates: #{evaluated.join(', ').ljust(57)}║
          # ║ Decisions: #{decisions.join(', ').ljust(57)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_metadata(source, class_name)
        {
          evaluated_models: detect_evaluated_models(source, class_name),
          decision_methods: detect_decision_methods(source),
          public_methods: extract_public_methods(source),
          class_methods: extract_class_methods(source),
          initialize_params: extract_initialize_params(source),
          is_pundit: pundit_policy?(source),
          custom_errors: extract_custom_errors(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') },
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size
        }
      end

      def detect_decision_methods(source)
        methods = []
        in_private = false
        in_protected = false

        source.each_line do |line|
          stripped = line.strip

          in_private = true if stripped == 'private'
          in_protected = true if stripped == 'protected'
          in_private = false if stripped == 'public'
          in_protected = false if stripped == 'public'

          next if in_private || in_protected

          if stripped =~ /def\s+((?:self\.)?\w+\?)/
            method_name = ::Regexp.last_match(1)
            methods << method_name
          end
        end

        methods.uniq
      end

      def detect_evaluated_models(source, class_name)
        models = []

        # From initialize params
        if source =~ /def\s+initialize\s*\(([^)]*)\)/
          params = ::Regexp.last_match(1)
          params.scan(/(\w+)/).flatten.each do |param|
            # Skip generic param names
            next if %w[args options params attributes context].include?(param)

            capitalized = param.sub(/\A\w/, &:upcase).gsub(/_(\w)/) { ::Regexp.last_match(1).upcase }
            models << capitalized
          end
        end

        # Infer from class name: RefundPolicy -> Refund
        stripped = class_name.split('::').last
        inferred = stripped.sub(/Policy\z/, '')
        models << inferred if !inferred.nil? && !inferred.empty? && !models.include?(inferred)

        models.uniq
      end

      def pundit_policy?(source)
        source.match?(/< ApplicationPolicy/) ||
          source.match?(/def\s+initialize\s*\(\s*user\s*,/) ||
          source.match?(/attr_reader\s+:user\s*,\s*:record/)
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

      def extract_custom_errors(source)
        source.scan(/class\s+(\w+(?:Error|Exception))\s*</).flatten
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(source, class_name)
        deps = []

        # Evaluated model dependencies
        detect_evaluated_models(source, class_name).each do |model|
          deps << { type: :model, target: model, via: :policy_evaluation }
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

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
