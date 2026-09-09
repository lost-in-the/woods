# frozen_string_literal: true

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
        component_paths.each do |relative|
          directory = File.join(Rails.root.to_s, relative)
          next unless File.directory?(directory)

          Dir.glob(File.join(directory, '**', '*.rb')).each do |path|
            constantize_component_file(path)
          end
        end
      end

      # @return [Array<String>] directories to scan, relative to Rails.root
      def component_paths
        configured = Woods.configuration&.component_paths
        configured.nil? || configured.empty? ? DEFAULT_COMPONENT_PATHS : Array(configured)
      end

      private

      # @param path [String] absolute path to a Ruby file
      # @return [void]
      def constantize_component_file(path)
        name = component_constant_name(path)
        return unless name

        name.safe_constantize
      rescue StandardError, ScriptError => e
        # A component that cannot load must not abort the extraction; a
        # SyntaxError in one file would otherwise take the whole run with it.
        Rails.logger.warn("[Woods] Could not load component file #{path}: #{e.message}")
      end

      # The constant a file's path implies, under the autoload root that owns
      # it. Nil when no autoload root does, because then the file's name says
      # nothing about its constant and loading it by hand would define
      # constants Zeitwerk does not manage.
      #
      # @param path [String]
      # @return [String, nil]
      def component_constant_name(path)
        root = autoload_roots.find { |candidate| path.start_with?("#{candidate}#{File::SEPARATOR}") }
        return nil unless root

        path.delete_prefix("#{root}#{File::SEPARATOR}").delete_suffix('.rb').camelize
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
