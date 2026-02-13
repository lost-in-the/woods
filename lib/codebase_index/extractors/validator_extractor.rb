# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # ValidatorExtractor handles custom validator class extraction.
    #
    # Custom validators encapsulate reusable validation logic that applies
    # across multiple models. They inherit from `ActiveModel::Validator`
    # or `ActiveModel::EachValidator` and live in `app/validators/`.
    #
    # We extract:
    # - Validator name and namespace
    # - Base class (Validator vs EachValidator)
    # - Validation rules (what they check)
    # - Models they operate on (from source references)
    # - Dependencies (what models/services they reference)
    #
    # @example
    #   extractor = ValidatorExtractor.new
    #   units = extractor.extract_all
    #   email = units.find { |u| u.identifier == "EmailFormatValidator" }
    #
    class ValidatorExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Directories to scan for custom validators
      VALIDATOR_DIRECTORIES = %w[
        app/validators
      ].freeze

      def initialize
        @directories = VALIDATOR_DIRECTORIES.map { |d| Rails.root.join(d) }
                                            .select(&:directory?)
      end

      # Extract all custom validators
      #
      # @return [Array<ExtractedUnit>] List of validator units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.rb')].filter_map do |file|
            extract_validator_file(file)
          end
        end
      end

      # Extract a single validator file
      #
      # @param file_path [String] Path to the validator file
      # @return [ExtractedUnit, nil] The extracted unit or nil if not a validator
      def extract_validator_file(file_path)
        source = File.read(file_path)
        class_name = extract_class_name(file_path, source)

        return nil unless class_name
        return nil unless validator_file?(source)

        unit = ExtractedUnit.new(
          type: :validator,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name)
        unit.metadata = extract_metadata(source, class_name)
        unit.dependencies = extract_dependencies(source)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract validator #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      def extract_class_name(file_path, source)
        return ::Regexp.last_match(1) if source =~ /^\s*class\s+([\w:]+)/

        file_path
          .sub("#{Rails.root}/", '')
          .sub(%r{^app/validators/}, '')
          .sub('.rb', '')
          .camelize
      end

      def validator_file?(source)
        source.match?(/< ActiveModel::Validator/) ||
          source.match?(/< ActiveModel::EachValidator/) ||
          source.match?(/def\s+validate_each\b/) ||
          source.match?(/def\s+validate\(/)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      def annotate_source(source, class_name)
        validator_type = detect_validator_type(source)
        validated_attrs = extract_validated_attributes(source)

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Validator: #{class_name.ljust(57)}║
          # ║ Type: #{validator_type.to_s.ljust(62)}║
          # ║ Attributes: #{validated_attrs.join(', ').ljust(56)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_metadata(source, class_name)
        {
          validator_type: detect_validator_type(source),
          validated_attributes: extract_validated_attributes(source),
          validation_rules: extract_validation_rules(source),
          error_messages: extract_error_messages(source),
          public_methods: extract_public_methods(source),
          class_methods: extract_class_methods(source),
          options_used: extract_options(source),
          inferred_models: infer_models_from_name(class_name),
          custom_errors: extract_custom_errors(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') },
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size
        }
      end

      def detect_validator_type(source)
        return :each_validator if source.match?(/< ActiveModel::EachValidator/)
        return :validator if source.match?(/< ActiveModel::Validator/)
        return :each_validator if source.match?(/def\s+validate_each\b/)
        return :validator if source.match?(/def\s+validate\(/)

        :unknown
      end

      def extract_validated_attributes(source)
        attrs = []

        # EachValidator: the attribute param in validate_each
        attrs << ::Regexp.last_match(1) if source =~ /def\s+validate_each\s*\(\s*\w+\s*,\s*(\w+)/

        # From error.add calls: record.errors.add(:attribute, ...)
        source.scan(/errors\.add\s*\(\s*:(\w+)/).flatten.each { |a| attrs << a }

        # From validates_each blocks
        source.scan(/validates_each\s*\(\s*:(\w+)/).flatten.each { |a| attrs << a }

        attrs.uniq
      end

      def extract_validation_rules(source)
        rules = []

        # Conditional checks in validate/validate_each body
        source.scan(/unless\s+(.+)$/).flatten.each { |r| rules << r.strip }
        source.scan(/if\s+(.+?)(?:\s*$|\s*then)/).flatten.each { |r| rules << r.strip }

        # Regex validations
        source.scan(%r{=~\s*(/[^/]+/)}).flatten.each { |r| rules << "matches #{r}" }
        source.scan(%r{match\?\s*\((/[^/]+/)\)}).flatten.each { |r| rules << "matches #{r}" }

        rules.first(10) # Cap at 10 to avoid noise
      end

      def extract_error_messages(source)
        messages = []

        # errors.add(:attr, "message") or errors.add(variable, "message")
        source.scan(/errors\.add\s*\(\s*:?\w+\s*,\s*["']([^"']+)["']/).flatten.each { |m| messages << m }

        # errors.add(:attr, :symbol) or errors.add(variable, :symbol)
        source.scan(/errors\.add\s*\(\s*:?\w+\s*,\s*:(\w+)/).flatten.each { |m| messages << ":#{m}" }

        messages
      end

      def extract_options(source)
        options = []

        # options[:key] access
        source.scan(/options\[:(\w+)\]/).flatten.each { |o| options << o }

        options.uniq
      end

      def infer_models_from_name(class_name)
        # EmailFormatValidator -> might validate email on many models
        # No reliable way to infer specific models from name alone
        # Return the validator's conceptual domain
        stripped = class_name.split('::').last
        inferred = stripped.sub(/Validator\z/, '')
        inferred.empty? ? [] : [inferred]
      end

      def extract_custom_errors(source)
        source.scan(/class\s+(\w+(?:Error|Exception))\s*</).flatten
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(source)
        deps = []
        deps.concat(scan_model_dependencies(source, via: :validation))
        deps.concat(scan_service_dependencies(source))

        # Other validators referenced
        source.scan(/(\w+Validator)(?:\.|::new)/).flatten.uniq.each do |validator|
          deps << { type: :validator, target: validator, via: :code_reference }
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
