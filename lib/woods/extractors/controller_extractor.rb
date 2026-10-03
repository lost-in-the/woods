# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

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

      # Matches everything between a `def foo_params` line and its
      # params.require/permit or params.expect call, without crossing into
      # a sibling method's body. Used by {#extract_permitted_params}.
      PARAMS_METHOD_BODY = /(?:(?!\bdef\b)[\s\S])*?/

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
      # Discovery walks the descendants of +ActionController::Base+,
      # +ActionController::API+ and +ActionController::Metal+ — not
      # +ApplicationController.descendants+, which excludes the receiver
      # (Class#descendants never includes the class itself, so
      # ApplicationController — usually the richest controller in the app —
      # was never indexed) and misses controllers inheriting straight from
      # +ActionController::Base+ (#200). Metal is walked too because a
      # controller built on the bare Rack layer (a health check, a webhook
      # endpoint) descends from neither of the other two. Each base is
      # guarded with +defined?+ so a host missing any of them simply
      # contributes nothing.
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
        controllers.concat(ActionController::Metal.descendants) if defined?(ActionController::Metal)
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
        action_sources = resolve_action_sources(controller)
        unit.source_code = build_composite_source(controller, inlined_source)
        unit.metadata = extract_metadata(controller, source, inlined_concerns: inlined_concerns,
                                                             action_sources: action_sources)
        unit.dependencies = extract_dependencies(controller, source, action_sources: action_sources)

        # Controllers benefit from per-action chunks
        unit.chunks = build_action_chunks(controller, unit)

        unit
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "[Woods] Failed to extract controller #{controller.name}: #{e.class}: #{e.message}")
        SourceInputs::ConsumerErrors.log(self, "[Woods]   #{e.backtrace&.first(5)&.join("\n  ")}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Route Mapping
      # ──────────────────────────────────────────────────────────────────────

      # Build a map of controller -> action -> route info from Rails routes.
      # Actions are key-sorted; each action's routes stay in route-table
      # order, which is the order Rails matches them in.
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

        routes.transform_values { |actions| actions.sort.to_h }
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
      # The sole caller ({#extract_controller}) always passes the
      # already concern-inlined source (see
      # {#build_controller_source_with_concerns}), which returns '' rather
      # than nil for a missing file — so this never sees a nil source.
      def build_composite_source(controller, source)
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
          opts << "unless: #{f[:unless]}" if f[:unless]

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
        process_action_callbacks(controller).map do |callback|
          only, except, if_conds, unless_conds = extract_callback_conditions(callback)

          result = { kind: callback.kind, filter: callback_filter(callback) }
          result[:only] = only.sort if only.any?
          result[:except] = except.sort if except.any?
          result[:if] = if_conds.join(', ') if if_conds.any?
          result[:unless] = unless_conds.join(', ') if unless_conds.any?
          result
        end
      end

      # A Metal controller has no callback chain until it includes a
      # callbacks module, so the chain is read only where it exists.
      #
      # @param controller [Class]
      # @return [Array<ActiveSupport::Callbacks::Callback>]
      def process_action_callbacks(controller)
        return [] unless controller.respond_to?(:_process_action_callbacks)

        controller._process_action_callbacks.to_a
      end

      # Whether a controller is built on the bare Rack layer rather than on
      # +ActionController::Base+ or +ActionController::API+.
      #
      # @param controller [Class]
      # @return [Boolean]
      def metal_controller?(controller)
        %w[Base API].filter_map { |name| action_controller_class(name) }.none? { |base| controller <= base }
      end

      # The framework classes the ancestor chain stops at.
      #
      # @return [Array<Class>]
      def framework_roots
        %w[Base API Metal].filter_map { |name| action_controller_class(name) }
      end

      # @param name [String] a class directly under ActionController
      # @return [Class, nil] nil when the host does not define it
      def action_controller_class(name)
        return nil unless defined?(ActionController) && ActionController.const_defined?(name, false)

        ActionController.const_get(name, false)
      end

      # Override only controller Proc conditions; the shared model/mailer
      # condition format is a separate extraction contract.
      def condition_label(condition)
        condition.is_a?(Proc) ? stable_filter(condition) : super
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
      # @return [Array<Module>] App-defined concern modules, sorted by name
      def detect_included_concerns(controller)
        controller.included_modules.select { |mod| app_concern_module?(mod) }.sort_by(&:name)
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
      # Action Selection
      # ──────────────────────────────────────────────────────────────────────

      # The controller's actions, each with where its method is defined.
      #
      # Starts from Rails' own +action_methods+ and admits a method only when
      # its body is application source: methods a gem DSL defines on the
      # class (+define_method+ from a gem file) and setters are not actions.
      # A method the class owns and defines in its own file is admitted
      # whether or not a route reaches it. Every other method (from an
      # included or prepended module, from the superclass chain, or defined
      # onto the class from another file) is admitted only when routed to
      # this controller: Rails counts the public helpers of every mixin and
      # base controller as actions, but they are not endpoints.
      #
      # @param controller [Class] The controller class
      # @return [Hash{String => Hash}] action name to
      #   +{ owner:, defined_in:, file:, line: }+, sorted by action name.
      #   +file+ is relative to Rails.root; +defined_in+ is the indexed unit
      #   whose source holds the method body, or nil when no unit does.
      def resolve_action_sources(controller)
        routed = routed_actions(controller)
        own_file = source_file_for(controller)

        action_method_names(controller).each_with_object({}) do |name, sources|
          next if name.end_with?('=')

          method = controller.instance_method(name)
          file, line = method.source_location
          next unless app_action_source?(file)
          next unless routed.include?(name) || (method.owner == controller && same_file?(file, own_file))

          sources[name] = {
            owner: method.owner.name,
            defined_in: defining_unit(method.owner, file),
            file: relative_to_root(file),
            line: line
          }
        end
      end

      # Routed actions Rails can dispatch whose body is gem code: inherited
      # from a gem superclass, mixed in from a gem module, or defined onto the
      # class by a gem DSL. They are not admitted as actions (the index holds
      # no unit for the body, so there is nothing to chunk or trace), but a
      # route to one resolves at runtime and must not read as a dead route.
      #
      # @param controller [Class] The controller class
      # @return [Hash{String => Hash}] action name to +{ owner: }+, the name
      #   of the module or class that defines the method, sorted by action
      def resolve_inherited_gem_actions(controller)
        routed = routed_actions(controller)

        action_method_names(controller).each_with_object({}) do |name, actions|
          next if name.end_with?('=') || !routed.include?(name)

          method = controller.instance_method(name)
          next if app_action_source?(method.source_location&.first)

          actions[name] = { owner: method.owner.name }
        end
      end

      # Rails' +action_methods+ is a Set whose order follows method
      # definition and inclusion order, so it is sorted before anything
      # derived from it is emitted.
      #
      # @param controller [Class]
      # @return [Array<String>]
      def action_method_names(controller)
        controller.action_methods.map(&:to_s).sort
      end

      # @param controller [Class]
      # @return [Set<String>] actions a route dispatches to on this controller
      def routed_actions(controller)
        (@routes_map[controller.name] || {}).keys.to_set(&:to_s)
      end

      # Whether a method body lives in application source: under Rails.root,
      # outside vendor/ and node_modules/, and outside any installed gem path
      # (a bundle installed inside the app root).
      #
      # @param file [String, nil] Method source file
      # @return [Boolean]
      def app_action_source?(file)
        return false unless app_source?(file, Rails.root.to_s)

        absolute = File.expand_path(file)
        gem_install_paths.none? { |dir| absolute.start_with?(dir) }
      end

      # @return [Array<String>] Installed gem directories, separator-terminated
      def gem_install_paths
        @gem_install_paths ||= begin
          dirs = Gem.path.dup
          dirs << Bundler.bundle_path.to_s if defined?(Bundler) && Bundler.respond_to?(:bundle_path)
          dirs.map { |dir| File.expand_path(dir).delete_suffix(File::SEPARATOR) + File::SEPARATOR }.uniq
        rescue StandardError
          []
        end
      end

      # The indexed unit whose source holds a method owned by +owner+.
      #
      # Walks the owner's namespace from the innermost name outward and takes
      # the first constant that is extracted as a unit from the method's own
      # file: an app controller class, or a module in a concerns directory. A
      # module nested inside a controller resolves to that controller.
      #
      # @param owner [Module] The method's owner
      # @param file [String] The method's source file
      # @return [String, nil]
      def defining_unit(owner, file)
        return nil unless owner.name

        parts = owner.name.split('::')
        parts.size.downto(1) do |count|
          name = parts.first(count).join('::')
          return name if unit_holding?(constant_named(name), file)
        end
        nil
      end

      # @param candidate [Module, nil]
      # @param file [String]
      # @return [Boolean]
      def unit_holding?(candidate, file)
        case candidate
        when Class
          app_defined_controller?(candidate) && same_file?(source_file_for(candidate), file)
        when Module
          same_file?(module_source_path(candidate), file) && concerns_directory_path?(File.expand_path(file))
        else
          false
        end
      end

      # @param name [String]
      # @return [Module, nil]
      def constant_named(name)
        Object.const_get(name)
      rescue NameError
        nil
      end

      def same_file?(left, right)
        left && right && File.expand_path(left) == File.expand_path(right)
      end

      def relative_to_root(file)
        File.expand_path(file).delete_prefix("#{File.expand_path(Rails.root.to_s)}#{File::SEPARATOR}")
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
      # @param action_sources [Hash{String => Hash}, nil] From
      #   {#resolve_action_sources}; computed when nil
      # @return [Hash]
      def extract_metadata(controller, source = nil, inlined_concerns: nil, action_sources: nil)
        action_sources ||= resolve_action_sources(controller)
        actions = action_sources.keys

        {
          # Actions and routes
          actions: actions,
          action_sources: action_sources,
          inherited_gem_actions: resolve_inherited_gem_actions(controller),
          routes: @routes_map[controller.name] || {},

          # Filter chain
          filters: extract_filter_chain(controller),

          # Runtime superclass, e.g. ApplicationController or ActionController::Metal
          parent_class: controller.superclass&.name,

          # Parent chain for understanding inherited behavior
          ancestors: controller.ancestors
                               .take_while { |a| !framework_roots.include?(a) }
                               .grep(Class)
                               .map(&:name)
                               .compact,

          # Built on ActionController::Metal rather than Base or API
          metal: metal_controller?(controller),

          # Concerns included (detected by membership, not name — #175)
          included_concerns: extract_included_concerns(controller),

          # Concerns actually inlined into source_code (demodulized)
          inlined_concerns: inlined_concerns || build_controller_source_with_concerns(controller, source).last,

          # Response formats
          responds_to: extract_respond_formats(controller, source),

          # Metrics
          action_count: actions.size,
          filter_count: process_action_callbacks(controller).count,

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

      # Strong-parameter declarations, keyed by the `*_params` method name.
      #
      # Each entry is `{ model:, permitted: }`. `permitted` is the list of
      # keys named at the TOP level of the `permit`/`expect` call — scalar
      # symbols and hash keys alike — and never the members of a nested list
      # or hash: `permit(:title, tags: [], meta: {seo: [:keyword]})` yields
      # `%w[title tags meta]`. See {#permitted_keys}.
      #
      # @param controller [Class, nil] Controller class (used only to locate
      #   the source when +source+ is not supplied)
      # @param source [String, nil] Controller source code
      # @return [Hash{String => Hash}] `{ method_name => { model:, permitted: } }`
      def extract_permitted_params(controller, source = nil)
        if source.nil?
          source_path = source_file_for(controller)
          return {} unless source_path && File.exist?(source_path)

          source = File.read(source_path)
        end

        params = {}

        # Match params.require(:x).permit(...) patterns. The body segment
        # between the method name and the require/permit call is bounded by
        # a negative lookahead on `def` so a method with no permit call
        # (e.g. `filter_params; params.fetch(:f); end`) never lets the scan
        # run into the *next* method's body and misattribute its params.
        # The /m flag plus a [\s\S] capture let the permit list cross
        # newlines — the common style in large controllers (M2); without
        # them `permit(` followed by a newline matched nothing and
        # permitted_params came back empty. The `\s*` around each chain joint
        # covers the fluent style the M2 fix missed (EXTA-5): the list could
        # cross newlines but the call chain itself still could not, so
        # `params.require(:post)\n  .permit(...)` matched nothing.
        source.scan(
          /def\s+(\w+_params)\b#{PARAMS_METHOD_BODY}
           params\s*\.\s*require\(:(\w+)\)\s*\.\s*permit\(([\s\S]*?)\)/xm
        ) do |method, model, permitted|
          params[method] = { model: model, permitted: permitted_keys(permitted) }
        end

        # Rails 8's params.expect(post: [:title, :body]) replacement for
        # require(...).permit(...). Same multi-line capture as above (M2).
        source.scan(
          /def\s+(\w+_params)\b#{PARAMS_METHOD_BODY}
           params\s*\.\s*expect\(\s*(\w+):\s*\[([\s\S]*?)\]\s*\)/xm
        ) do |method, model, permitted|
          params[method] ||= { model: model, permitted: permitted_keys(permitted) }
        end

        params
      end

      # The top-level keys of a permit/expect argument list.
      #
      # The contract is deliberately flat and shallow: every key the caller
      # names at the top level, whether declared as a scalar symbol
      # (`:title`) or as a hash key (`tags: []`, `meta: {…}`), and nothing
      # from inside a nested list or hash. Scanning for `:(\w+)` alone
      # produced neither contract — hash keys, which is how every array and
      # nested param is declared, were dropped while their nested leaves
      # leaked in flat, so `permit(:title, tags: [], meta: {seo: [:keyword]})`
      # reported `title, keyword` (EXTA-12).
      #
      # @param list [String] Raw text between `permit(`/`expect(…[` and its close
      # @return [Array<String>] Top-level key names, in source order
      def permitted_keys(list)
        top_level_arguments(list).scan(/:(\w+)|(\w+):/).map { |symbol, key| symbol || key }.uniq
      end

      # Drop everything inside nested `[...]` / `{...}` groups, leaving the
      # argument list's own tokens.
      #
      # @param list [String]
      # @return [String]
      def top_level_arguments(list)
        depth = 0
        list.each_char.with_object(+'') do |char, kept|
          case char
          when '[', '{' then depth += 1
          when ']', '}' then depth -= 1 if depth.positive?
          else kept << char if depth.zero?
          end
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(controller, source = nil, action_sources: nil)
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

        # consolidate_dependencies keeps one edge per (type, target), so the
        # structural edges join afterwards: a controller that redirects to
        # its parent keeps that edge as well as the inheritance one.
        structural = action_source_dependencies(controller, action_sources || resolve_action_sources(controller))
        (consolidate_dependencies(deps) + structural).uniq { |dep| dep.values_at(:type, :target, :via) }
      end

      # Edges to the units that hold the bodies of actions this controller
      # does not define itself. Editing that unit's file changes the action,
      # so the edge puts this controller in the blast radius and flow scope.
      #
      # @param controller [Class]
      # @param action_sources [Hash{String => Hash}]
      # @return [Array<Hash>]
      def action_source_dependencies(controller, action_sources)
        holders = action_sources.values.filter_map { |source| source[:defined_in] }.uniq - [controller.name]
        deps = holders.map do |holder|
          type = constant_named(holder).is_a?(Class) ? :controller : :concern
          { type: type, target: holder, via: :action_source }
        end
        deps << superclass_dependency(controller)
        deps.compact
      end

      # An edge to an app-defined parent controller. A method the parent
      # gains can become a routed action of this controller, so editing the
      # parent must re-extract it even before any action comes from there.
      #
      # @param controller [Class]
      # @return [Hash, nil]
      def superclass_dependency(controller)
        parent = controller.superclass
        return nil unless parent.is_a?(Class) && app_defined_controller?(parent)

        { type: :controller, target: parent.name, via: :inheritance }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Per-Action Chunking
      # ──────────────────────────────────────────────────────────────────────

      # Build per-action chunks for precise retrieval, one per admitted
      # action (+metadata[:actions]+). Rails' +action_methods+ also lists
      # gem DSL methods, setters, unrouted mixin helpers and gem-inherited
      # actions, none of which is an indexed action.
      def build_action_chunks(controller, unit)
        Array(unit.metadata[:actions]).filter_map do |action|
          route_info = @routes_map.dig(controller.name, action.to_s)
          filters = applicable_filters(controller, action)

          action_source, declaration_line = chunk_source(controller, action)
          next unless action_source

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

          metadata = {
            parent: unit.identifier,
            action: action.to_s,
            route: route_info,
            filters: filters,
            http_methods: route_info&.map { |r| r[:verb] }&.uniq || []
          }
          metadata[:declaration_line] = declaration_line if declaration_line

          {
            chunk_type: :action,
            identifier: "#{controller.name}##{action}",
            content: chunk_content,
            content_hash: Digest::SHA256.hexdigest(chunk_content),
            metadata: metadata
          }
        end
      end

      # The source an action chunk holds: the action's +def+ body, or, for
      # an action with no +def+ (an +attr_reader+, or a method a DSL defines
      # from its own file), the line Ruby reports as its definition site.
      #
      # @param controller [Class]
      # @param action [String]
      # @return [Array(String, Integer), Array(String, nil), Array(nil, nil)]
      #   the source and, for a declaration, its line number
      def chunk_source(controller, action)
        body = extract_action_source(controller, action)
        return [body, nil] if body && !body.strip.empty?

        file, line = controller.instance_method(action).source_location
        declaration = declaration_line_text(file, line)
        declaration ? [declaration, line] : [nil, nil]
      rescue NameError
        [nil, nil]
      end

      # @param file [String, nil]
      # @param line [Integer, nil]
      # @return [String, nil] the stripped line, or nil when it cannot be read
      def declaration_line_text(file, line)
        return nil unless file && line && File.exist?(file)

        text = (@declaration_lines ||= {})[file] ||= File.readlines(file)
        text[line - 1]&.strip.presence
      end

      def applicable_filters(controller, action)
        action_name = action.to_s

        applicable = process_action_callbacks(controller).select do |cb|
          callback_applies_to_action?(cb, action_name)
        end
        applicable.map { |cb| { kind: cb.kind, filter: callback_filter(cb) } }
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
