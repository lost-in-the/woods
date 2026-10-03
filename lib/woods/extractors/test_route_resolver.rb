# frozen_string_literal: true

require 'strscan'

require_relative 'route_extractor'

module Woods
  module Extractors
    # Resolves the navigation a feature, system or request test performs to
    # the route units it exercises.
    #
    # Recognized calls: `visit`, `get`, `post`, `put`, `patch`, `delete` and
    # `head`, given a route helper (`visit new_widget_path`) or a literal path
    # (`post "/widgets"`). A helper resolves through the live named-route map
    # to the route with the same path and the call's verb. A literal is matched
    # against each route's path pattern, in route order; an interpolation
    # stands for one segment value.
    #
    # Targets are the identifiers {RouteExtractor} emits, read from its own
    # output for the live route set, so an edge always names a route unit.
    # The result depends on the route table: the test mapping extractor is a
    # route consumer and re-runs when routes change.
    #
    # Not modeled, deliberately: segment constraints (a literal matches the
    # first route whose shape fits), the second and later verbs of a
    # multi-verb `match` route, and routes drawn inside mounted engines.
    #
    # @example
    #   TestRouteResolver.new.exercised(%(visit "/widgets/#{widget.id}"\npost widgets_path))
    #   # => ["GET /widgets/:id", "POST /widgets"]
    #
    class TestRouteResolver
      # A navigation call and its target. `visit` may follow a receiver
      # (`page.visit`); the request verbs may not (`cache.get` is not a request).
      NAVIGATION = %r{
        (?:(?<![\w:@$.])(visit|get|post|put|patch|delete|head)|(?<=\.)(visit))
        [ \t(]+
        (?:(?:main_app\.)?([a-z_]\w*_(?:path|url))\b|"(/[^"\n]*)"|'(/[^'\n]*)')
      }x

      COMMENT_LINE = /\A[ \t]*#/
      INTERPOLATION = /#\{[^}\n]*\}/
      # Longest literal worth matching; bounds the work of a path pattern.
      MAX_LITERAL_LENGTH = 512

      Route = Struct.new(:identifier, :verb, :path, :name, :prefix, keyword_init: true)

      def initialize
        @routes = load_routes
        @by_name = @routes.select(&:name).each_with_object({}) { |route, map| map[route.name] ||= route }
        @by_verb_and_path = @routes.each_with_object({}) { |route, map| map[[route.verb, route.path]] ||= route }
        @patterns = {}
        @literals = {}
      end

      # Route units the source exercises.
      #
      # @param source [String] Ruby source of a test file
      # @return [Array<String>] sorted, unique route identifiers
      def exercised(source)
        return [] if @routes.empty?

        source.each_line.flat_map do |line|
          next [] if line.match?(COMMENT_LINE)

          line.scan(NAVIGATION).filter_map { |captures| resolve(*captures) }
        end.uniq.sort
      end

      private

      def resolve(verb, receiver_visit, helper, interpolated, literal)
        verb = (verb || receiver_visit) == 'visit' ? 'GET' : verb.upcase
        return helper_route(verb, helper) if helper

        path = normalize(interpolated ? interpolated.gsub(INTERPOLATION, '1') : literal)
        path && literal_route(verb, path)
      end

      # @return [String, nil] the route with the helper's path and this verb
      def helper_route(verb, helper)
        named = @by_name[helper.sub(/_(?:path|url)\z/, '')]
        return nil unless named

        (named.verb == verb ? named : @by_verb_and_path[[verb, named.path]])&.identifier
      end

      # Drop the query string, fragment and trailing slash. A literal still
      # holding `#{` was cut short by a quote inside its interpolation.
      def normalize(path)
        return nil if path.include?('#{') || path.length > MAX_LITERAL_LENGTH

        path = path[/\A[^?#]*/].chomp('/')
        path.empty? ? '/' : path
      end

      def literal_route(verb, path)
        key = [verb, path]
        return @literals[key] if @literals.key?(key)

        @literals[key] = @routes.find do |route|
          route.verb == verb && path.start_with?(route.prefix) && pattern_for(route.path).match?(path)
        end&.identifier
      end

      def pattern_for(route_path)
        @patterns[route_path] ||= compile(route_path)
      end

      # Turn a route path spec into an anchored pattern: `:name` is one
      # segment value, `*name` spans segments, `( )` is optional. A format
      # extension is accepted after any path.
      def compile(route_path)
        scanner = StringScanner.new(route_path == '/' ? route_path : route_path.chomp('/'))
        pattern = +'\A'
        until scanner.eos?
          pattern << if scanner.scan(/:\w+/) then '[^/.?]+'
                     elsif scanner.scan(/\*\w+/) then '.+'
                     elsif scanner.scan('(') then '(?:'
                     elsif scanner.scan(')') then ')?'
                     else Regexp.escape(scanner.getch)
                     end
        end
        Regexp.new("#{pattern}(?:\\.\\w+)?\\z")
      end

      # Controller routes of the live route set, in route order.
      #
      # @return [Array<Route>]
      def load_routes
        RouteExtractor.new.extract_all.filter_map do |unit|
          metadata = unit.metadata
          next unless metadata[:action] && metadata[:path]

          path = metadata[:path].to_s
          Route.new(identifier: unit.identifier, verb: metadata[:http_method].to_s, path: path,
                    name: metadata[:route_name]&.to_s, prefix: path[/\A[^:*(]*/].chomp('/'))
        end
      rescue StandardError
        []
      end
    end
  end
end
