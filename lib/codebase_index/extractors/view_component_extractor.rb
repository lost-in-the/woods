# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # ViewComponentExtractor handles ViewComponent extraction.
    #
    # ViewComponent components are Ruby classes that encapsulate view logic.
    # We can extract:
    # - Slot definitions (renders_one, renders_many)
    # - Sidecar template paths (.html.erb files next to the .rb file)
    # - Initialize parameters (the component's API)
    # - Preview classes (ViewComponent::Preview subclasses)
    # - Collection support
    # - Callbacks (before_render, after_render)
    # - Content areas (legacy API)
    # - Component dependencies (rendered sub-components, model references)
    #
    # @example
    #   extractor = ViewComponentExtractor.new
    #   units = extractor.extract_all
    #   card = units.find { |u| u.identifier == "CardComponent" }
    #
    class ViewComponentExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      def initialize
        @component_base = find_component_base
      end

      # Extract all ViewComponent components
      #
      # @return [Array<ExtractedUnit>] List of view component units
      def extract_all
        return [] unless @component_base

        @component_base.descendants.map do |component|
          extract_component(component)
        end.compact
      end

      # Extract a single ViewComponent component
      #
      # @param component [Class] The component class
      # @return [ExtractedUnit, nil] The extracted unit, or nil on failure
      def extract_component(component)
        return nil if component.name.nil?
        return nil if preview_class?(component)

        unit = ExtractedUnit.new(
          type: :view_component,
          identifier: component.name,
          file_path: source_file_for(component)
        )

        unit.source_code = read_source(unit.file_path)

        # Skip framework/internal components with no resolvable source
        return nil if unit.file_path.nil? && unit.source_code.empty?

        unit.namespace = extract_namespace(component)
        unit.metadata = extract_metadata(component, unit.source_code)
        unit.dependencies = extract_dependencies(component, unit.source_code)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract view component #{component.name}: #{e.message}")
        nil
      end

      private

      # Find the ViewComponent::Base class if the gem is loaded
      #
      # @return [Class, nil]
      def find_component_base
        return nil unless defined?(ViewComponent::Base)

        ViewComponent::Base
      end

      # Check if a class is a preview class (not a component itself)
      #
      # @param klass [Class]
      # @return [Boolean]
      def preview_class?(klass)
        defined?(ViewComponent::Preview) && klass < ViewComponent::Preview
      end

      # Locate the source file for a component class.
      #
      # Convention paths first, then introspection via {#resolve_source_location}
      # which filters out vendor/node_modules paths.
      #
      # @param component [Class]
      # @return [String, nil]
      def source_file_for(component)
        possible_paths = [
          Rails.root.join("app/components/#{component.name.underscore}.rb"),
          Rails.root.join("app/views/components/#{component.name.underscore}.rb")
        ]

        found = possible_paths.find { |p| File.exist?(p) }
        return found.to_s if found

        resolve_source_location(component, app_root: Rails.root.to_s, fallback: nil)
      end

      # @param file_path [String, nil]
      # @return [String]
      def read_source(file_path)
        return '' unless file_path && File.exist?(file_path)

        File.read(file_path)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_metadata(component, source)
        {
          slots: extract_slots(source),
          initialize_params: extract_initialize_params(component),
          public_methods: component.public_instance_methods(false),
          parent_component: component.superclass.name,
          sidecar_template: detect_sidecar_template(component),
          preview_class: detect_preview_class(component),
          collection_support: detect_collection_support(source),
          callbacks: extract_callbacks(source),
          content_areas: extract_content_areas(source),
          renders_many: extract_renders_many(source),
          renders_one: extract_renders_one(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') }
        }
      end

      # Extract slot definitions from renders_one / renders_many
      #
      # @param source [String]
      # @return [Array<Hash>]
      def extract_slots(source)
        slots = []

        source.scan(/renders_one\s+:(\w+)(?:,\s*(\w+(?:::\w+)*))?/) do |name, klass|
          slots << { name: name, type: :one, class: klass }
        end

        source.scan(/renders_many\s+:(\w+)(?:,\s*(\w+(?:::\w+)*))?/) do |name, klass|
          slots << { name: name, type: :many, class: klass }
        end

        slots
      end

      def extract_renders_many(source)
        source.scan(/renders_many\s+:(\w+)/).flatten
      end

      def extract_renders_one(source)
        source.scan(/renders_one\s+:(\w+)/).flatten
      end

      # Extract initialize parameters to understand the component's data requirements
      #
      # @param component [Class]
      # @return [Array<Hash>]
      def extract_initialize_params(component)
        method = component.instance_method(:initialize)
        params = method.parameters

        params.map do |type, name|
          param_type = case type
                       when :req then :required
                       when :opt then :optional
                       when :keyreq then :keyword_required
                       when :key then :keyword_optional
                       when :rest then :splat
                       when :keyrest then :double_splat
                       when :block then :block
                       else type
                       end
          { name: name, type: param_type }
        end
      rescue StandardError
        []
      end

      # Detect sidecar template file (.html.erb next to the .rb file)
      #
      # @param component [Class]
      # @return [String, nil] Path to sidecar template if found
      def detect_sidecar_template(component)
        base_path = Rails.root.join("app/components/#{component.name.underscore}")

        # Check common sidecar template patterns
        candidates = [
          "#{base_path}.html.erb",
          "#{base_path}.html.haml",
          "#{base_path}.html.slim",
          "#{base_path}/#{component.name.demodulize.underscore}.html.erb"
        ]

        candidates.find { |path| File.exist?(path) }
      rescue StandardError
        nil
      end

      # Detect if a preview class exists for this component
      #
      # @param component [Class]
      # @return [String, nil] Preview class name if found
      def detect_preview_class(component)
        return nil unless defined?(ViewComponent::Preview)

        preview_name = "#{component.name}Preview"
        klass = preview_name.safe_constantize
        klass&.name if klass && klass < ViewComponent::Preview
      rescue StandardError
        nil
      end

      # Detect if the component supports collection rendering
      #
      # @param source [String]
      # @return [Boolean]
      def detect_collection_support(source)
        source.match?(/with_collection_parameter/) ||
          source.match?(/def\s+self\.collection_parameter/)
      end

      # Extract before_render / after_render callbacks
      #
      # @param source [String]
      # @return [Array<Hash>]
      def extract_callbacks(source)
        callbacks = []

        source.scan(/before_render\s+:(\w+)/) do |name|
          callbacks << { kind: :before_render, method: name[0] }
        end

        source.scan(/after_render\s+:(\w+)/) do |name|
          callbacks << { kind: :after_render, method: name[0] }
        end

        # Also detect inline before_render method override
        callbacks << { kind: :before_render, method: :inline } if source.match?(/def\s+before_render\b/)

        callbacks
      end

      # Extract legacy content_areas definitions
      #
      # @param source [String]
      # @return [Array<String>]
      def extract_content_areas(source)
        source.scan(/with_content_areas\s+(.+)$/).flatten.flat_map do |area_list|
          area_list.scan(/:(\w+)/).flatten
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(component, source)
        deps = []

        # Other components rendered via render()
        source.scan(/render\s*\(?\s*(\w+(?:::\w+)*)\.new/).flatten.uniq.each do |comp|
          next if comp == component.name

          deps << { type: :component, target: comp, via: :render }
        end

        # Components rendered via slot classes
        source.scan(/renders_one\s+:\w+,\s*(\w+(?:::\w+)*)/).flatten.uniq.each do |comp|
          deps << { type: :component, target: comp, via: :slot }
        end

        source.scan(/renders_many\s+:\w+,\s*(\w+(?:::\w+)*)/).flatten.uniq.each do |comp|
          deps << { type: :component, target: comp, via: :slot }
        end

        # Model references
        deps.concat(scan_model_dependencies(source, via: :data_dependency))

        # Helper modules
        source.scan(/include\s+(\w+Helper)/).flatten.uniq.each do |helper|
          deps << { type: :helper, target: helper, via: :include }
        end

        # Stimulus controllers (from data-controller attributes in templates/source)
        source.scan(/data[_-]controller[=:]\s*["']([^"']+)["']/).flatten.uniq.each do |controller|
          deps << { type: :stimulus_controller, target: controller, via: :html_attribute }
        end

        # URL helpers
        source.scan(/(\w+)_(?:path|url)/).flatten.uniq.each do |route|
          deps << { type: :route, target: route, via: :url_helper }
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
