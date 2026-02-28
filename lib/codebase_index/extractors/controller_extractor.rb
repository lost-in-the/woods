# frozen_string_literal: true

require 'digest'
require_relative 'ast_source_extraction'
require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # ControllerExtractor handles ActionController extraction with:
    # - Route mapping (which HTTP endpoints hit which actions)
    # - Before/after action filter chain resolution
    # - Per-action chunking for precise retrieval
    # - Concern inlining
    #
    # Controllers are chunked more aggressively than models because
    # queries are often action-specific ("how does the create action work").
    #
    # @example
    #   extractor = ControllerExtractor.new
    #   units = extractor.extract_all
    #   registrations = units.find { |u| u.identifier == "Users::RegistrationsController" }
    #
    class ControllerExtractor
      include AstSourceExtraction
      include SharedUtilityMethods
      include SharedDependencyScanner

      def initialize
        @routes_map = build_routes_map
      end

      # Extract all controllers in the application
      #
      # @return [Array<ExtractedUnit>] List of controller units
      def extract_all
        controllers = ApplicationController.descendants

        controllers = (controllers + ActionController::API.descendants).uniq if defined?(ActionController::API)

        controllers.map do |controller|
          extract_controller(controller)
        end.compact
      end

      # Extract a single controller
      #
      # @param controller [Class] The controller class
      # @return [ExtractedUnit] The extracted unit
      def extract_controller(controller)
        unit = ExtractedUnit.new(
          type: :controller,
          identifier: controller.name,
          file_path: source_file_for(controller)
        )

        source_path = unit.file_path
        source = source_path && File.exist?(source_path) ? File.read(source_path) : ''

        unit.namespace = extract_namespace(controller)
        unit.source_code = build_composite_source(controller, source)
        unit.metadata = extract_metadata(controller, source)
        unit.dependencies = extract_dependencies(controller, source)

        # Controllers benefit from per-action chunks
        unit.chunks = build_action_chunks(controller, unit)

        unit
      rescue StandardError => e
        Rails.logger.error("[CodebaseIndex] Failed to extract controller #{controller.name}: #{e.class}: #{e.message}")
        Rails.logger.error("[CodebaseIndex]   #{e.backtrace&.first(5)&.join("\n  ")}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Route Mapping
      # ──────────────────────────────────────────────────────────────────────

      # Build a map of controller -> action -> route info from Rails routes
      def build_routes_map
        routes = {}

        Rails.application.routes.routes.each do |route|
          next unless route.defaults[:controller]

          controller = "#{route.defaults[:controller].camelize}Controller"
          action = route.defaults[:action]

          routes[controller] ||= {}
          routes[controller][action] ||= []
          routes[controller][action] << {
            verb: extract_verb(route),
            path: route.path.spec.to_s.gsub('(.:format)', ''),
            name: route.name,
            constraints: route.constraints.except(:request_method)
          }
        end

        routes
      end

      def extract_verb(route)
        verb = route.verb
        return verb if verb.is_a?(String)
        return verb.source.gsub(/[\^$]/, '') if verb.respond_to?(:source)

        verb.to_s
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Building
      # ──────────────────────────────────────────────────────────────────────

      # Find the source file for a controller, validating paths are within Rails.root.
      #
      # Uses a multi-tier strategy to avoid returning gem/vendor paths that appear
      # when controllers include modules from gems (e.g., decent_exposure, appsignal).
      #
      # @param controller [Class] The controller class
      # @return [String] Absolute path to the controller source file
      def source_file_for(controller)
        app_root = Rails.root.to_s
        convention_path = Rails.root.join("app/controllers/#{controller.name.underscore}.rb").to_s

        # Tier 1: Instance methods defined directly on this controller
        controller.instance_methods(false).each do |method_name|
          loc = controller.instance_method(method_name).source_location&.first
          return loc if loc&.start_with?(app_root)
        end

        # Tier 2: Class/singleton methods defined on this controller
        controller.methods(false).each do |method_name|
          loc = controller.method(method_name).source_location&.first
          return loc if loc&.start_with?(app_root)
        end

        # Tier 3: Convention path if file exists
        return convention_path if File.exist?(convention_path)

        # Tier 4: const_source_location (Ruby 3.0+)
        if Object.respond_to?(:const_source_location)
          loc = Object.const_source_location(controller.name)&.first
          return loc if loc&.start_with?(app_root)
        end

        # Tier 5: Always return convention path — never a gem path
        convention_path
      rescue StandardError
        Rails.root.join("app/controllers/#{controller.name.underscore}.rb").to_s
      end

      # Build composite source with routes and filters as headers
      def build_composite_source(controller, source = nil)
        if source.nil?
          source_path = source_file_for(controller)
          return '' unless source_path && File.exist?(source_path)

          source = File.read(source_path)
        end

        # Prepend route information
        routes_comment = build_routes_comment(controller)

        # Prepend before_action chain
        filters_comment = build_filters_comment(controller)

        "#{routes_comment}\n#{filters_comment}\n#{source}"
      end

      def build_routes_comment(controller)
        routes = @routes_map[controller.name] || {}
        return '' if routes.empty?

        lines = routes.flat_map do |action, route_list|
          route_list.map do |info|
            verb = info[:verb].to_s.ljust(7)
            path = info[:path].ljust(45)
            "  #{verb} #{path} → ##{action}"
          end
        end

        <<~ROUTES
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Routes                                                                 ║
          # ╚═══════════════════════════════════════════════════════════════════════╝
          #
          #{lines.map { |l| "# #{l}" }.join("\n")}
          #
        ROUTES
      end

      def build_filters_comment(controller)
        filters = extract_filter_chain(controller)
        return '' if filters.empty?

        lines = filters.map do |f|
          opts = []
          opts << "only: [#{f[:only].map { |a| ":#{a}" }.join(', ')}]" if f[:only]&.any?
          opts << "except: [#{f[:except].map { |a| ":#{a}" }.join(', ')}]" if f[:except]&.any?
          opts << "if: #{f[:if]}" if f[:if]

          opts_str = opts.any? ? " (#{opts.join('; ')})" : ''
          "  #{f[:kind].to_s.ljust(8)} :#{f[:filter]}#{opts_str}"
        end

        <<~FILTERS
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Filter Chain                                                           ║
          # ╚═══════════════════════════════════════════════════════════════════════╝
          #
          #{lines.map { |l| "# #{l}" }.join("\n")}
          #
        FILTERS
      end

      def extract_filter_chain(controller)
        controller._process_action_callbacks.map do |callback|
          only, except, if_conds, unless_conds = extract_callback_conditions(callback)

          result = { kind: callback.kind, filter: callback.filter }
          result[:only] = only if only.any?
          result[:except] = except if except.any?
          result[:if] = if_conds.join(', ') if if_conds.any?
          result[:unless] = unless_conds.join(', ') if unless_conds.any?
          result
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Extract comprehensive metadata
      def extract_metadata(controller, source = nil)
        own_methods = controller.instance_methods(false).to_set(&:to_s)
        actions = controller.action_methods.select { |m| own_methods.include?(m) }.to_a

        {
          # Actions and routes
          actions: actions,
          routes: @routes_map[controller.name] || {},

          # Filter chain
          filters: extract_filter_chain(controller),

          # Parent chain for understanding inherited behavior
          ancestors: controller.ancestors
                     .take_while { |a| a != ActionController::Base && a != ActionController::API }
                     .grep(Class)
                     .map(&:name)
                     .compact,

          # Concerns included
          included_concerns: extract_included_concerns(controller),

          # Response formats
          responds_to: extract_respond_formats(controller, source),

          # Metrics
          action_count: actions.size,
          filter_count: controller._process_action_callbacks.count,

          # Strong parameters if definable
          permitted_params: extract_permitted_params(controller, source)
        }
      end

      def extract_included_concerns(controller)
        controller.included_modules
                  .select { |m| m.name&.include?('Concern') || m.name&.include?('Concerns') }
                  .map(&:name)
      end

      def extract_respond_formats(controller, source = nil)
        if source.nil?
          source_path = source_file_for(controller)
          return [] unless source_path && File.exist?(source_path)

          source = File.read(source_path)
        end

        formats = []

        formats << :html if source.include?('respond_to do') || !source.include?('respond_to')
        formats << :json if source.include?(':json') || source.include?('render json:')
        formats << :xml if source.include?(':xml') || source.include?('render xml:')
        formats << :turbo_stream if source.include?('turbo_stream')

        formats.uniq
      end

      def extract_permitted_params(controller, source = nil)
        if source.nil?
          source_path = source_file_for(controller)
          return {} unless source_path && File.exist?(source_path)

          source = File.read(source_path)
        end

        params = {}

        # Match params.require(:x).permit(...) patterns
        source.scan(/def\s+(\w+_params).*?params\.require\(:(\w+)\)\.permit\((.*?)\)/m) do |method, model, permitted|
          params[method] = {
            model: model,
            permitted: permitted.scan(/:(\w+)/).flatten
          }
        end

        params
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(controller, source = nil)
        deps = []

        if source.nil?
          source_path = source_file_for(controller)
          source = File.read(source_path) if source_path && File.exist?(source_path)
        end

        if source
          deps.concat(scan_common_dependencies(source))

          # Phlex component references
          source.scan(/render\s+(\w+(?:::\w+)*Component)/).flatten.uniq.each do |component|
            deps << { type: :component, target: component, via: :render }
          end

          # Other view renders
          source.scan(%r{render\s+["'](\w+/\w+)["']}).flatten.uniq.each do |template|
            deps << { type: :view, target: template, via: :render }
          end
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Per-Action Chunking
      # ──────────────────────────────────────────────────────────────────────

      # Build per-action chunks for precise retrieval
      def build_action_chunks(controller, unit)
        controller.action_methods.filter_map do |action|
          route_info = @routes_map.dig(controller.name, action.to_s)
          filters = applicable_filters(controller, action)

          # Extract just this action's source
          action_source = extract_action_source(controller, action)
          next if action_source.nil? || action_source.strip.empty?

          route_desc = if route_info&.any?
                         route_info.map { |r| "#{r[:verb]} #{r[:path]}" }.join(', ')
                       else
                         'No direct route'
                       end

          chunk_content = <<~ACTION
            # Controller: #{controller.name}
            # Action: #{action}
            # Route: #{route_desc}
            # Filters: #{filters.map { |f| "#{f[:kind]}(:#{f[:filter]})" }.join(', ').presence || 'none'}

            #{action_source}
          ACTION

          {
            chunk_type: :action,
            identifier: "#{controller.name}##{action}",
            content: chunk_content,
            content_hash: Digest::SHA256.hexdigest(chunk_content),
            metadata: {
              parent: unit.identifier,
              action: action.to_s,
              route: route_info,
              filters: filters,
              http_methods: route_info&.map { |r| r[:verb] }&.uniq || []
            }
          }
        end
      end

      def applicable_filters(controller, action)
        action_name = action.to_s

        applicable = controller._process_action_callbacks.select do |cb|
          callback_applies_to_action?(cb, action_name)
        end
        applicable.map { |cb| { kind: cb.kind, filter: cb.filter } }
      end

      # Determine if a callback applies to a given action name.
      #
      # Checks ActionFilter objects in @if (only) and @unless (except).
      # Non-ActionFilter conditions (procs, symbols) are assumed true.
      #
      # @param callback [ActiveSupport::Callbacks::Callback]
      # @param action_name [String]
      # @return [Boolean]
      def callback_applies_to_action?(callback, action_name)
        if_conditions = callback.instance_variable_get(:@if) || []
        unless_conditions = callback.instance_variable_get(:@unless) || []

        # Check @if conditions — all must pass for the callback to apply
        if_conditions.each do |cond|
          actions = extract_action_filter_actions(cond)
          next unless actions # skip non-ActionFilter conditions (assume true)
          return false unless actions.include?(action_name)
        end

        # Check @unless conditions — if any match, callback doesn't apply
        unless_conditions.each do |cond|
          actions = extract_action_filter_actions(cond)
          next unless actions
          return false if actions.include?(action_name)
        end

        true
      end
    end
  end
end
