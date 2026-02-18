# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # RouteExtractor handles Rails route extraction via runtime introspection.
    #
    # Unlike file-based extractors, RouteExtractor reads the live routing
    # table from `Rails.application.routes.routes`. Each route becomes an
    # ExtractedUnit with metadata about HTTP method, path, controller, and
    # action.
    #
    # @example
    #   extractor = RouteExtractor.new
    #   units = extractor.extract_all
    #   login = units.find { |u| u.identifier == "POST /login" }
    #
    class RouteExtractor
      include SharedUtilityMethods

      def initialize
        # No directories to scan — this is runtime introspection
      end

      # Extract all routes from the Rails routing table
      #
      # @return [Array<ExtractedUnit>] List of route units
      def extract_all
        return [] unless rails_routes_available?

        routes = Rails.application.routes.routes
        routes.filter_map { |route| extract_route(route) }
      end

      private

      # Check if the Rails routing table is available.
      #
      # @return [Boolean]
      def rails_routes_available?
        defined?(Rails) &&
          Rails.respond_to?(:application) &&
          Rails.application.respond_to?(:routes) &&
          Rails.application.routes.respond_to?(:routes)
      end

      # Extract a single route into an ExtractedUnit.
      #
      # @param route [ActionDispatch::Journey::Route] A route object
      # @return [ExtractedUnit, nil]
      def extract_route(route)
        defaults = route_defaults(route)
        controller = defaults[:controller]
        action = defaults[:action]

        return nil unless controller && action

        verb = route_verb(route)
        path = route_path(route)
        identifier = "#{verb} #{path}"

        controller_class = "#{controller.camelize}Controller"

        unit = ExtractedUnit.new(
          type: :route,
          identifier: identifier,
          file_path: nil
        )

        unit.namespace = extract_namespace(controller_class)
        unit.source_code = build_route_source(verb, path, controller, action, route)
        unit.metadata = build_route_metadata(verb, path, controller, action, route)
        unit.dependencies = build_route_dependencies(controller_class)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract route: #{e.message}")
        nil
      end

      # Extract defaults hash from route, handling different Rails versions.
      #
      # @param route [ActionDispatch::Journey::Route]
      # @return [Hash]
      def route_defaults(route)
        if route.respond_to?(:defaults)
          route.defaults
        else
          {}
        end
      end

      # Extract HTTP verb from route.
      #
      # @param route [ActionDispatch::Journey::Route]
      # @return [String]
      def route_verb(route)
        if route.respond_to?(:verb) && route.verb.present?
          verb = route.verb
          verb.is_a?(String) ? verb : verb.to_s.scan(/[A-Z]+/).first
        else
          'GET'
        end.to_s
      end

      # Extract path pattern from route.
      #
      # @param route [ActionDispatch::Journey::Route]
      # @return [String]
      def route_path(route)
        if route.respond_to?(:path)
          spec = route.path
          spec = spec.spec if spec.respond_to?(:spec)
          spec.to_s.sub('(.:format)', '')
        else
          '/'
        end
      end

      # Build a human-readable source representation of the route.
      #
      # @param verb [String] HTTP method
      # @param path [String] URL path pattern
      # @param controller [String] Controller name (underscored)
      # @param action [String] Action name
      # @param route [ActionDispatch::Journey::Route]
      # @return [String]
      def build_route_source(verb, path, controller, action, route)
        name = route.respond_to?(:name) ? route.name : nil
        constraints = route_constraints(route)

        lines = []
        lines << "# Route: #{verb} #{path}"
        lines << "# Name: #{name}" if name
        lines << "# Controller: #{controller}##{action}"
        lines << "# Constraints: #{constraints.inspect}" if constraints.any?
        lines << '#'
        lines << "# #{verb.downcase} '#{path}', to: '#{controller}##{action}'"

        lines.join("\n")
      end

      # Build metadata hash for a route.
      #
      # @return [Hash]
      def build_route_metadata(verb, path, controller, action, route)
        {
          http_method: verb,
          path: path,
          controller: controller,
          action: action,
          route_name: route.respond_to?(:name) ? route.name : nil,
          constraints: route_constraints(route),
          path_params: path.scan(/:(\w+)/).flatten
        }
      end

      # Extract route constraints.
      #
      # @param route [ActionDispatch::Journey::Route]
      # @return [Hash]
      def route_constraints(route)
        if route.respond_to?(:constraints) && route.constraints.is_a?(Hash)
          route.constraints
        else
          {}
        end
      end

      # Build dependencies linking route to its controller.
      #
      # @param controller_class [String] The controller class name
      # @return [Array<Hash>]
      def build_route_dependencies(controller_class)
        [{ type: :controller, target: controller_class, via: :route_dispatch }]
      end
    end
  end
end
