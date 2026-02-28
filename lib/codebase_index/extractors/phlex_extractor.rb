# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # PhlexExtractor handles Phlex component extraction.
    #
    # Phlex components are Ruby classes, making them more introspectable
    # than ERB templates. We can extract:
    # - Slot definitions (renders_one, renders_many)
    # - Initialize parameters (the component's API)
    # - Component dependencies (what other components it renders)
    # - Helper usage
    # - Stimulus controller references
    #
    # @example
    #   extractor = PhlexExtractor.new
    #   units = extractor.extract_all
    #   card = units.find { |u| u.identifier == "Components::CardComponent" }
    #
    class PhlexExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Common Phlex base classes to look for
      PHLEX_BASES = %w[
        Phlex::HTML
        Phlex::Component
        ApplicationComponent
      ].freeze

      def initialize
        @component_base = find_component_base
      end

      # Extract all Phlex/ViewComponent components
      #
      # @return [Array<ExtractedUnit>] List of component units
      def extract_all
        return [] unless @component_base

        @component_base.descendants.map do |component|
          extract_component(component)
        end.compact
      end

      # Extract a single component
      #
      # @param component [Class] The component class
      # @return [ExtractedUnit] The extracted unit
      def extract_component(component)
        return nil if component.name.nil?

        unit = ExtractedUnit.new(
          type: :component,
          identifier: component.name,
          file_path: source_file_for(component)
        )

        unit.namespace = extract_namespace(component)
        unit.source_code = read_source(unit.file_path)
        unit.metadata = extract_metadata(component, unit.source_code)
        unit.dependencies = extract_dependencies(component, unit.source_code)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract component #{component.name}: #{e.message}")
        nil
      end

      private

      # Find the base component class used in the application.
      # Skips ApplicationComponent if it's actually a ViewComponent subclass
      # to avoid extracting ViewComponent classes with Phlex-specific metadata.
      #
      # @return [Class, nil]
      def find_component_base
        PHLEX_BASES.each do |base_name|
          klass = base_name.safe_constantize
          next unless klass
          next if base_name == 'ApplicationComponent' && view_component_subclass?(klass)

          return klass
        end
        nil
      end

      # Check if a class descends from ViewComponent::Base.
      #
      # @param klass [Class]
      # @return [Boolean]
      def view_component_subclass?(klass)
        defined?(ViewComponent::Base) && klass < ViewComponent::Base
      end

      # Locate the source file for a Phlex component class.
      #
      # Convention paths first, then introspection via {#resolve_source_location}
      # which filters out vendor/node_modules paths.
      #
      # @param component [Class]
      # @return [String, nil]
      def source_file_for(component)
        possible_paths = [
          Rails.root.join("app/views/components/#{component.name.underscore}.rb"),
          Rails.root.join("app/components/#{component.name.underscore}.rb"),
          Rails.root.join("app/views/#{component.name.underscore}.rb")
        ]

        found = possible_paths.find { |p| File.exist?(p) }
        return found.to_s if found

        resolve_source_location(component, app_root: Rails.root.to_s, fallback: nil)
      end

      def read_source(file_path)
        return '' unless file_path && File.exist?(file_path)

        File.read(file_path)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_metadata(component, source)
        {
          # Component API
          slots: extract_slots(component, source),
          initialize_params: extract_initialize_params(component),

          # Public interface
          public_methods: component.public_instance_methods(false),

          # Hierarchy
          parent_component: component.superclass.name,

          # Phlex-specific
          has_view_template: component.method_defined?(:view_template),

          # For rendering context
          renders_many: extract_renders_many(source),
          renders_one: extract_renders_one(source),

          # Metrics
          loc: source.lines.count { |l| l.strip.present? && !l.strip.start_with?('#') }
        }
      end

      # Extract slot definitions from Phlex components
      def extract_slots(_component, source)
        slots = []

        # Phlex 1.x style: renders_one, renders_many
        source.scan(/renders_one\s+:(\w+)(?:,\s*(\w+))?/) do |name, klass|
          slots << { name: name, type: :one, class: klass }
        end

        source.scan(/renders_many\s+:(\w+)(?:,\s*(\w+))?/) do |name, klass|
          slots << { name: name, type: :many, class: klass }
        end

        # Also check for slot method definitions
        source.scan(/def\s+(\w+)_slot/) do |name|
          slots << { name: name[0], type: :method }
        end

        slots
      end

      def extract_renders_many(source)
        source.scan(/renders_many\s+:(\w+)/).flatten
      end

      def extract_renders_one(source)
        source.scan(/renders_one\s+:(\w+)/).flatten
      end

      # Extract initialize parameters to understand component's data requirements
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

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(component, source)
        deps = []

        # Other components rendered
        # Phlex style: render ComponentName.new(...)
        source.scan(/render\s+(\w+(?:::\w+)*)(?:\.new|\()/).flatten.uniq.each do |comp|
          next if comp == component.name # Skip self-references

          deps << { type: :component, target: comp, via: :render }
        end

        # ViewComponent style: render(ComponentName.new(...))
        source.scan(/render\((\w+(?:::\w+)*)\.new/).flatten.uniq.each do |comp|
          next if comp == component.name

          deps << { type: :component, target: comp, via: :render }
        end

        # Model references (often passed as props)
        deps.concat(scan_model_dependencies(source, via: :data_dependency))

        # Helper modules
        source.scan(/include\s+(\w+Helper)/).flatten.uniq.each do |helper|
          deps << { type: :helper, target: helper, via: :include }
        end

        source.scan(/helpers\.(\w+)/).flatten.uniq.each do |method|
          deps << { type: :helper_method, target: method, via: :call }
        end

        # Stimulus controllers (from data-controller attributes)
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
