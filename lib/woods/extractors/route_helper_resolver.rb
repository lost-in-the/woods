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
      # Route helper prefixes that produce non-navigation dependencies.
      # These generate asset URLs or are common false positives from
      # non-route uses of _path/_url suffixes in Ruby code.
      #
      # NOTE: `root` is intentionally excluded — root_path is the most common
      # Rails route helper, but it appears so frequently in non-navigation contexts
      # (path construction, config, tests) that it generates excessive noise.
      # The tradeoff: "what links to the home page?" won't appear in graph queries.
      # Add new prefixes here when false positives are discovered in host apps.
      IGNORED_HELPER_PREFIXES = %w[
        asset
        image
        stylesheet
        javascript
        font
        audio
        video
        turbo_stream
        file
        tmp
        base
        root
        log
        socket
        download
      ].freeze

      # Build the route helper lookup map from Rails named routes.
      # Call this once in your extractor's initialize method.
      def build_route_helper_map
        @route_helper_map = {}
        return unless defined?(Rails) && Rails.application&.routes

        Rails.application.routes.named_routes.each do |name, route|
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
      end

      # Resolve a _path/_url helper to its controller#action target.
      #
      # @param helper_name [String] e.g., "new_post_path", "users_url"
      # @return [Hash, nil] { controller:, action:, path:, verb: } or nil if unresolvable
      def resolve_route_helper(helper_name)
        base = helper_name.sub(/_(path|url)\z/, '')
        return nil if IGNORED_HELPER_PREFIXES.any? { |prefix| base.start_with?("#{prefix}_") || base == prefix }

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
