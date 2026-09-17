# frozen_string_literal: true

module Woods
  module Extractors
    # Shared module for resolving named route helpers to controller#action targets.
    #
    # Builds an inverse lookup from `Rails.application.routes.named_routes`,
    # mapping route helper names (e.g., "new_post") to their controller and action.
    # Include this module and call {#build_route_helper_map} in your initializer.
    #
    # @example
    #   class MyExtractor
    #     include RouteHelperResolver
    #
    #     def initialize
    #       build_route_helper_map
    #     end
    #
    #     def find_target(source)
    #       resolve_route_helper("posts_path")
    #       #=> { controller: "PostsController", action: "index", path: "/posts", verb: "GET" }
    #     end
    #   end
    #
    module RouteHelperResolver
      # Build the route helper lookup map from Rails named routes.
      # Call this once in your extractor's initialize method.
      #
      # Resilient to partial test doubles: any exception raised while
      # traversing Rails routes (unstubbed `application` on a double,
      # missing `named_routes`, etc.) is swallowed and leaves the map
      # empty — extractors omit unresolved navigation dependencies.
      def build_route_helper_map
        @route_helper_map = {}
        return unless defined?(Rails)

        routes = safe_rails_application_routes
        return unless routes

        # Rails lazy route sets do not load when named_routes is read. Use the
        # runtime route collection reader before caching helpers, just as the
        # route extractor does. Older route sets and partial doubles still work.
        routes.routes if routes.respond_to?(:routes)

        routes.named_routes.each do |name, route|
          controller = route.defaults[:controller]
          action = route.defaults[:action]
          next unless controller && action

          @route_helper_map[name.to_s] = {
            controller: "#{controller.camelize}Controller",
            action: action,
            path: route.path.spec.to_s.gsub('(.:format)', ''),
            verb: extract_route_verb(route)
          }
        end
      rescue StandardError
        # Leave @route_helper_map empty — navigation-edge extractors omit
        # helpers whose controller/action cannot be resolved.
        @route_helper_map = {}
      end

      # True when Rails.application.routes is reachable. Probing via
      # `respond_to?` first so partial RSpec doubles that haven't
      # stubbed `.application` don't raise MockExpectationError (which
      # descends from Exception, not StandardError — `rescue StandardError`
      # would not catch it).
      def safe_rails_application_routes
        return nil unless Rails.respond_to?(:application)

        app = Rails.application
        return nil unless app.respond_to?(:routes)

        app.routes
      rescue StandardError
        nil
      end

      # Resolve a _path/_url helper to its controller#action target.
      #
      # @param helper_name [String] e.g., "new_post_path", "users_url"
      # @return [Hash, nil] { controller:, action:, path:, verb: } or nil if unresolvable
      def resolve_route_helper(helper_name)
        base = helper_name.sub(/_(path|url)\z/, '')
        # A real named route is authoritative even when its name resembles
        # a filesystem or asset helper. Unresolved names still produce no edge.
        @route_helper_map&.[](base)
      end

      private

      # Extract the HTTP verb from a route.
      #
      # @param route [ActionDispatch::Journey::Route] The route object
      # @return [String] HTTP verb (GET, POST, etc.)
      def extract_route_verb(route)
        if route.respond_to?(:verb) && route.verb.is_a?(String)
          route.verb
        elsif route.respond_to?(:verb)
          route.verb.to_s.gsub(/[^A-Z|]/, '')
        else
          'GET'
        end
      end
    end
  end
end
