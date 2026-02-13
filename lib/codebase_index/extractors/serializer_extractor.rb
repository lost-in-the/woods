# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # SerializerExtractor handles extraction of serializers, blueprinters, and decorators.
    #
    # Serializers define the API contract — what data is exposed and how it's shaped.
    # They often wrap models, select attributes, and define associations that map
    # directly to JSON responses. Understanding these is critical for API-aware
    # code analysis.
    #
    # Supports:
    # - ActiveModel::Serializer (AMS)
    # - Blueprinter::Base
    # - Draper::Decorator
    #
    # @example
    #   extractor = SerializerExtractor.new
    #   units = extractor.extract_all
    #   user_serializer = units.find { |u| u.identifier == "UserSerializer" }
    #
    class SerializerExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Directories to scan for serializer-like files
      SERIALIZER_DIRECTORIES = %w[
        app/serializers
        app/blueprinters
        app/decorators
      ].freeze

      # Known base classes for runtime discovery
      BASE_CLASSES = {
        'ActiveModel::Serializer' => :ams,
        'Blueprinter::Base' => :blueprinter,
        'Draper::Decorator' => :draper
      }.freeze

      def initialize
        @directories = SERIALIZER_DIRECTORIES.map { |d| Rails.root.join(d) }
                                             .select(&:directory?)
      end

      # Extract all serializers, blueprinters, and decorators in the application
      #
      # @return [Array<ExtractedUnit>] List of serializer units
      def extract_all
        units = []

        # File-based discovery (catches everything in known directories)
        @directories.each do |dir|
          Dir[dir.join('**/*.rb')].each do |file|
            unit = extract_serializer_file(file)
            units << unit if unit
          end
        end

        # Class-based discovery for loaded gems
        seen = units.map(&:identifier).to_set
        BASE_CLASSES.each_key do |base_class_name|
          base_class = begin
            base_class_name.constantize
          rescue NameError
            nil
          end
          next unless base_class

          base_class.descendants.each do |klass|
            next if klass.name.nil?
            next if seen.include?(klass.name)

            unit = extract_serializer_class(klass, base_class_name)
            if unit
              units << unit
              seen << unit.identifier
            end
          end
        end

        units.compact
      end

      # Extract a serializer from its file
      #
      # @param file_path [String] Path to the serializer file
      # @return [ExtractedUnit, nil] The extracted unit, or nil if not a serializer
      def extract_serializer_file(file_path)
        source = File.read(file_path)
        class_name = extract_class_name(file_path, source)

        return nil unless class_name
        return nil unless serializer_file?(source)

        unit = ExtractedUnit.new(
          type: :serializer,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name)
        unit.metadata = extract_metadata_from_source(source, class_name)
        unit.dependencies = extract_dependencies(source)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract serializer #{file_path}: #{e.message}")
        nil
      end

      private

      # Extract a serializer from its class (runtime introspection)
      #
      # @param klass [Class] The serializer class
      # @param base_class_name [String] Name of the detected base class
      # @return [ExtractedUnit, nil] The extracted unit
      def extract_serializer_class(klass, base_class_name)
        return nil if klass.name.nil?

        file_path = source_file_for(klass)
        source = file_path && File.exist?(file_path) ? File.read(file_path) : ''

        unit = ExtractedUnit.new(
          type: :serializer,
          identifier: klass.name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(klass.name)
        unit.source_code = annotate_source(source, klass.name)
        unit.metadata = extract_metadata_from_class(klass, source, base_class_name)
        unit.dependencies = extract_dependencies(source)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract serializer #{klass.name}: #{e.message}")
        nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      def extract_class_name(file_path, source)
        return ::Regexp.last_match(1) if source =~ /^\s*class\s+([\w:]+)/

        # Fall back to convention
        file_path
          .sub(Rails.root.to_s + '/', '')
          .sub(%r{^app/(serializers|blueprinters|decorators)/}, '')
          .sub('.rb', '')
          .camelize
      end

      def serializer_file?(source)
        source.match?(/< ActiveModel::Serializer/) ||
          source.match?(/< Blueprinter::Base/) ||
          source.match?(/< Draper::Decorator/) ||
          source.match?(/< ApplicationSerializer/) ||
          source.match?(/< ApplicationDecorator/) ||
          source.match?(/< BaseSerializer/) ||
          source.match?(/< BaseBlueprinter/) ||
          source.match?(/attributes?\s+:/) ||
          source.match?(/has_many\s+:.*serializer/) ||
          source.match?(/belongs_to\s+:.*serializer/) ||
          source.match?(/view\s+:/) # Blueprinter views
      end

      def source_file_for(klass)
        methods = klass.instance_methods(false)
        if methods.any?
          klass.instance_method(methods.first).source_location&.first
        end || Rails.root.join("app/serializers/#{klass.name.underscore}.rb").to_s
      rescue StandardError
        nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      def annotate_source(source, class_name)
        serializer_type = detect_serializer_type(source)
        wrapped_model = detect_wrapped_model(source, class_name)

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Serializer: #{class_name.ljust(57)}║
          # ║ Type: #{serializer_type.to_s.ljust(61)}║
          # ║ Wraps: #{(wrapped_model || 'unknown').ljust(60)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      def detect_serializer_type(source)
        return :ams if source.match?(/< ActiveModel::Serializer/) || source.match?(/< ApplicationSerializer/)
        return :blueprinter if source.match?(/< Blueprinter::Base/) || source.match?(/< BaseBlueprinter/)
        return :draper if source.match?(/< Draper::Decorator/) || source.match?(/< ApplicationDecorator/)

        :unknown
      end

      def detect_wrapped_model(source, class_name)
        # AMS: `type` declaration
        return ::Regexp.last_match(1).classify if source =~ /type\s+[:"'](\w+)/

        # Draper: `decorates` declaration
        return ::Regexp.last_match(1).classify if source =~ /decorates\s+[:"'](\w+)/

        # Convention: strip Serializer/Decorator/Blueprinter suffix
        class_name
          .split('::')
          .last
          .sub(/Serializer$/, '')
          .sub(/Decorator$/, '')
          .sub(/Blueprinter$/, '')
          .sub(/Blueprint$/, '')
          .then { |name| name.empty? ? nil : name }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction (from source)
      # ──────────────────────────────────────────────────────────────────────

      def extract_metadata_from_source(source, class_name)
        {
          serializer_type: detect_serializer_type(source),
          wrapped_model: detect_wrapped_model(source, class_name),
          attributes: extract_attributes(source),
          associations: extract_associations(source),
          custom_methods: extract_custom_methods(source),
          views: extract_views(source),
          loc: source.lines.count { |l| l.strip.length > 0 && !l.strip.start_with?('#') }
        }
      end

      def extract_metadata_from_class(klass, source, base_class_name)
        base_metadata = extract_metadata_from_source(source, klass.name)
        base_metadata[:serializer_type] = BASE_CLASSES[base_class_name] || base_metadata[:serializer_type]

        # Enhance with runtime introspection if available
        if klass.respond_to?(:_attributes_data)
          # AMS runtime attributes
          runtime_attrs = klass._attributes_data.keys.map(&:to_s)
          base_metadata[:attributes] = runtime_attrs if runtime_attrs.any?
        elsif klass.respond_to?(:definition)
          # Blueprinter runtime fields
          definition = klass.definition
          base_metadata[:views] = definition.keys.map(&:to_s) if definition.respond_to?(:keys)
        end

        base_metadata
      end

      def extract_attributes(source)
        attrs = []

        # AMS / generic: `attributes :name, :email, :created_at`
        source.scan(/attributes?\s+((?::\w+(?:,\s*)?)+)/).each do |match|
          match[0].scan(/:(\w+)/).flatten.each { |a| attrs << a }
        end

        # Blueprinter: `field :name` or `identifier :id`
        source.scan(/(?:field|identifier)\s+:(\w+)/).flatten.each { |a| attrs << a }

        # Draper: `delegate :name, :email, to: :object`
        source.scan(/delegate\s+((?::\w+(?:,\s*)?)+)\s*,\s*to:\s*:object/).each do |match|
          match[0].scan(/:(\w+)/).flatten.each { |a| attrs << a }
        end

        attrs.uniq
      end

      def extract_associations(source)
        assocs = []

        # AMS: `has_many :comments`, `belongs_to :author`, `has_one :profile`
        source.scan(/(has_many|has_one|belongs_to)\s+:(\w+)(?:,\s*serializer:\s*([\w:]+))?/) do |type, name, serializer|
          assocs << { type: type, name: name, serializer: serializer }.compact
        end

        # Blueprinter: `association :comments, blueprint: CommentBlueprint`
        source.scan(/association\s+:(\w+)(?:,\s*blueprint:\s*([\w:]+))?/) do |name, blueprint|
          assocs << { type: 'association', name: name, serializer: blueprint }.compact
        end

        assocs
      end

      def extract_custom_methods(source)
        methods = []

        # Instance methods defined in the class (excluding standard callbacks)
        source.scan(/def\s+(\w+)/).flatten.each do |method_name|
          next if %w[initialize].include?(method_name)

          methods << method_name
        end

        methods
      end

      def extract_views(source)
        views = []

        # Blueprinter views: `view :extended do`
        source.scan(/view\s+:(\w+)/).flatten.each { |v| views << v }

        views
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(source)
        deps = []
        deps.concat(scan_model_dependencies(source, via: :serialization))

        # Other serializers referenced (e.g., `serializer: CommentSerializer`)
        source.scan(/(?:serializer|blueprint):\s*([\w:]+)/).flatten.uniq.each do |serializer|
          deps << { type: :serializer, target: serializer, via: :serialization }
        end

        deps.concat(scan_service_dependencies(source))

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
