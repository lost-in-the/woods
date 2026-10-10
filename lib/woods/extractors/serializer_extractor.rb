# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative '../source_references/runtime_lookup'

module Woods
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
    # - Application-defined bases: every runtime descendant of a class this
    #   extractor admits from `app/serializers` or `app/blueprinters`
    # - Standalone classes under `app/serializers` named `*Serializer`
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

      # Directories whose admitted classes act as application serializer
      # bases. `app/decorators` is excluded: DecoratorExtractor owns it.
      APPLICATION_BASE_DIRECTORIES = %w[
        app/serializers
        app/blueprinters
      ].freeze

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
        find_files_in_directories(@directories).each do |file|
          unit = extract_serializer_file(file)
          units << unit if unit
        end

        # Class-based discovery for loaded gems and application bases
        bases = application_bases(units)
        seen = units.to_set(&:identifier)
        discoverable_classes(bases).each do |klass|
          next if seen.include?(klass.name)

          unit = extract_serializer_class(klass, bases)
          units << unit if unit
        end

        units.compact
      end

      # Extract a serializer from its file
      #
      # @param file_path [String] Path to the serializer file
      # @return [ExtractedUnit, nil] The extracted unit, or nil if not a serializer
      def extract_serializer_file(file_path)
        source = File.read(file_path)
        class_name = admitted_class_name(file_path, source)
        return nil unless class_name

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
        SourceInputs::ConsumerErrors.log(self, "Failed to extract serializer #{file_path}: #{e.message}")
        nil
      end

      # Current, named descendants of the supported runtime serializer bases
      # and of the application bases. Stale class objects retained after
      # Rails reload do not own their name.
      #
      # @param bases [Array<Class>] application bases; scanned when omitted
      # @return [Array<Class>]
      def discoverable_classes(bases = application_bases)
        roots = BASE_CLASSES.keys.filter_map(&:safe_constantize) + bases
        roots.flat_map(&:descendants).uniq.select do |klass|
          runtime_base_for(klass, bases)
        end
      end

      # Extract a serializer from its class (runtime introspection)
      #
      # @param klass [Class] The serializer class
      # @param bases [Array<Class>, nil] application bases; scanned when needed
      # @return [ExtractedUnit, nil] The extracted unit
      def extract_serializer_class(klass, bases = nil)
        base_class_name = runtime_base_for(klass, bases)
        return nil unless base_class_name

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
        SourceInputs::ConsumerErrors.log(self, "Failed to extract serializer #{klass.name}: #{e.message}")
        nil
      end

      private

      # The live constant and a supported ancestor jointly establish ownership.
      # @param klass [Class]
      # @param bases [Array<Class>, nil] application bases; scanned when needed
      # @return [String, nil] supported base name for a current serializer class
      def runtime_base_for(klass, bases = nil)
        return nil unless live_class?(klass)

        framework = BASE_CLASSES.keys.find do |name|
          base = name.safe_constantize
          base && klass < base
        end
        framework || (bases || application_bases).find { |base| klass < base }&.name
      end

      # @param klass [Object]
      # @return [Boolean] whether klass is a named class that still owns its name
      def live_class?(klass)
        return false unless klass.is_a?(Class) && klass.name

        SourceReferences::RuntimeLookup.new.call("::#{klass.name}", allow_private: true)[:value].equal?(klass)
      end

      # Live classes this extractor admits from {APPLICATION_BASE_DIRECTORIES}.
      # Their runtime descendants are serializers whatever their source says.
      #
      # @param units [Array<ExtractedUnit>, nil] file units already extracted;
      #   the directories are scanned when omitted
      # @return [Array<Class>]
      def application_bases(units = nil)
        directories = APPLICATION_BASE_DIRECTORIES.map { |d| Rails.root.join(d) }.select(&:directory?)
        identifiers =
          if units
            units.filter_map do |unit|
              unit.identifier if directories.any? { |dir| unit.file_path.to_s.start_with?("#{dir}/") }
            end
          else
            find_files_in_directories(directories).filter_map do |file|
              admitted_class_name(file, File.read(file))
            rescue StandardError
              nil
            end
          end

        identifiers.uniq.filter_map do |identifier|
          klass = SourceReferences::RuntimeLookup.new.call("::#{identifier}", allow_private: true)[:value]
          klass if live_class?(klass)
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      def extract_class_name(file_path, source)
        # Zeitwerk-governed naming (G-1), then position-aware (#174), then
        # convention.
        governed_class_name(file_path, source) || qualified_first_class_name(source) || file_path
          .sub("#{Rails.root}/", '')
          .sub(%r{^app/(serializers|blueprinters|decorators)/}, '')
          .sub('.rb', '')
          .camelize
      end

      # The file's identity when this extractor admits it, else nil.
      #
      # @param file_path [String]
      # @param source [String]
      # @return [String, nil]
      def admitted_class_name(file_path, source)
        class_name = extract_class_name(file_path, source)
        return nil unless class_name
        return class_name if serializer_file?(source) || standalone_serializer?(file_path, source, class_name)

        nil
      end

      # A class under `app/serializers` whose own name ends in `Serializer`.
      # Helper classes nested beside the base (`ApplicationSerializer::KeyParser`)
      # do not qualify.
      def standalone_serializer?(file_path, source, class_name)
        file_path.to_s.start_with?("#{Rails.root.join('app/serializers')}/") &&
          class_name.split('::').last.end_with?('Serializer') &&
          declares_class?(source, class_name)
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

      # Locate the source file for a serializer class.
      #
      # Convention path first, then introspection via {#resolve_source_location}
      # which filters out vendor/node_modules paths.
      #
      # Returns nil rather than a fabricated convention path when nothing
      # resolves, as {JobExtractor} does: a nonexistent `app/serializers/` path
      # enters the graph's file_map, and the next incremental run's safety-net
      # sweep prunes a unit a full extraction still emits.
      #
      # @param klass [Class]
      # @return [String, nil]
      def source_file_for(klass)
        convention_path = Rails.root.join("app/serializers/#{klass.name.underscore}.rb").to_s
        return convention_path if File.exist?(convention_path)

        resolve_source_location(klass, app_root: Rails.root.to_s, fallback: nil)
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
          parent_class: extract_parent_class(source, class_name),
          wrapped_model: detect_wrapped_model(source, class_name),
          attributes: extract_attributes(source),
          associations: extract_associations(source),
          custom_methods: extract_custom_methods(source),
          views: extract_views(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') }
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
        # Blueprinter views: `view :extended do`
        source.scan(/view\s+:(\w+)/).flatten
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
        deps.concat(scan_config_dependencies(source))

        consolidate_dependencies(deps)
      end
    end
  end
end
