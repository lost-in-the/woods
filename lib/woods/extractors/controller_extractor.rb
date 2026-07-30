# frozen_string_literal: true

require 'digest'
require_relative 'ast_source_extraction'
require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'route_helper_resolver'

module Woods
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
      include RouteHelperResolver

      # @return [Array<String>] Warnings collected during extraction
      #   (concern-inlining fallbacks). Drained by the orchestrator, which
      #   collects warnings from every extractor that exposes them.
      attr_reader :warnings

      def initialize
        @routes_map = build_routes_map
        @concern_cache = {}
        @concern_module_cache = {}
        @warnings = []
        build_route_helper_map
      end

      # Extract all controllers in the application
      #
      # @return [Array<ExtractedUnit>] List of controller units
      def extract_all
        discoverable_classes.map do |controller|
          extract_controller(controller)
        end.compact
      end

      # The controller classes this extractor would extract from the running
      # app. Shared with the incremental path's class reconciliation (#164).
      #
      # Discovery walks +ActionController::Base.descendants+ and
      # +ActionController::API.descendants+ — not
      # +ApplicationController.descendants+, which excludes the receiver
      # (Class#descendants never includes the class itself, so
      # ApplicationController — usually the richest controller in the app —
      # was never indexed) and misses controllers inheriting straight from
      # +ActionController::Base+ (#200). Each base is guarded with
      # +defined?+ so a host missing one, or both (no NameError on hosts
      # without an ApplicationController constant), simply contributes
      # nothing.
      #
      # Framework-internal descendants (Rails::InfoController,
      # ActiveStorage controllers, engine controllers) share this ancestry
      # but live in gem source; {#app_defined_controller?} keeps them out.
      # That filter is shared with {#extract_controller} so this set stays
      # exactly the set extract_controller accepts — it is the incremental
      # reconciliation input, and any class listed here that
      # extract_controller rejects would be recomputed as a phantom
      # "addition" on every incremental run (same reasoning as
      # ViewComponentExtractor's preview filtering).
      #
      # @return [Array<Class>]
      def discoverable_classes
        controllers = []
        controllers.concat(ActionController::Base.descendants) if defined?(ActionController::Base)
        controllers.concat(ActionController::API.descendants) if defined?(ActionController::API)
        controllers.uniq.select { |controller| app_defined_controller?(controller) }
      end

      # Extract a single controller
      #
      # Rejects classes the extractor does not own — anonymous classes and
      # framework-internal controllers — via {#app_defined_controller?},
      # the same gate {#discoverable_classes} applies, so the two stay in
      # agreement for incremental class reconciliation.
      #
      # @param controller [Class] The controller class
      # @return [ExtractedUnit, nil] The extracted unit, or nil for classes
      #   the extractor rejects
      def extract_controller(controller)
        return nil unless app_defined_controller?(controller)

        unit = ExtractedUnit.new(
          type: :controller,
          identifier: controller.name,
          file_path: source_file_for(controller)
        )

        source_path = unit.file_path
        source = source_path && File.exist?(source_path) ? File.read(source_path) : ''

        unit.namespace = extract_namespace(controller)
        inlined_source, inlined_concerns = build_controller_source_with_concerns(controller, source)
        unit.source_code = build_composite_source(controller, inlined_source)
        unit.metadata = extract_metadata(controller, source, inlined_concerns: inlined_concerns)
        unit.dependencies = extract_dependencies(controller, source)

        # Controllers benefit from per-action chunks
        unit.chunks = build_action_chunks(controller, unit)

        unit
      rescue StandardError => e
        Rails.logger.error("[Woods] Failed to extract controller #{controller.name}: #{e.class}: #{e.message}")
        Rails.logger.error("[Woods]   #{e.backtrace&.first(5)&.join("\n  ")}")
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

      # Whether a controller class belongs to the host application.
      #
      # Discovery starts from the ActionController bases (#200), which
      # framework controllers (Rails::InfoController, ActiveStorage's
      # controllers, engine controllers) also descend from. App-defined
      # means: the class is named, and it resolves to an existing source
      # file that {SharedUtilityMethods#app_source?} accepts (under
      # +Rails.root+, outside vendor/ and node_modules/). Framework classes
      # resolve to gem paths, so {#source_file_for} falls back to a
      # convention path that does not exist and they are rejected.
      #
      # Shared by {#discoverable_classes} and {#extract_controller}; the
      # two must agree or the incremental class reconciliation recomputes
      # the same phantom "additions" every run.
      #
      # @param controller [Class] Candidate controller class
      # @return [Boolean]
      def app_defined_controller?(controller)
        return false if controller.name.nil?

        path = source_file_for(controller)
        return false unless path

        File.exist?(path) && app_source?(path, Rails.root.to_s)
      end

      # Find the source file for a controller, validating paths are within Rails.root.
      #
      # Convention path first, then introspection via {#resolve_source_location}
      # which filters out vendor/node_modules paths.
      #
      # @param controller [Class] The controller class
      # @return [String] Absolute path to the controller source file
      def source_file_for(controller)
        convention_path = Rails.root.join("app/controllers/#{controller.name.underscore}.rb").to_s
        return convention_path if File.exist?(convention_path)

        resolve_source_location(controller, app_root: Rails.root.to_s, fallback: convention_path)
      end

      # Build composite source with routes and filters as headers.
      #
      # Callers pass the already concern-inlined source (see
      # {#build_controller_source_with_concerns}); the nil fallback reads
      # from disk and inlines so both paths agree.
      def build_composite_source(controller, source = nil)
        if source.nil?
          source_path = source_file_for(controller)
          return '' unless source_path && File.exist?(source_path)

          source, = build_controller_source_with_concerns(controller, File.read(source_path))
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
      # Concern Detection & Inlining
      # ──────────────────────────────────────────────────────────────────────

      # Modules included in the controller that are application-defined
      # concerns.
      #
      # Detection is by membership, not name (#175): Rails does not
      # namespace controller concerns — app/controllers/concerns/
      # requires_author.rb defines top-level +RequiresAuthor+ — so the old
      # name-substring check ('Concern'/'Concerns') never matched idiomatic
      # controller concerns and +included_concerns+ came back empty while
      # the concern's effects (filters) were captured.
      #
      # @param controller [Class] The controller class
      # @return [Array<Module>] App-defined concern modules
      def detect_included_concerns(controller)
        controller.included_modules.select { |mod| app_concern_module?(mod) }
      end

      # Whether a module included in a controller is an application-defined
      # concern.
      #
      # A module counts when it extends +ActiveSupport::Concern+ (the
      # idiomatic case) OR its resolved source file sits under an
      # app/**/concerns directory (a plain module mixed in from concerns/
      # without the extend). Framework modules are excluded first: many gem
      # modules extend +ActiveSupport::Concern+ too
      # (ActionController::MimeResponds et al.), so any module whose source
      # resolves outside the app ({SharedUtilityMethods#app_source?}) is
      # rejected before either positive check runs. Verdicts are memoized
      # per module name — ApplicationController's includes recur in every
      # controller of the app.
      #
      # @param mod [Module] A module from the controller's included_modules
      # @return [Boolean]
      def app_concern_module?(mod)
        return false unless mod.name

        return @concern_module_cache[mod.name] if @concern_module_cache.key?(mod.name)

        @concern_module_cache[mod.name] = compute_app_concern_module(mod)
      end

      # Uncached concern verdict for a named module (see
      # {#app_concern_module?} for the detection rules).
      #
      # @param mod [Module] A named module
      # @return [Boolean]
      def compute_app_concern_module(mod)
        path = module_source_path(mod)
        return false if path && !app_source?(path, Rails.root.to_s)

        activesupport_concern?(mod) || concerns_directory_path?(path)
      end

      # Resolve a module's defining source file via const_source_location.
      #
      # @param mod [Module] A named module
      # @return [String, nil] Absolute path, or nil when unresolvable
      def module_source_path(mod)
        return nil unless Object.respond_to?(:const_source_location)

        Object.const_source_location(mod.name)&.first
      rescue StandardError
        nil
      end

      # Whether a module extends ActiveSupport::Concern (the idiomatic
      # concern marker). Membership lives on the singleton class.
      #
      # @param mod [Module] A module to test
      # @return [Boolean]
      def activesupport_concern?(mod)
        return false unless defined?(ActiveSupport::Concern)

        mod.singleton_class.include?(ActiveSupport::Concern)
      end

      # Whether a resolved source path sits under an app/**/concerns
      # directory (e.g. app/controllers/concerns/, app/models/concerns/).
      # Callers guarantee the path, when present, is app source.
      #
      # @param path [String, nil] Absolute path under Rails.root, or nil
      # @return [Boolean]
      def concerns_directory_path?(path)
        return false unless path

        relative = path.delete_prefix("#{Rails.root}/")
        relative.match?(%r{\Aapp/(?:[^/]+/)*concerns/})
      end

      # Read controller source and inline all detected concerns, mirroring
      # ModelExtractor's approach: concern code is inserted as '#'-prefixed
      # comment lines right after the class declaration (nested or compact
      # style), falling back to appending at end-of-source with a warning
      # rather than silently dropping the block.
      #
      # An empty source (missing file) is returned untouched — inlining
      # into nothing would fabricate source_code out of comments.
      #
      # @param controller [Class] The controller class
      # @param source [String, nil] Pre-read controller source (read from
      #   disk when nil)
      # @return [Array(String, Array<String>)] The concern-inlined source
      #   and the demodulized names of the concerns actually inlined into
      #   it. Returning the pair keeps metadata[:inlined_concerns] truthful
      #   — it is derived from the insertion result, never recomputed
      #   independently of what the composite source carries.
      def build_controller_source_with_concerns(controller, source = nil)
        if source.nil?
          source_path = source_file_for(controller)
          return ['', []] unless source_path && File.exist?(source_path)

          source = File.read(source_path)
        end

        return [source, []] if source.empty?

        concern_sources = resolved_concern_sources(controller)
        return [source, []] if concern_sources.empty?

        [insert_concern_block(controller, source, build_concern_block(concern_sources)),
         concern_sources.map { |name, _code| name.demodulize }]
      end

      # Resolve [name, code] pairs for every detected concern whose source
      # file can be located.
      #
      # @param controller [Class] The controller class
      # @return [Array<Array(String, String)>]
      def resolved_concern_sources(controller)
        detect_included_concerns(controller).filter_map { |mod| concern_source(mod) }
      end

      # Get the source code for a concern, with caching. Resolution reuses
      # {#module_source_path} — the same location detection validated — so
      # a concern detected purely by ActiveSupport::Concern membership with
      # no resolvable file keeps its edge and metadata entry but is not
      # inlined.
      #
      # @param mod [Module] A detected concern module
      # @return [Array(String, String), nil] [name, code] or nil
      def concern_source(mod)
        return @concern_cache[mod.name] if @concern_cache.key?(mod.name)

        path = module_source_path(mod)
        return nil unless path && File.exist?(path)

        @concern_cache[mod.name] = [mod.name, File.read(path)]
      end

      # Render concern sources as a '#'-commented display block showing
      # what's mixed in (same display form as ModelExtractor).
      #
      # @param concern_sources [Array<Array(String, String)>] [name, code] pairs
      # @return [String]
      def build_concern_block(concern_sources)
        concern_sources.map do |name, code|
          indented = code.lines.map { |l| "  # #{l.rstrip}" }.join("\n")
          <<~CONCERN
            # ┌─────────────────────────────────────────────────────────────────────┐
            # │ Included from: #{name.ljust(54)}│
            # └─────────────────────────────────────────────────────────────────────┘
            #{indented}
            # ─────────────────────────── End #{name} ───────────────────────────
          CONCERN
        end.join("\n\n")
      end

      # Insert the concern block after the controller's class declaration
      # line. Falls back to appending at end-of-source (recording a
      # warning) when no declaration matches — dropping the block silently
      # would leave source_code contradicting metadata[:inlined_concerns].
      #
      # @param controller [Class] The controller class
      # @param source [String] The controller source
      # @param concern_block [String] Commented concern block to insert
      # @return [String]
      def insert_concern_block(controller, source, concern_block)
        pattern = class_declaration_pattern(controller)
        return source.sub(pattern) { "#{::Regexp.last_match(1)}\n\n#{concern_block}" } if source.match?(pattern)

        @warnings << "[#{controller.name}] No class declaration matched for concern inlining; " \
                     'appending inlined concern block at end of source'
        "#{source.chomp}\n\n#{concern_block}"
      end

      # Regexp matching the controller's class declaration in either nested
      # (+class PostsController+) or compact
      # (+class Admin::PostsController+) style. The word boundary stops
      # +class PostsControllerError+ from claiming the block; the +(?!::)+
      # lookahead stops a nested +class PostsController::Error+ from
      # claiming it either.
      #
      # @param controller [Class] The controller class
      # @return [Regexp]
      def class_declaration_pattern(controller)
        /(class\s+(?:[\w:]+::)?#{Regexp.escape(controller.name.demodulize)}\b(?!::).*$)/
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Extract comprehensive metadata
      #
      # @param controller [Class] The controller class
      # @param source [String, nil] The raw controller source code
      # @param inlined_concerns [Array<String>, nil] Demodulized names of
      #   the concerns actually inlined into the unit's source_code (from
      #   {#build_controller_source_with_concerns}). When nil, derived by
      #   running the same inlining — the metadata must never claim a
      #   concern the composite source does not carry.
      # @return [Hash]
      def extract_metadata(controller, source = nil, inlined_concerns: nil)
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

          # Concerns included (detected by membership, not name — #175)
          included_concerns: extract_included_concerns(controller),

          # Concerns actually inlined into source_code (demodulized)
          inlined_concerns: inlined_concerns || build_controller_source_with_concerns(controller, source).last,

          # Response formats
          responds_to: extract_respond_formats(controller, source),

          # Metrics
          action_count: actions.size,
          filter_count: controller._process_action_callbacks.count,

          # Strong parameters if definable
          permitted_params: extract_permitted_params(controller, source)
        }
      end

      # Names of the app-defined concerns included in the controller.
      # Detection lives in {#detect_included_concerns} (#175).
      #
      # @param controller [Class] The controller class
      # @return [Array<String>] Full module names
      def extract_included_concerns(controller)
        detect_included_concerns(controller).map(&:name)
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
        # Included concerns add per-request behavior (filters, helpers).
        # Same edge shape as ModelExtractor's concern edges so graph
        # consumers see one format (#175).
        deps = detect_included_concerns(controller).map do |mod|
          { type: :concern, target: mod.name, via: :include }
        end

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

          # redirect_to with named route helpers
          deps.concat(scan_navigation_dependencies(source, via_type: :redirect_to))
        end

        consolidate_dependencies(deps)
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
