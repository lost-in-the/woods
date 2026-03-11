# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # PunditExtractor handles Pundit authorization policy extraction.
    #
    # Specifically targets Pundit convention: classes in `app/policies/`
    # that inherit from ApplicationPolicy or follow Pundit patterns
    # (user/record attrs, action? methods). This is distinct from the
    # generic PolicyExtractor which handles domain eligibility policies.
    #
    # @example
    #   extractor = PunditExtractor.new
    #   units = extractor.extract_all
    #   post_policy = units.find { |u| u.identifier == "PostPolicy" }
    #
    class PunditExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Directories to scan for Pundit policies
      PUNDIT_DIRECTORIES = %w[
        app/policies
      ].freeze

      # Standard Pundit action methods
      PUNDIT_ACTIONS = %w[index? show? create? new? update? edit? destroy?].freeze

      def initialize
        @directories = PUNDIT_DIRECTORIES.map { |d| Rails.root.join(d) }
                                         .select(&:directory?)
      end

      # Extract all Pundit policy classes
      #
      # @return [Array<ExtractedUnit>] List of Pundit policy units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.rb')].filter_map do |file|
            extract_pundit_file(file)
          end
        end
      end

      # Extract a single Pundit policy file
      #
      # @param file_path [String] Path to the policy file
      # @return [ExtractedUnit, nil] The extracted unit or nil if not a Pundit policy
      def extract_pundit_file(file_path)
        source = File.read(file_path)
        class_name = extract_class_name(file_path, source)

        return nil unless class_name
        return nil unless pundit_policy?(source)

        unit = ExtractedUnit.new(
          type: :pundit_policy,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name)
        unit.metadata = extract_metadata(source, class_name)
        unit.dependencies = extract_dependencies(source, class_name)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract Pundit policy #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      # Extract class name from source or infer from file path.
      #
      # @param file_path [String]
      # @param source [String]
      # @return [String, nil]
      def extract_class_name(file_path, source)
        return ::Regexp.last_match(1) if source =~ /^\s*class\s+([\w:]+)/

        file_path
          .sub("#{Rails.root}/", '')
          .sub(%r{^app/policies/}, '')
          .sub('.rb', '')
          .split('/')
          .map { |s| s.split('_').map(&:capitalize).join }
          .join('::')
      end

      # Detect whether this is a Pundit policy.
      #
      # @param source [String] Ruby source code
      # @return [Boolean]
      def pundit_policy?(source)
        source.match?(/< ApplicationPolicy/) ||
          (source.match?(/attr_reader\s+:user/) && source.match?(/attr_reader.*:record/)) ||
          (source.match?(/def\s+initialize\s*\(\s*user\s*,/) && source.match?(/def\s+\w+\?/))
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String]
      # @param class_name [String]
      # @return [String]
      def annotate_source(source, class_name)
        model = infer_model(class_name)
        actions = detect_authorization_actions(source)

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Pundit Policy: #{class_name.ljust(53)}║
          # ║ Model: #{model.to_s.ljust(61)}║
          # ║ Actions: #{actions.join(', ').ljust(59)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String]
      # @param class_name [String]
      # @return [Hash]
      def extract_metadata(source, class_name)
        actions = detect_authorization_actions(source)
        {
          model: infer_model(class_name),
          authorization_actions: actions,
          standard_actions: actions & PUNDIT_ACTIONS,
          custom_actions: actions - PUNDIT_ACTIONS,
          has_scope_class: source.match?(/class\s+Scope\b/) || false,
          inherits_application_policy: source.match?(/< ApplicationPolicy/) || false,
          public_methods: extract_public_methods(source),
          class_methods: extract_class_methods(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') },
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size
        }
      end

      # Detect authorization action methods (public methods ending in ?).
      #
      # @param source [String]
      # @return [Array<String>]
      def detect_authorization_actions(source)
        methods = []
        in_private = false
        in_protected = false
        in_scope_class = false
        scope_depth = 0

        source.each_line do |line|
          stripped = line.strip

          # Track Scope inner class
          if stripped =~ /class\s+Scope\b/
            in_scope_class = true
            scope_depth = 0
          end
          if in_scope_class
            scope_depth += stripped.scan(/\b(class|module|do)\b/).size
            scope_depth -= stripped.scan(/\bend\b/).size
            if scope_depth <= 0
              in_scope_class = false
              next
            end
            next
          end

          in_private = true if stripped == 'private'
          in_protected = true if stripped == 'protected'
          in_private = false if stripped == 'public'
          in_protected = false if stripped == 'public'

          next if in_private || in_protected

          methods << ::Regexp.last_match(1) if stripped =~ /def\s+(\w+\?)/
        end

        methods.uniq
      end

      # Infer the model name from the policy class name.
      #
      # @param class_name [String]
      # @return [String]
      def infer_model(class_name)
        stripped = class_name.split('::').last
        stripped.sub(/Policy\z/, '')
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String]
      # @param class_name [String]
      # @return [Array<Hash>]
      def extract_dependencies(source, class_name)
        model = infer_model(class_name)
        deps = [{ type: :model, target: model, via: :authorization }]

        deps.concat(scan_model_dependencies(source))
        deps.concat(scan_service_dependencies(source))

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
