# frozen_string_literal: true

require_relative 'shared_dependency_scanner'
require_relative 'route_helper_resolver'
require_relative 'view_engines/base'
require_relative 'view_engines/erb'

module Woods
  module Extractors
    # ViewTemplateExtractor orchestrates view-template extraction across
    # per-engine implementations under {ViewEngines}.
    #
    # For each configured view directory the orchestrator walks every
    # extension any registered engine handles, finds the first engine
    # whose {ViewEngines::Base#handles?} returns true for a given file,
    # and delegates parsing, scanning, and partial-identifier resolution
    # to that engine. The orchestrator itself owns filesystem walking,
    # identifier construction, controller inference, route-helper edge
    # resolution, and dependency assembly.
    #
    # Engines are registered via {ENGINES}. Add a new engine by creating
    # a {ViewEngines::Base} subclass and appending it to that list.
    #
    # @example
    #   extractor = ViewTemplateExtractor.new
    #   units = extractor.extract_all
    #   index = units.find { |u| u.identifier == "users/index.html.erb" }
    #
    class ViewTemplateExtractor
      include SharedDependencyScanner
      include RouteHelperResolver

      # Directories to scan for view templates.
      VIEW_DIRECTORIES = %w[
        app/views
      ].freeze

      # Registered view-template engines, in precedence order. The first
      # engine whose {ViewEngines::Base#handles?} returns true for a file
      # wins — place more specific engines before more general ones if
      # overlap is ever introduced.
      ENGINES = [ViewEngines::Erb].freeze

      # Template engine names the extraction pipeline currently
      # understands — aggregated from {ENGINES} so the list stays honest
      # as engines are added or removed. Surfaced through the MCP
      # `structure` tool.
      #
      # @return [Array<Symbol>]
      def self.supported_template_engines
        ENGINES.map { |klass| klass.new.name }.uniq.freeze
      end

      def initialize
        @directories = VIEW_DIRECTORIES.map { |d| Rails.root.join(d) }
                                       .select(&:directory?)
        @engines = self.class::ENGINES.map(&:new)
        build_route_helper_map
      end

      # Extract all view templates across the registered engines.
      #
      # @return [Array<ExtractedUnit>] List of view template units
      def extract_all
        extensions = @engines.flat_map(&:extensions).uniq
        @directories.flat_map do |dir|
          files = extensions.flat_map { |ext| Dir[dir.join("**/*#{ext}")] }
          files.uniq.filter_map { |file| extract_view_template_file(file) }
        end
      end

      # Extract a single view template file.
      #
      # @param file_path [String] Path to the template file
      # @return [ExtractedUnit, nil] The extracted unit, or nil if no
      #   registered engine handles the file
      def extract_view_template_file(file_path)
        engine = engine_for(file_path)
        return nil unless engine

        source = File.read(file_path)
        identifier = build_identifier(file_path)
        namespace = extract_view_namespace(file_path)

        unit = ExtractedUnit.new(
          type: :view_template,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace = namespace
        unit.source_code = source
        partials = engine.scan_partials(source)
        unit.metadata = build_metadata(engine, source, file_path, partials)
        unit.dependencies = build_dependencies(engine, source, file_path, identifier, partials)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract view template #{file_path}: #{e.message}")
        nil
      end

      private

      # Find the registered engine that handles the given file, if any.
      #
      # @param file_path [String]
      # @return [ViewEngines::Base, nil]
      def engine_for(file_path)
        @engines.find { |e| e.handles?(file_path) }
      end

      # Build a readable identifier from the file path.
      #
      # @param file_path [String] Absolute path to the template
      # @return [String] Relative identifier like "users/index.html.erb"
      def build_identifier(file_path)
        relative = file_path.sub("#{Rails.root}/", '')
        relative.sub(%r{^app/views/}, '')
      end

      # Extract namespace from directory structure.
      #
      # @param file_path [String] Absolute path
      # @return [String, nil] Namespace like "users" or "admin/users"
      def extract_view_namespace(file_path)
        identifier = build_identifier(file_path)
        dir = File.dirname(identifier)
        dir == '.' ? nil : dir
      end

      # Build metadata hash for the template.
      #
      # @param engine [ViewEngines::Base] Engine that matched this file
      # @param source [String] Template source code
      # @param file_path [String] Path to the template
      # @param partials [Array<String>] Pre-extracted partial names
      # @return [Hash]
      def build_metadata(engine, source, file_path, partials)
        {
          template_engine: engine.name.to_s,
          is_partial: partial?(file_path),
          partials_rendered: partials,
          instance_variables: engine.scan_instance_variables(source),
          helpers_called: engine.scan_helpers(source),
          loc: source.lines.count { |l| l.strip.length.positive? }
        }
      end

      # Check if a template is a partial (filename starts with _).
      #
      # @param file_path [String] Path to the template
      # @return [Boolean]
      def partial?(file_path)
        File.basename(file_path).start_with?('_')
      end

      # Build dependencies for the template.
      #
      # @param engine [ViewEngines::Base] Engine that matched this file
      # @param source [String] Template source code
      # @param file_path [String] Path to the template
      # @param identifier [String] Template identifier
      # @param partials [Array<String>] Pre-extracted partial names
      # @return [Array<Hash>]
      def build_dependencies(engine, source, file_path, identifier, partials)
        deps = []

        partials.each do |partial_name|
          partial_identifier = engine.resolve_partial_identifier(partial_name, identifier)
          deps << { type: :view_template, target: partial_identifier, via: :render }
        end

        controller = infer_controller(file_path)
        deps << { type: :controller, target: controller, via: :view_render } if controller

        deps.concat(scan_navigation_dependencies(source, via_type: :link_to))
        deps.concat(scan_form_dependencies(source))

        deps.uniq { |d| [d[:type], d[:target], d[:via]] }
      end

      # Infer the controller class from the template's directory path.
      #
      # @param file_path [String] Path to the template
      # @return [String, nil] Controller class name
      def infer_controller(file_path)
        namespace = extract_view_namespace(file_path)
        return nil unless namespace
        return nil if namespace == 'layouts'

        parts = namespace.split('/')
        controller_name = parts.map { |p| p.split('_').map(&:capitalize).join }.join('::')
        "#{controller_name}Controller"
      end
    end
  end
end
