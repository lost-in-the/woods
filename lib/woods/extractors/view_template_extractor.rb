# frozen_string_literal: true

require_relative '../source_file'
require_relative '../source_inputs/consumer_errors'

require 'set'
require_relative 'route_helper_resolver'
require_relative 'helper_catalog'
require_relative 'helper_call_scan'
require_relative 'comment_blanking'
require_relative 'caller_prefix_partials'
require_relative 'view_engines/base'
require_relative 'view_engines/erb'
require_relative 'view_engines/haml'
require_relative 'view_engines/jbuilder'

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
    # resolution, helper-call edge resolution (through {HelperCatalog}),
    # and dependency assembly.
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
      include RouteHelperResolver

      # Directories to scan for view templates.
      VIEW_DIRECTORIES = %w[
        app/views
      ].freeze

      # Where the classes that own view directories live. A change here can
      # move a view directory's owner or its view prefixes.
      OWNER_DIRECTORIES = %w[
        app/controllers
        app/mailers
      ].freeze

      # Registered view-template engines, in precedence order. The first
      # engine whose {ViewEngines::Base#handles?} returns true for a file
      # wins — place more specific engines before more general ones if
      # overlap is ever introduced.
      ENGINES = [ViewEngines::Erb, ViewEngines::Haml, ViewEngines::Jbuilder].freeze

      # Marks a partial name built by Ruby string interpolation, whose real
      # path is only known at runtime.
      INTERPOLATION_MARKER = '#{'

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
        pending = {}
        units = @directories.flat_map do |dir|
          files = extensions.flat_map { |ext| Dir[dir.join("**/*#{ext}")] }
          files.uniq.filter_map { |file| extract_view_template_file(file, pending: pending) }
        end
        resolve_caller_partials(units, pending)
        units
      end

      # Extract a single view template file.
      #
      # A relative partial no file was found for depends on which pages
      # render this template ({CallerPrefixPartials}). Without +pending+ the
      # unit is returned as {#extract_all} would produce it, which reads
      # every template when this one holds such a partial.
      #
      # @param file_path [String] Path to the template file
      # @param pending [Hash, nil] When given, caller-dependent partials are
      #   collected into it under the unit's identifier and left unresolved
      # @return [ExtractedUnit, nil] The extracted unit, or nil if no
      #   registered engine handles the file
      def extract_view_template_file(file_path, pending: nil)
        return extract_resolved_template(file_path) unless pending

        engine = engine_for(file_path)
        return nil unless engine

        source = SourceFile.read(file_path)
        identifier = build_identifier(file_path)
        namespace = extract_view_namespace(file_path)

        unit = ExtractedUnit.new(
          type: :view_template,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace = namespace
        unit.source_code = source
        code = CommentBlanking.blank(source, file_path)
        interpolated, partials = engine.scan_partials(code).partition { |name| name.include?(INTERPOLATION_MARKER) }
        unit.metadata = build_metadata(engine, source, code, file_path, partials, interpolated)
        unit.dependencies = build_dependencies(engine, code, file_path, identifier, partials, pending)
        apply_helper_calls(unit, engine, source, namespace)

        unit
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract view template #{file_path}: #{e.message}")
        nil
      end

      private

      # The full pass is kept for the life of this extractor, which reads
      # one state of the tree: an incremental run re-extracts each template
      # that renders a changed partial, and each would repeat it.
      #
      # @param file_path [String]
      # @return [ExtractedUnit, nil] The unit with its caller-dependent partials resolved
      def extract_resolved_template(file_path)
        pending = {}
        unit = extract_view_template_file(file_path, pending: pending)
        return unit if unit.nil? || pending.empty?

        @resolved_templates ||= extract_all.to_h { |candidate| [candidate.identifier, candidate] }
        resolved = @resolved_templates[unit.identifier]
        return resolved if resolved

        resolve_caller_partials([unit], pending)
        unit
      end

      # @param units [Array<ExtractedUnit>] Every view template unit
      # @param pending [Hash{String => Array<Hash>}] See {CallerPrefixPartials#apply}
      # @return [void]
      def resolve_caller_partials(units, pending)
        return if pending.empty?

        owners = units.filter_map(&:namespace).uniq.sort.each_with_object({}) do |directory, known|
          prefixes = owner_prefixes(directory)
          known[directory] = { prefixes: prefixes, layout: owner_layout(directory, prefixes) } if prefixes
        end
        resolver = lambda do |identifier, prefixes, name|
          found = partial_under_prefixes(engine_for(identifier), name, identifier, prefixes)
          preferred_partial(engine_for(identifier), identifier, found) if found.any?
        end
        CallerPrefixPartials.new(owners: owners, resolver: resolver).apply(units, pending)
      end

      # The layout an owner renders its pages in: the one it names, or the
      # first `layouts/<prefix>` template that exists along its prefixes. A
      # layout chosen at request time (a Symbol or Proc) is unknown.
      #
      # @param directory [String] View directory with an owner
      # @param prefixes [Array<String>] The owner's view prefixes
      # @return [String, nil] Extension-less identifier, e.g. "layouts/application"
      def owner_layout(directory, prefixes)
        klass = view_owner(directory)[:klass]
        layout = klass.respond_to?(:_layout) ? klass._layout : nil
        case layout
        when String then layout.match?(/\blayouts/) ? layout : "layouts/#{layout}"
        when nil
          prefixes.map { |prefix| "layouts/#{prefix}" }
                  .find { |candidate| existing_partial_identifiers("#{candidate}.html").any? }
        end
      rescue StandardError
        nil
      end

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

      # Build metadata hash for the template. `unresolved_partials` is
      # present only when a partial name is interpolated or the engine
      # reports runtime-built partials.
      #
      # @param engine [ViewEngines::Base] Engine that matched this file
      # @param source [String] Template source code
      # @param code [String] The source with its comments blanked
      # @param file_path [String] Path to the template
      # @param partials [Array<String>] Literal partial names
      # @param interpolated [Array<String>] Partial names built by interpolation
      # @return [Hash]
      def build_metadata(engine, source, code, file_path, partials, interpolated)
        metadata = {
          template_engine: engine.name.to_s,
          is_partial: partial?(file_path),
          partials_rendered: partials,
          instance_variables: engine.scan_instance_variables(source),
          helpers_called: engine.scan_helpers(source),
          loc: source.lines.count { |l| l.strip.length.positive? }
        }
        unresolved = interpolated.map { |name| { kind: 'interpolation', name: name } } +
                     engine.scan_unresolved_partials(code)
        metadata[:unresolved_partials] = unresolved if unresolved.any?
        metadata
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
      # @param code [String] Template source with its comments blanked
      # @param file_path [String] Path to the template
      # @param identifier [String] Template identifier
      # @param partials [Array<String>] Pre-extracted partial names
      # @param pending [Hash] Collects each relative partial no file was found for
      # @return [Array<Hash>]
      def build_dependencies(engine, code, file_path, identifier, partials, pending)
        deps = []

        partials.each do |partial_name|
          partial_identifier = resolve_partial(engine, partial_name, identifier)
          unless partial_identifier
            partial_identifier = engine.resolve_partial_identifier(partial_name, identifier)
            unless partial_name.include?('/')
              (pending[identifier] ||= []) << { name: partial_name, target: partial_identifier }
            end
          end
          deps << { type: :view_template, target: partial_identifier, via: :render }
        end

        owner = view_owner(extract_view_namespace(file_path))
        deps << { type: owner[:type], target: owner[:name], via: :view_render } if owner

        deps.concat(resolve_navigation_candidates(engine, code))

        deps.uniq { |d| [d[:type], d[:target], d[:via]] }
      end

      # Add `helper_call` edges to the helper modules whose methods the
      # template calls, and `helper_method` edges to the controllers that
      # declare the names it calls. Names resolve through the template's
      # owner, so a mailer view sees its mailer's helpers.
      #
      # @param unit [ExtractedUnit]
      # @param engine [ViewEngines::Base]
      # @param source [String]
      # @param namespace [String, nil] View directory
      # @return [void]
      def apply_helper_calls(unit, engine, source, namespace)
        return if helper_catalog.names.empty?

        calls = engine.scan_method_calls(source, helper_catalog.names)
        owner = view_owner(namespace)&.dig(:klass)
        HelperCallScan.apply(unit, HelperCallScan.resolve(helper_catalog, calls, context: owner))
      end

      # The application's helper methods, read once per extractor.
      #
      # @return [HelperCatalog]
      def helper_catalog
        @helper_catalog ||= HelperCatalog.new
      end

      # Resolve a rendered partial to the template file that exists on disk
      # under any registered engine, so a partial rendered across engines
      # points at a real unit. A relative name missing from the template's
      # own directory is looked up through the view prefixes of the class
      # that owns that directory. A template in a directory nothing owns
      # (a layout, a shared partial) is rendered through its callers'
      # prefixes instead, which {CallerPrefixPartials} resolves.
      #
      # @param engine [ViewEngines::Base] Engine of the rendering template
      # @param partial_name [String] Partial name from the render call
      # @param identifier [String] Identifier of the rendering template
      # @return [String, nil] Partial template identifier, nil when no file exists
      def resolve_partial(engine, partial_name, identifier)
        candidates = existing_partial_identifiers(engine.resolve_partial_identifier(partial_name, identifier))
        if candidates.empty? && !partial_name.include?('/')
          own_dir = File.dirname(identifier)
          prefixes = owner_prefixes(own_dir)
          candidates = partial_under_prefixes(engine, partial_name, identifier, prefixes - [own_dir]) if prefixes
        end
        preferred_partial(engine, identifier, candidates) if candidates.any?
      end

      # Among several files for one partial the renderer's format wins, then
      # a format-less partial, then the renderer's own engine, then
      # {ENGINES} order.
      #
      # @param engine [ViewEngines::Base] Engine of the rendering template
      # @param identifier [String] Identifier of the rendering template
      # @param candidates [Array<String>] Existing partial identifiers
      # @return [String]
      def preferred_partial(engine, identifier, candidates)
        renderer_format = template_format(identifier)
        candidates.min_by do |candidate|
          [format_rank(template_format(candidate), renderer_format),
           engine.handles?(candidate) ? 0 : 1,
           @engines.index(engine_for(candidate)),
           candidate]
        end
      end

      # Rails resolves a relative partial through the rendering
      # controller's `_prefixes`: its own path, each parent controller's,
      # then "application". The first prefix holding the partial wins.
      #
      # @param engine [ViewEngines::Base]
      # @param partial_name [String] Relative partial name, e.g. "show"
      # @param identifier [String] Identifier of the rendering template
      # @param prefixes [Array<String>] View prefixes, in lookup order
      # @return [Array<String>]
      def partial_under_prefixes(engine, partial_name, identifier, prefixes)
        prefixes.each do |prefix|
          found = existing_partial_identifiers(engine.resolve_partial_identifier("#{prefix}/#{partial_name}", identifier))
          return found if found.any?
        end
        []
      end

      # Lookup prefixes of the class that owns a view directory, ending in
      # "application".
      #
      # @param dir [String] View directory, "." for the views root
      # @return [Array<String>, nil] nil when no runtime class owns the directory
      def owner_prefixes(dir)
        return nil unless view_owner(dir == '.' ? nil : dir)

        prefixes = controller_prefixes(dir)
        ((prefixes.empty? ? [dir] : prefixes) + ['application']).uniq
      end

      # View prefixes of the runtime class that owns a view directory.
      #
      # @param dir [String] View directory, "." for the views root
      # @return [Array<String>]
      def controller_prefixes(dir)
        klass = view_owner(dir == '.' ? nil : dir)&.dig(:klass)
        klass.respond_to?(:_prefixes) ? Array(klass._prefixes) : []
      rescue StandardError
        []
      end

      # Identifiers of existing files that share the partial's directory
      # and name stem and that some registered engine handles.
      #
      # @param partial_identifier [String] e.g. "ledgers/_summary.html.erb"
      # @return [Array<String>]
      def existing_partial_identifiers(partial_identifier)
        dir = File.dirname(partial_identifier)
        prefix = "#{File.basename(partial_identifier).split('.', 2).first}."
        @directories.flat_map do |root|
          path = dir == '.' ? root : root.join(dir)
          next [] unless path.directory?

          Dir.children(path).select { |name| name.start_with?(prefix) && engine_for(name) }
             .map { |name| dir == '.' ? name : "#{dir}/#{name}" }
        end.uniq
      end

      # Format segment of a template identifier ("html" for
      # "show.html+phone.erb"), or nil when the name carries none.
      #
      # @param identifier [String]
      # @return [String, nil]
      def template_format(identifier)
        parts = File.basename(identifier).split('.')
        parts.size >= 3 ? parts[-2].split('+').first : nil
      end

      # @param candidate_format [String, nil]
      # @param renderer_format [String, nil]
      # @return [Integer] 0 same format, 1 format-less, 2 other format
      def format_rank(candidate_format, renderer_format)
        return 0 if candidate_format == renderer_format

        candidate_format.nil? ? 1 : 2
      end

      # Ask the engine for route-helper candidates and resolve each to a
      # controller target via {RouteHelperResolver}. Gated by
      # +Woods.configuration.extract_navigation_edges+ so the config
      # toggle still applies.
      #
      # @param engine [ViewEngines::Base]
      # @param source [String]
      # @return [Array<Hash>]
      def resolve_navigation_candidates(engine, source)
        return [] unless Woods.configuration&.extract_navigation_edges

        seen = Set.new
        engine.scan_navigation_candidates(source).filter_map do |cand|
          resolved = resolve_route_helper(cand[:helper])
          next unless resolved

          key = [resolved[:controller], cand[:via]]
          next if seen.include?(key)

          seen.add(key)
          { type: :controller, target: resolved[:controller], via: cand[:via] }
        end
      end

      # The class that renders templates from a view directory: the
      # controller the directory names, or the mailer for a mailer view
      # directory. Only a class that exists at runtime counts, so a
      # directory such as `shared/` or `layouts/` has no owner.
      #
      # @param namespace [String, nil] View directory, e.g. "admin/users"
      # @return [Hash, nil] `{ type: :controller | :mailer, name:, klass: }`
      def view_owner(namespace)
        return nil if namespace.nil? || namespace == 'layouts'

        @view_owners ||= {}
        return @view_owners[namespace] if @view_owners.key?(namespace)

        @view_owners[namespace] = find_view_owner(camelize_path(namespace))
      end

      # @param base_name [String] e.g. "Admin::Users"
      # @return [Hash, nil]
      def find_view_owner(base_name)
        controller = runtime_constant("#{base_name}Controller")
        if subclass_of_any?(controller, %w[ActionController::Base ActionController::API])
          return { type: :controller, name: "#{base_name}Controller", klass: controller }
        end

        mailer = runtime_constant(base_name)
        { type: :mailer, name: base_name, klass: mailer } if subclass_of_any?(mailer, %w[ActionMailer::Base])
      end

      # @param klass [Object, nil]
      # @param base_names [Array<String>]
      # @return [Boolean]
      def subclass_of_any?(klass, base_names)
        return false unless klass.is_a?(Class)

        base_names.any? do |base_name|
          base = runtime_constant(base_name)
          base.is_a?(Class) && klass < base
        end
      end

      # Look a constant up one segment at a time without inheritance, so a
      # missing `Shared::SvgController` never resolves to a top-level
      # `SvgController`.
      #
      # @param name [String]
      # @return [Object, nil]
      def runtime_constant(name)
        name.split('::').reduce(Object) do |scope, part|
          return nil unless scope.is_a?(Module) && scope.const_defined?(part, false)

          scope.const_get(part, false)
        end
      rescue StandardError
        nil
      end

      # "admin/user_accounts" -> "Admin::UserAccounts", honoring host
      # inflections when ActiveSupport is loaded.
      #
      # @param path [String]
      # @return [String]
      def camelize_path(path)
        return path.camelize if path.respond_to?(:camelize)

        path.split('/').map { |p| p.split('_').map(&:capitalize).join }.join('::')
      end
    end
  end
end
