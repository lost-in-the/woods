# frozen_string_literal: true

require_relative 'render_target_resolver'

module Woods
  module Extractors
    # Finds component classes the eager load never reached.
    #
    # Both component extractors discover their units through
    # `component_base.descendants`, which only knows the classes something has
    # already loaded. Rails leaves `app/views` out of both `autoload_paths` and
    # `eager_load_paths`, so an app that keeps components beside their
    # templates and opts the subtree into autoloading gets classes that exist
    # on disk, resolve by name, and are absent from `descendants` for the whole
    # extraction (B-184).
    #
    # This walks the configured component directories and asks the autoloader
    # for each file's constant before `descendants` is read. Zeitwerk does the
    # loading, so a file that does not define the constant its path implies is
    # skipped rather than guessed at, and nothing is loaded twice.
    module ComponentDiscovery
      # Directories scanned when `Woods.configuration.component_paths` is unset.
      # Relative to `Rails.root`, deepest first is not required: the autoload
      # root a file resolves against is chosen per file, longest match first.
      DEFAULT_COMPONENT_PATHS = %w[
        app/components
        app/views/components
        app/views
      ].freeze

      # Ask the autoloader for every component file's constant.
      #
      # Call before reading `descendants`. Cheap when the app has no component
      # directories: each miss is one `File.directory?`.
      #
      # @return [void]
      def load_component_files
        @component_files_loaded = true
        unowned = 0
        undefined = 0
        component_directories.each do |directory|
          Dir.glob(File.join(directory, '**', '*.rb')).each do |path|
            case constantize_component_file(path)
            when :unowned then unowned += 1
            when :undefined then undefined += 1
            end
          end
        end

        # Two misconfigurations this cannot fix for the caller, each said once:
        # a component directory no Rails autoload path owns (loading those
        # files by hand would define constants Zeitwerk does not manage), and
        # a file whose expected constant resolves to nothing (an inflection or
        # namespace the path does not imply). Skipping silently looks
        # identical to having no components.
        if unowned.positive?
          Rails.logger.debug do
            "[Woods] #{unowned} component file(s) resolved to no constant; " \
              'their directory is not on an autoload path.'
          end
        end
        return unless undefined.positive?

        Rails.logger.debug do
          "[Woods] #{undefined} component file(s) resolved to no constant; " \
            'each file and the constant expected of it are logged above.'
        end
      end

      # Name the components a component's source renders.
      #
      # A target is resolved against the loaded constant tables, so every
      # component file is asked for first: the same load state a full
      # extraction resolves in, whichever entry point reached this component.
      #
      # @param component [Class] the rendering component
      # @param source [String] the source of the file that defines it
      # @param fragments [Array<String>] Ruby from the component's templates
      # @param kinds [Array<Symbol>, nil] see {RenderTargetResolver#call}
      # @return [RenderTargetResolver::Result]
      def resolve_render_targets(component, source, fragments: [], kinds: nil)
        load_component_files unless @component_files_loaded
        @render_target_resolver ||= RenderTargetResolver.new(ownership: method(:render_target_owner))
        @render_target_resolver.call(component, source, fragments: fragments, kinds: kinds)
      end

      # @param result [RenderTargetResolver::Result]
      # @return [Array<Hash>] `:render` edges, then `:slot` edges
      def component_dependencies(result)
        result.targets.map { |target| { type: :component, target: target, via: :render } } +
          result.slot_targets.map { |target| { type: :component, target: target, via: :slot } }
      end

      # @param result [RenderTargetResolver::Result]
      # @return [Hash] the renders and slots that produced no edge, and why
      def component_resolution_metadata(result)
        { unresolved_renders: result.unresolved, unresolved_slots: result.unresolved_slots,
          external_renders: result.external }
      end

      # Who defines a rendered component class.
      #
      # The test is the one both component families apply to their own units:
      # an application file defines it. Anything else has no unit to point at.
      #
      # @param component [Class]
      # @return [Symbol, String, nil] +:app+, the owning gem's name, or nil
      #   when no loaded gem contains the definition
      def render_target_owner(component)
        path = source_file_for(component)
        return :app if app_source_file?(path)
        return nil unless path

        absolute = File.expand_path(path)
        gem_roots.find { |root, _name| absolute.start_with?(root) }&.last
      end

      # Whether a class still owns its name.
      #
      # A Rails reload leaves the previous class object in `descendants` until
      # it is collected, under the name its replacement now holds, so one
      # component would be extracted twice and the survivor picked by order.
      # A name that resolves to nothing loaded is left to the caller's other
      # checks.
      #
      # @param component [Class]
      # @return [Boolean] false when the name resolves to a different object
      def current_constant?(component)
        @constant_lookup ||= SourceReferences::RuntimeLookup.new
        current = @constant_lookup.call("::#{component.name}", allow_private: true)[:value]
        current.nil? || current.equal?(component)
      end

      # @return [Array<String>] absolute directories to walk, nested entries
      #   collapsed into their ancestor so no file is handed over twice
      def component_directories
        ComponentDiscovery.component_directories
      end

      # @return [Array<String>] directories to scan, relative to Rails.root
      def component_paths
        ComponentDiscovery.component_paths
      end

      # @see #component_directories
      def self.component_directories
        present = component_paths
                  .map { |relative| File.join(Rails.root.to_s, relative) }
                  .uniq
                  .select { |directory| File.directory?(directory) }

        present.reject do |directory|
          present.any? { |other| other != directory && directory.start_with?("#{other}#{File::SEPARATOR}") }
        end
      end

      # Nil means "the defaults". An explicitly empty list means "walk
      # nothing", which is how an app opts out of the walk entirely.
      #
      # @return [Array<String>] directories to scan, relative to Rails.root
      def self.component_paths
        configured = Woods.configuration&.component_paths
        configured.nil? ? DEFAULT_COMPONENT_PATHS : Array(configured)
      end

      # Whether a changed path can define or rename a component: a Ruby file
      # under one of the component directories.
      #
      # @param path [String] absolute path
      # @return [Boolean]
      def self.component_source_path?(path)
        path.end_with?('.rb') &&
          component_directories.any? { |directory| path.start_with?("#{directory}#{File::SEPARATOR}") }
      end

      private

      # @param path [String] absolute path to a Ruby file
      # @return [Symbol] +:loaded+ when the file's constant resolved (or the
      #   file failed to load, which is warned about and not counted),
      #   +:unowned+ when no autoload root owns the path, +:undefined+ when
      #   the expected constant resolved to nothing
      def constantize_component_file(path)
        name = component_constant_name(path)
        return :unowned unless name
        return :loaded if name.safe_constantize

        # A nil here used to count as resolved, so a component whose expected
        # name was wrong (an inflection camelize does not know) vanished from
        # the extraction without a trace (F16).
        Rails.logger.debug { "[Woods] component file #{path} defines no #{name}" }
        :undefined
      rescue StandardError, ScriptError => e
        # A component that cannot load must not abort the extraction; a
        # SyntaxError in one file would otherwise take the whole run with it.
        Rails.logger.warn("[Woods] Could not load component file #{path}: #{e.message}")
        :loaded
      end

      # The constant a file's path implies, under the autoload root that owns
      # it. Nil when no autoload root does, because then the file's name says
      # nothing about its constant and loading it by hand would define
      # constants Zeitwerk does not manage.
      #
      # The owning Zeitwerk loader is asked first: its answer honours the
      # app's inflections (`api_card` => `APICard`), collapsed directories and
      # namespaces, which a plain `camelize` of the relative path does not
      # (F16). The camelize answer remains the fallback for a loader that
      # predates `cpath_expected_at` or declines to name the file.
      #
      # @param path [String]
      # @return [String, nil]
      def component_constant_name(path)
        root = autoload_roots.find { |candidate| path.start_with?("#{candidate}#{File::SEPARATOR}") }
        return nil unless root

        loader_constant_name(path) || path.delete_prefix("#{root}#{File::SEPARATOR}").delete_suffix('.rb').camelize
      end

      # @param path [String]
      # @return [String, nil] the first loader's non-nil answer
      def loader_constant_name(path)
        return nil unless Rails.respond_to?(:autoloaders) && Rails.autoloaders.respond_to?(:each)

        Rails.autoloaders.each do |loader|
          next unless loader.respond_to?(:cpath_expected_at)

          begin
            name = loader.cpath_expected_at(path)
          rescue StandardError
            next
          end
          return name if name
        end
        nil
      end

      # @return [Array<Array(String, String)>] loaded gem roots with their
      #   names, longest root first so a nested gem wins over its container
      def gem_roots
        @gem_roots ||= begin
          roots = Gem.loaded_specs.values.map do |spec|
            ["#{File.expand_path(spec.full_gem_path)}#{File::SEPARATOR}", spec.name]
          end
          roots.sort_by { |root, name| [-root.length, name] }
        end
      end

      # Every directory Zeitwerk resolves constants against, longest first so a
      # file under `app/views/components` resolves against that root rather
      # than against `app/views` when an app registers both.
      #
      # @return [Array<String>]
      def autoload_roots
        @autoload_roots ||= begin
          config = Rails.application&.config
          roots = %i[autoload_paths eager_load_paths autoload_once_paths].flat_map do |key|
            config.respond_to?(key) ? Array(config.public_send(key)).map(&:to_s) : []
          end
          roots.uniq.sort_by { |path| -path.length }
        end
      end
    end
  end
end
