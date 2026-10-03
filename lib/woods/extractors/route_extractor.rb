# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'config_source_guard'

module Woods
  module Extractors
    # RouteExtractor handles Rails route extraction via runtime introspection.
    #
    # Unlike file-based extractors, RouteExtractor reads the live routing
    # table from `Rails.application.routes.routes`. Each route becomes an
    # ExtractedUnit with metadata about HTTP method, path, controller, and
    # action. A route that reaches no controller action (a mount, a redirect,
    # a Rack endpoint) carries a +kind+ and the endpoint it points at instead.
    #
    # Where the runtime exposes +route.source_location+ (Rails 8.0+, with
    # +ActionDispatch::Routing::Mapper.route_source_locations+ on, the
    # development default), a route drawn in +config/routes.rb+ or under
    # +config/routes/+ carries that file as its +file_path+, its line, and a
    # +drawn_in+ edge to the file's unit. Each of those files is also a
    # +route_file+ unit holding its source, the DSL calls it declares, the
    # files it draws and the routes located in it, so a draw file is indexed
    # even when the runtime exposes no locations. A route file must resolve
    # under the application root, and its published source is passed through
    # {ConfigSourceGuard.redact}.
    #
    # @example
    #   extractor = RouteExtractor.new
    #   units = extractor.extract_all
    #   login = units.find { |u| u.identifier == "POST /login" }
    #
    class RouteExtractor
      include SharedUtilityMethods

      # The root route file and the directory `draw` reads from.
      ROUTES_FILE = 'config/routes.rb'
      ROUTES_DIRECTORY = 'config/routes'

      # Routing DSL calls recorded as a route file's declarations.
      DECLARATION_METHODS = %w[
        get post put patch delete match root resources resource namespace scope
        mount draw concern concerns constraints direct resolve devise_for
      ].freeze
      DECLARATION = /\A\s*+(#{DECLARATION_METHODS.join('|')})\b\s*+\(?+\s*+(?::(\w++)|"([^"\\\n]*+)"|'([^'\\\n]*+)')?+/
      MAX_DECLARATIONS = 5_000

      def initialize
        # No directories to scan — this is runtime introspection
      end

      # Extract all routes from the Rails routing table, then one unit per
      # route file.
      #
      # @return [Array<ExtractedUnit>] route units followed by route_file units
      def extract_all
        return [] unless rails_routes_available?

        routes = Rails.application.routes.routes
        units = number_colliding_identifiers(routes.filter_map { |route| extract_route(route) })
        units + extract_route_files(units)
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Source locations and route files
      # ──────────────────────────────────────────────────────────────────────

      # @return [String, nil] the application root, when Rails exposes one
      def application_root
        return @application_root if defined?(@application_root)

        @application_root = defined?(Rails.root) && Rails.root ? Rails.root.to_s : nil
      end

      # Where a route was drawn, when the runtime recorded it and it names a
      # route file under the application root. Anything else (a gem frame, a
      # file outside the route files, a missing file) is no location: only
      # route files trigger a routes re-run, so only they can be kept current.
      #
      # @param route [ActionDispatch::Journey::Route]
      # @return [Hash, nil] +:file_path+, +:relative+ and +:line+
      def route_location(route)
        raw = route.respond_to?(:source_location) ? route.source_location : nil
        return nil unless raw.is_a?(String) && application_root

        path, _, line = raw.rpartition(':')
        return nil unless line.match?(/\A\d++\z/)

        relative = path.delete_prefix("#{application_root}/")
        return nil unless route_file?(relative)

        { file_path: File.join(application_root, relative), relative: relative, line: line.to_i }
      end

      def route_file?(relative)
        files = (@route_files ||= {})
        return files[relative] if files.key?(relative)

        named = relative == ROUTES_FILE || (relative.start_with?("#{ROUTES_DIRECTORY}/") && relative.end_with?('.rb'))
        files[relative] = named && !relative.split('/').include?('..') &&
                          ConfigSourceGuard.inside_root?(File.join(application_root, relative), application_root)
      end

      # Attach a recorded location to a route unit.
      #
      # @param unit [ExtractedUnit] a route unit with source, metadata and dependencies set
      # @param route [ActionDispatch::Journey::Route]
      # @return [ExtractedUnit]
      def locate(unit, route)
        location = route_location(route)
        return unit unless location

        unit.metadata[:line_number] = location[:line]
        unit.file_path = location[:file_path]
        unit.source_code = unit.source_code.sub("\n#\n", "\n# Source: #{location[:relative]}:#{location[:line]}\n#\n")
        unit.dependencies += [{ type: :route_file, target: location[:relative], via: :drawn_in }]
        unit
      end

      # One unit per route file: +config/routes.rb+ and every Ruby file under
      # +config/routes/+.
      #
      # @param route_units [Array<ExtractedUnit>] the extracted routes, identifiers final
      # @return [Array<ExtractedUnit>] route_file units sorted by identifier
      def extract_route_files(route_units)
        return [] unless application_root

        located = route_units.select(&:file_path).group_by(&:file_path)
        route_file_paths.filter_map do |relative|
          path = File.join(application_root, relative)
          build_route_file(relative, path, located.fetch(path, []), located.any?)
        end
      end

      def route_file_paths
        nested = Dir.glob("#{ROUTES_DIRECTORY}/**/*.rb", base: application_root)
        root_file = File.file?(File.join(application_root, ROUTES_FILE)) ? [ROUTES_FILE] : []
        (root_file + nested).uniq.sort.select { |relative| route_file?(relative) }
      end

      def build_route_file(relative, path, routes, source_locations)
        source = File.read(path, encoding: Encoding::UTF_8)
        raise Woods::ExtractionError, 'Source is not valid UTF-8' unless source.valid_encoding?

        source = ConfigSourceGuard.redact(source)
        declarations = route_declarations(source)
        draws = declarations.select { |entry| entry[:method] == 'draw' }.filter_map { |entry| entry[:argument] }.uniq
        unit = ExtractedUnit.new(type: :route_file, identifier: relative, file_path: path)
        unit.namespace = File.dirname(relative)
        unit.source_code = "# Route file: #{relative}\n\n#{source}"
        unit.metadata = { declarations: declarations, draws: draws, source_locations: source_locations,
                          routes: routes.map(&:identifier).sort, route_count: routes.size,
                          loc: source.lines.count { |line| !line.strip.empty? && !line.strip.start_with?('#') } }
        unit.dependencies = draws.map do |name|
          { type: :route_file, target: "#{ROUTES_DIRECTORY}/#{name}.rb", via: :draw }
        end
        unit
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract route file #{relative}: #{e.message}")
        nil
      end

      # The routing DSL calls a file makes, one per line that opens with one.
      # A static reading: it lists what the file declares, not the routes the
      # runtime expands a declaration into.
      #
      # @param source [String]
      # @return [Array<Hash>] +{ line:, method:, argument: }+ in file order
      def route_declarations(source)
        declarations = []
        source.each_line.with_index(1) do |line, number|
          match = DECLARATION.match(line)
          next unless match

          declarations << { line: number, method: match[1], argument: match[2] || match[3] || match[4] }
          break if declarations.size >= MAX_DECLARATIONS
        end
        declarations
      end

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

        return extract_endpoint_route(route) unless controller && action

        verb = route_verb(route)
        path = route_path(route)
        identifier = route_identifier(verb, path, route)

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

        locate(unit, route)
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract route: #{e.message}")
        nil
      end

      # Extract a route that dispatches to no controller action: a mount, a
      # `redirect(...)`, or a Rack endpoint object. Classified from the live
      # endpoint behind +route.app+, never from the routes file.
      #
      # A dispatcher endpoint here is a controller route whose action comes
      # from a path segment (`get ':action', controller: ...`); it names no
      # single action and stays skipped.
      #
      # @param route [ActionDispatch::Journey::Route]
      # @return [ExtractedUnit, nil]
      def extract_endpoint_route(route)
        app = route_endpoint(route)
        return nil if app.nil? || (app.respond_to?(:dispatcher?) && app.dispatcher?)

        kind = endpoint_kind(route, app)
        verb = endpoint_verb(route)
        path = route_path(route)

        unit = ExtractedUnit.new(
          type: :route,
          identifier: "#{route_identifier(verb, path, route)} (#{kind})",
          file_path: nil
        )
        unit.metadata = build_endpoint_metadata(kind, verb, path, app, route)
        unit.source_code = build_endpoint_source(unit.metadata, app)
        unit.dependencies = build_endpoint_dependencies(kind, app)
        locate(unit, route)
      end

      # The endpoint behind a route, unwrapped from the
      # ActionDispatch::Routing::Mapper::Constraints wrapper Rails puts around
      # every `to:` callable and mounted app. Only that wrapper is unwrapped:
      # an engine class also answers +app+ (its own middleware stack).
      #
      # @return [Object, nil]
      def route_endpoint(route)
        app = route.respond_to?(:app) ? route.app : nil
        5.times do
          break unless constraints_wrapper?(app)

          app = app.app
        end
        app
      end

      def constraints_wrapper?(app)
        defined?(ActionDispatch::Routing::Mapper::Constraints) &&
          app.is_a?(ActionDispatch::Routing::Mapper::Constraints)
      end

      # @return [String] "redirect", "mount" (an unanchored path, which is
      #   what `mount` draws), or "rack_endpoint"
      def endpoint_kind(route, app)
        return 'redirect' if defined?(ActionDispatch::Routing::Redirect) && app.is_a?(ActionDispatch::Routing::Redirect)

        path = route.respond_to?(:path) ? route.path : nil
        path.respond_to?(:anchored) && path.anchored == false ? 'mount' : 'rack_endpoint'
      end

      # `mount` and `via: :all` leave the verb blank; they answer every verb.
      def endpoint_verb(route)
        verb = route.respond_to?(:verb) ? route.verb : nil
        verb.present? ? route_verb(route) : 'ANY'
      end

      # @return [String] the class name of the endpoint, or of the mounted
      #   class itself
      def endpoint_name(app)
        name = app.is_a?(Module) ? app.name : app.class.name
        name || app.class.to_s
      end

      # Same test EngineExtractor uses to recognise an engine.
      def engine_endpoint?(app)
        return true if app.is_a?(Class) && defined?(Rails::Engine) && app < Rails::Engine

        app.is_a?(Class) && app.respond_to?(:engine_name) && app.respond_to?(:routes)
      end

      # @return [Hash]
      def build_endpoint_metadata(kind, verb, path, app, route)
        metadata = {
          kind: kind,
          http_method: verb,
          path: path,
          app: endpoint_name(app),
          route_name: route.respond_to?(:name) ? route.name : nil,
          constraints: route_constraints(route),
          path_params: path.scan(/:(\w+)/).flatten
        }
        return metadata unless kind == 'redirect'

        metadata.merge(redirect_target: redirect_target(app),
                       redirect_status: app.respond_to?(:status) ? app.status : nil)
      end

      # A path redirect holds its target string in +block+, an options
      # redirect its options hash; a block redirect is computed per request.
      #
      # @return [String]
      def redirect_target(app)
        if defined?(ActionDispatch::Routing::OptionRedirect) && app.is_a?(ActionDispatch::Routing::OptionRedirect)
          return app.options.sort_by { |key, _| key.to_s }.map { |key, value| "#{key}=#{value}" }.join(', ')
        end

        block = app.respond_to?(:block) ? app.block : nil
        block.is_a?(String) ? block : 'dynamic'
      end

      # @return [String]
      def build_endpoint_source(metadata, app)
        lines = ["# Route: #{metadata[:http_method]} #{metadata[:path]}"]
        lines << "# Name: #{metadata[:route_name]}" if metadata[:route_name]
        lines << "# Kind: #{metadata[:kind]}"
        lines << "# App: #{metadata[:app]}"
        lines << "# Constraints: #{metadata[:constraints].inspect}" if metadata[:constraints].any?
        lines << '#'
        lines << "# #{endpoint_declaration(metadata, app)}"
        lines.join("\n")
      end

      def endpoint_declaration(metadata, app)
        verb = metadata[:http_method]
        path = metadata[:path]
        case metadata[:kind]
        when 'mount' then "mount #{metadata[:app]} => '#{path}'"
        when 'redirect' then "#{verb.downcase} '#{path}', to: #{redirect_declaration(metadata, app)}"
        else "match '#{path}', to: #{metadata[:app]}, via: :#{verb == 'ANY' ? 'all' : verb.downcase}"
        end
      end

      def redirect_declaration(metadata, app)
        return 'redirect { ... }' if metadata[:redirect_target] == 'dynamic'
        return "redirect('#{metadata[:redirect_target]}')" unless app.respond_to?(:options)

        "redirect(#{app.options.map { |key, value| "#{key}: '#{value}'" }.join(', ')})"
      end

      # No route_dispatch edge: nothing here reaches a controller action. A
      # mounted engine links to the engine unit, whose identifier is the
      # engine class name.
      #
      # @return [Array<Hash>]
      def build_endpoint_dependencies(kind, app)
        return [] unless kind == 'mount' && engine_endpoint?(app)

        [{ type: :engine, target: app.name, via: :mount }]
      end

      # Identifier for a route: `VERB /path`, qualified by its request
      # constraints when it has any (B-127). Two routes that share a verb and
      # path but differ by subdomain, header, or format would otherwise
      # collapse into one unit, and the second silently vanished from the
      # index. Path-segment requirements (`id: /\d+/`) do not qualify: they
      # do not distinguish routes with the same path spec, and folding them
      # in would rename every `resources` route with an `id` constraint.
      #
      # @return [String] e.g. "GET /users" or "GET /users [subdomain=api]"
      def route_identifier(verb, path, route)
        base = "#{verb} #{path}"
        parts = identifier_constraints(path, route)
        parts.empty? ? base : "#{base} [#{parts.join(', ')}]"
      end

      # @return [Array<String>] sorted `key=value` pairs for the constraints
      #   that qualify the identifier, plus `constraint=proc` when the route
      #   is wrapped by a callable constraint
      def identifier_constraints(path, route)
        segment_keys = path.scan(/:(\w+)/).flatten.map(&:to_sym)
        pairs = route_constraints(route).reject { |key, _| segment_keys.include?(key.to_sym) }
        requirements = route.respond_to?(:requirements) && route.requirements.is_a?(Hash) ? route.requirements : {}
        pairs[:format] = requirements[:format] if requirements.key?(:format) && !pairs.key?(:format)

        parts = pairs.sort_by { |key, _| key.to_s }.map { |key, value| "#{key}=#{constraint_value(value)}" }
        parts << 'constraint=proc' if callable_constraint?(route)
        parts
      end

      def constraint_value(value)
        value.is_a?(Regexp) ? value.source : value.to_s
      end

      # A `constraints -> (req) { ... }` block wraps the endpoint in
      # ActionDispatch::Routing::Mapper::Constraints, which exposes the
      # callables as +constraints+.
      def callable_constraint?(route)
        app = route.respond_to?(:app) ? route.app : nil
        app.respond_to?(:constraints) && app.constraints.is_a?(Array) && app.constraints.any?
      end

      # Routes still sharing an identifier after constraints are applied
      # (two callable constraints, say) are numbered in route order:
      # `GET /users`, `GET /users #2`. Deterministic for a given routes file,
      # and the second route is indexed instead of dropped.
      def number_colliding_identifiers(units)
        seen = Hash.new(0)
        units.each do |unit|
          seen[unit.identifier] += 1
          next if seen[unit.identifier] == 1

          unit.identifier = "#{unit.identifier} ##{seen[unit.identifier]}"
        end
        units
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
