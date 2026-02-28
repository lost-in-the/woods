# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # DecoratorExtractor handles decorator, presenter, and form object extraction.
    #
    # Scans conventional directories for view-layer wrapper objects:
    # decorators (Draper-style or PORO), presenters, and form objects.
    # Extracts the decorated model relationship, delegation chains, and
    # whether the Draper gem is in use.
    #
    # @example
    #   extractor = DecoratorExtractor.new
    #   units = extractor.extract_all
    #   user_dec = units.find { |u| u.identifier == "UserDecorator" }
    #   user_dec.metadata[:decorated_model]  # => "User"
    #   user_dec.metadata[:uses_draper]      # => true
    #
    class DecoratorExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Directories to scan for decorator-style objects
      DECORATOR_DIRECTORIES = %w[
        app/decorators
        app/presenters
        app/form_objects
      ].freeze

      # Maps directory segment to decorator_type symbol
      DIRECTORY_TYPE_MAP = {
        'decorators' => :decorator,
        'presenters' => :presenter,
        'form_objects' => :form_object
      }.freeze

      # Suffixes used to infer the decorated model name
      DECORATOR_SUFFIXES = %w[Decorator Presenter Form].freeze

      def initialize
        @directories = DECORATOR_DIRECTORIES.map { |d| Rails.root.join(d) }
                                            .select(&:directory?)
      end

      # Extract all decorator, presenter, and form object units.
      #
      # @return [Array<ExtractedUnit>] List of decorator units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.rb')].filter_map do |file|
            extract_decorator_file(file)
          end
        end
      end

      # Extract a single decorator file.
      #
      # @param file_path [String] Absolute path to the Ruby file
      # @return [ExtractedUnit, nil] The extracted unit or nil if not a decorator
      def extract_decorator_file(file_path)
        source = File.read(file_path)
        class_name = extract_class_name(file_path, source)

        return nil unless class_name
        return nil if skip_file?(source)

        unit = ExtractedUnit.new(
          type: :decorator,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name, file_path)
        unit.metadata = extract_metadata(source, class_name, file_path)
        unit.dependencies = extract_dependencies(source, class_name)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract decorator #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      # Extract the class name from source or fall back to filename convention.
      #
      # Handles namespaced classes defined inside module blocks by combining
      # outer module names with the class name (e.g., module Admin / class
      # UserDecorator → "Admin::UserDecorator").
      #
      # @param file_path [String] Path to the file
      # @param source [String] Ruby source code
      # @return [String, nil] The class name or nil
      def extract_class_name(file_path, source)
        namespaces = source.scan(/^\s*module\s+([\w:]+)/).flatten
        class_match = source.match(/^\s*class\s+([\w:]+)/)

        if class_match
          base_class = class_match[1]
          if namespaces.any? && !base_class.include?('::')
            "#{namespaces.join('::')}::#{base_class}"
          else
            base_class
          end
        else
          relative = file_path.sub("#{Rails.root}/", '')
          relative
            .sub(%r{^app/(decorators|presenters|form_objects)/}, '')
            .sub('.rb', '')
            .camelize
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # Prepend a summary annotation header to the source.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] The class name
      # @param file_path [String] Path to the file
      # @return [String] Annotated source
      def annotate_source(source, class_name, file_path)
        decorator_type = infer_decorator_type(file_path)
        decorated_model = infer_decorated_model(class_name)

        annotation = <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Decorator: #{class_name.ljust(57)}║
          # ║ Type: #{decorator_type.to_s.ljust(62)}║
          # ║ Decorates: #{(decorated_model || 'unknown').ljust(57)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

        ANNOTATION

        annotation + source
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build the metadata hash for a decorator unit.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] The class name
      # @param file_path [String] Path to the file
      # @return [Hash] Decorator metadata
      def extract_metadata(source, class_name, file_path)
        {
          decorator_type: infer_decorator_type(file_path),
          decorated_model: infer_decorated_model(class_name),
          uses_draper: draper?(source),
          delegated_methods: extract_delegated_methods(source),
          public_methods: extract_public_methods(source),
          entry_points: detect_entry_points(source),
          class_methods: extract_class_methods(source),
          initialize_params: extract_initialize_params(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') }
        }
      end

      # Infer the decorator_type symbol from the file path.
      #
      # @param file_path [String] Absolute path to the file
      # @return [Symbol] :decorator, :presenter, or :form_object
      def infer_decorator_type(file_path)
        DIRECTORY_TYPE_MAP.each do |dir_segment, type|
          return type if file_path.include?("/#{dir_segment}/")
        end
        :decorator
      end

      # Infer the decorated model name by stripping known suffixes.
      #
      # @param class_name [String] e.g. "UserDecorator", "ProductPresenter"
      # @return [String, nil] e.g. "User", "Product", or nil if not inferable
      def infer_decorated_model(class_name)
        base = class_name.split('::').last
        DECORATOR_SUFFIXES.each do |suffix|
          return base.delete_suffix(suffix) if base.end_with?(suffix) && base.length > suffix.length
        end
        nil
      end

      # Detect whether the class uses the Draper gem.
      #
      # @param source [String] Ruby source code
      # @return [Boolean]
      def draper?(source)
        source.match?(/Draper::Decorator/)
      end

      # Extract method names passed to `delegate` calls.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Delegated method names
      def extract_delegated_methods(source)
        methods = []
        source.scan(/\bdelegate\s+(.*?)(?:,\s*to:|$)/m) do |match|
          match[0].scan(/:(\w+)/).flatten.each { |m| methods << m }
        end
        methods.uniq
      end

      # Detect common entry points for decorator invocation.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Entry point method names
      def detect_entry_points(source)
        points = []
        points << 'call'       if source.match?(/def (self\.)?call\b/)
        points << 'decorate'   if source.match?(/def (self\.)?decorate\b/)
        points << 'present'    if source.match?(/def (self\.)?present\b/)
        points << 'to_partial_path' if source.match?(/def to_partial_path\b/)
        points.empty? ? ['unknown'] : points
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build the dependency array for a decorator unit.
      #
      # Links to the decorated model via :decoration and scans the source
      # for common code references (models, services, jobs, mailers).
      #
      # @param source [String] Ruby source code
      # @param class_name [String] The class name
      # @return [Array<Hash>] Dependency hashes with :type, :target, :via
      def extract_dependencies(source, class_name)
        deps = []

        decorated_model = infer_decorated_model(class_name)
        deps << { type: :model, target: decorated_model, via: :decoration } if decorated_model

        deps.concat(scan_common_dependencies(source))

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
