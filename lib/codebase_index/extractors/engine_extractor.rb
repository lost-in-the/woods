# frozen_string_literal: true

require_relative 'shared_utility_methods'

module CodebaseIndex
  module Extractors
    # EngineExtractor handles Rails engine and mountable gem extraction via runtime introspection.
    #
    # Reads `Rails::Engine.subclasses` to discover engines, then inspects each engine's
    # routes, mount point, and configuration. Each engine becomes one ExtractedUnit with
    # metadata about its name, root path, mount point, route count, and isolation.
    #
    # @example
    #   extractor = EngineExtractor.new
    #   units = extractor.extract_all
    #   devise = units.find { |u| u.identifier == "Devise::Engine" }
    #
    class EngineExtractor
      include SharedUtilityMethods

      def initialize
        # No directories to scan — this is runtime introspection
      end

      # Extract all Rails engines as ExtractedUnits
      #
      # @return [Array<ExtractedUnit>] List of engine units
      def extract_all
        return [] unless engines_available?

        engines = Rails::Engine.subclasses
        return [] if engines.empty?

        mount_map = build_mount_map
        engines.filter_map { |engine| extract_engine(engine, mount_map) }
      end

      private

      # Check if Rails::Engine and the application routing table are available.
      #
      # @return [Boolean]
      def engines_available?
        defined?(Rails::Engine) &&
          Rails.respond_to?(:application) &&
          Rails.application.respond_to?(:routes)
      end

      # Build a mapping from engine class to mounted path by scanning app routes.
      #
      # @return [Hash{Class => String}] Engine class to mount path
      def build_mount_map
        map = {}
        Rails.application.routes.routes.each do |route|
          app = route.app
          next unless engine_class?(app)

          path = extract_mount_path(route)
          map[app] = path if path
        rescue StandardError
          next
        end
        map
      rescue StandardError
        {}
      end

      # Check if an object is a Rails::Engine subclass.
      #
      # Uses duck-typing: checks for engine_name method which is defined on all
      # Rails::Engine subclasses. Falls back to class hierarchy check.
      #
      # @param app [Object] The route app object
      # @return [Boolean]
      def engine_class?(app)
        return true if app.is_a?(Class) && defined?(Rails::Engine) && app < Rails::Engine
        return true if app.respond_to?(:engine_name) && app.respond_to?(:routes)

        false
      end

      # Extract the mount path string from a route object.
      #
      # @param route [ActionDispatch::Journey::Route]
      # @return [String, nil]
      def extract_mount_path(route)
        return nil unless route.respond_to?(:path) && route.path

        spec = route.path
        spec = spec.spec if spec.respond_to?(:spec)
        path = spec.to_s
        path.empty? ? nil : path
      end

      # Extract a single engine into an ExtractedUnit.
      #
      # @param engine [Class] A Rails::Engine subclass
      # @param mount_map [Hash] Engine-to-path mapping
      # @return [ExtractedUnit, nil]
      def extract_engine(engine, mount_map)
        name = engine.name
        engine_name = engine.engine_name
        root_path = engine.root.to_s
        route_count = count_engine_routes(engine)
        mounted_path = mount_map[engine]
        isolated = engine.respond_to?(:isolated?) ? engine.isolated? : false
        controllers = extract_engine_controllers(engine)

        unit = ExtractedUnit.new(
          type: :engine,
          identifier: name,
          file_path: nil
        )

        unit.namespace = extract_namespace(name)
        unit.source_code = build_engine_source(name, engine_name, root_path, mounted_path, route_count, isolated)
        unit.metadata = {
          engine_name: engine_name,
          root_path: root_path,
          mounted_path: mounted_path,
          route_count: route_count,
          isolate_namespace: isolated,
          controllers: controllers
        }
        unit.dependencies = build_engine_dependencies(controllers)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract engine #{engine.name}: #{e.message}")
        nil
      end

      # Count routes defined by an engine.
      #
      # @param engine [Class] A Rails::Engine subclass
      # @return [Integer]
      def count_engine_routes(engine)
        engine.routes.routes.count
      rescue StandardError
        0
      end

      # Extract controller names from engine routes.
      #
      # @param engine [Class] A Rails::Engine subclass
      # @return [Array<String>] Controller class names
      def extract_engine_controllers(engine)
        controllers = Set.new
        engine.routes.routes.each do |route|
          defaults = route.respond_to?(:defaults) ? route.defaults : {}
          controller = defaults[:controller]
          controllers << "#{controller.camelize}Controller" if controller
        rescue StandardError
          next
        end
        controllers.to_a
      rescue StandardError
        []
      end

      # Build a human-readable source representation of the engine.
      #
      # @param name [String] Engine class name
      # @param engine_name [String] Engine short name
      # @param root_path [String] Engine root directory
      # @param mounted_path [String, nil] Mount path in host app
      # @param route_count [Integer] Number of routes
      # @param isolated [Boolean] Whether engine uses isolate_namespace
      # @return [String]
      def build_engine_source(name, engine_name, root_path, mounted_path, route_count, isolated)
        lines = []
        lines << "# Engine: #{name}"
        lines << "# Name: #{engine_name}"
        lines << "# Root: #{root_path}"
        lines << "# Mounted at: #{mounted_path || '(not mounted)'}"
        lines << "# Routes: #{route_count}"
        lines << "# Isolated namespace: #{isolated}"
        lines.join("\n")
      end

      # Build dependencies linking engine to its controllers.
      #
      # @param controllers [Array<String>] Controller class names
      # @return [Array<Hash>]
      def build_engine_dependencies(controllers)
        controllers.map do |controller|
          { type: :controller, target: controller, via: :engine_route }
        end
      end
    end
  end
end
