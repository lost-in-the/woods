# frozen_string_literal: true

require_relative '../git_source_filter'

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'behavioral_profile'
require_relative 'config_source_guard'

module Woods
  module Extractors
    # ConfigurationExtractor handles Rails configuration file extraction.
    #
    # Scans `config/initializers/` and `config/environments/` for Ruby
    # configuration files, plus the Ruby an application boots, seeds and builds
    # from: `config/boot.rb`, `config/environment.rb`, `config/importmap.rb`,
    # `config/deploy.rb`, `config/deploy/`, `db/seeds.rb`, `db/seeds/`, and the
    # root `Gemfile` and `Rakefile`. Each file becomes one
    # ExtractedUnit with metadata about config type, gem references, and
    # detected settings.
    #
    # Published source is passed through {ConfigSourceGuard.redact}, so a
    # credential-shaped literal is replaced by a marker.
    #
    # `config/routes.rb` belongs to RouteExtractor (a `route_file` unit) and
    # `config/application.rb` is the nominal path of the behavioral profile, so
    # neither is extracted here. Other Ruby directly under `config/` is not
    # extracted either: {Woods::ReloadPolicy} leaves it unclassified so the
    # watch daemon can restart for the helpers its process loaded at boot, and
    # a file the daemon ignores cannot be kept current.
    #
    # @example
    #   extractor = ConfigurationExtractor.new
    #   units = extractor.extract_all
    #   devise = units.find { |u| u.identifier == "initializers/devise.rb" }
    #
    class ConfigurationExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Directories to scan for configuration files
      CONFIG_DIRECTORIES = %w[
        config/initializers
        config/environments
      ].freeze

      # Config type of each directory scanned recursively.
      DIRECTORY_TYPES = {
        'config/initializers' => 'initializer',
        'config/environments' => 'environment',
        'config/deploy' => 'deploy',
        'db/seeds' => 'seeds'
      }.freeze

      # Config types of {CONFIG_DIRECTORIES}, and of a call that names no type.
      CONFIG_TYPES_BY_DIRECTORY = [nil, 'initializer', 'environment'].freeze

      # Directories scanned in addition to {CONFIG_DIRECTORIES}.
      SOURCE_DIRECTORIES = (DIRECTORY_TYPES.keys - CONFIG_DIRECTORIES).freeze

      # Config type of each file named exactly.
      FILE_TYPES = {
        'Gemfile' => 'gemfile',
        'Rakefile' => 'rakefile',
        'config/boot.rb' => 'boot',
        'config/deploy.rb' => 'deploy',
        'config/environment.rb' => 'environment',
        'config/importmap.rb' => 'importmap',
        'db/seeds.rb' => 'seeds'
      }.freeze

      # Root-relative files named exactly, including the two with no extension.
      SOURCE_FILES = FILE_TYPES.keys.freeze

      GEM_DECLARATION = /^[ \t]*+gem[ \t]*+\(?+[ \t]*+["']([\w.-]++)["']/

      class << self
        # Whether this extractor owns a path. A pure function of the path.
        #
        # @param relative_path [String] Rails.root-relative path
        # @return [Boolean]
        def configuration_path?(relative_path)
          !config_type_for(relative_path.to_s).nil?
        end

        # @param relative_path [String] Rails.root-relative path
        # @return [String, nil] the config type, or nil for a path this extractor does not own
        def config_type_for(relative_path)
          return FILE_TYPES[relative_path] if FILE_TYPES.key?(relative_path)
          return nil unless relative_path.end_with?('.rb')

          directory = DIRECTORY_TYPES.keys.find { |dir| relative_path.start_with?("#{dir}/") }
          DIRECTORY_TYPES[directory]
        end
      end

      def initialize
        @directories = CONFIG_DIRECTORIES.map { |d| Rails.root.join(d) }
                                         .select(&:directory?)
      end

      # Extract all configuration files and the behavioral profile.
      #
      # @return [Array<ExtractedUnit>] List of configuration units
      def extract_all
        units = (find_files_in_directories(@directories) + boot_and_root_files).filter_map do |file|
          extract_configuration_file(file)
        end

        profile = extract_behavioral_profile
        units << profile if profile

        units
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "BehavioralProfile integration failed: #{e.message}")
        units || []
      end

      # Re-derive the synthetic unit from resolved runtime values, never from
      # its nominal config/application.rb source path.
      # @return [ExtractedUnit, nil]
      def extract_behavioral_profile
        profiler = BehavioralProfile.new
        profile = profiler.extract
        SourceInputs::ConsumerErrors.record(self) if SourceInputs::ConsumerErrors.failed?(profiler)
        profile
      end

      # Extract a single configuration file
      #
      # @param file_path [String] Path to the configuration file
      # @return [ExtractedUnit, nil] The extracted unit or nil on failure
      def extract_configuration_file(file_path)
        config_type = detect_config_type(file_path)
        return nil unless config_type && readable?(file_path)

        return nil if (@git_filter ||= GitSourceFilter.new(root: Rails.root)).skip_reason(file_path)

        # Credential-shaped text never reaches the published source or metadata.
        source = ConfigSourceGuard.redact(File.read(file_path))
        identifier = build_identifier(file_path)

        unit = ExtractedUnit.new(
          type: :configuration,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace = config_type
        unit.source_code = annotate_source(source, identifier, config_type)
        unit.metadata = extract_metadata(source, config_type)
        unit.dependencies = extract_dependencies(source, config_type)

        unit
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract configuration #{file_path}: #{e.message}")
        nil
      end

      private

      # Initializers and environments are read as found. Every other file must
      # resolve under the application root, so a symlink cannot publish a
      # foreign file as a boot, seed or root unit.
      def readable?(file_path)
        relative = file_path.to_s.sub("#{Rails.root}/", '')
        return true if CONFIG_DIRECTORIES.any? { |dir| relative.start_with?("#{dir}/") }

        ConfigSourceGuard.inside_root?(file_path.to_s, Rails.root.to_s)
      end

      # Files outside {CONFIG_DIRECTORIES}: the exact files, then the extra
      # directories. Sorted, so repeat runs agree.
      #
      # @return [Array<String>] absolute paths
      def boot_and_root_files
        root = Rails.root.to_s
        relative = SOURCE_FILES.select { |path| File.file?(File.join(root, path)) }
        relative += SOURCE_DIRECTORIES.flat_map { |dir| Dir.glob("#{dir}/**/*.rb", base: root) }
        relative.uniq.sort.select { |path| self.class.configuration_path?(path) }.map { |path| File.join(root, path) }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Identification
      # ──────────────────────────────────────────────────────────────────────

      # Build a readable identifier from the file path.
      #
      # @param file_path [String]
      # @return [String] e.g., "initializers/devise.rb" or "environments/production.rb"
      def build_identifier(file_path)
        relative = file_path.sub("#{Rails.root}/", '')
        relative.sub(%r{^config/}, '')
      end

      # The kind of configuration a file holds, decided by its path.
      #
      # @param file_path [String]
      # @return [String, nil] nil for a path this extractor does not own
      def detect_config_type(file_path)
        self.class.config_type_for(file_path.to_s.sub("#{Rails.root}/", ''))
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String]
      # @param identifier [String]
      # @param config_type [String]
      # @return [String]
      def annotate_source(source, identifier, config_type)
        gem_refs = detect_gem_references(source, config_type)

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Configuration: #{identifier.ljust(53)}║
          # ║ Type: #{config_type.ljust(62)}║
          # ║ Gems: #{gem_refs.join(', ').ljust(62)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String]
      # @param config_type [String]
      # @return [Hash]
      def extract_metadata(source, config_type)
        {
          config_type: config_type,
          gem_references: detect_gem_references(source, config_type),
          config_settings: detect_config_settings(source),
          rails_config_blocks: detect_rails_config_blocks(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') },
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size
        }
      end

      # Detect gem/library references in configuration.
      #
      # @param source [String]
      # @param config_type [String, nil] a Gemfile also counts its `gem` declarations
      # @return [Array<String>]
      def detect_gem_references(source, config_type = nil)
        refs = config_type == 'gemfile' ? source.scan(GEM_DECLARATION).flatten : []

        # Gem.configure style: Devise.setup, Sidekiq.configure_server
        source.scan(/(\w+)\.(setup|configure\w*|config)\b/).each do |match|
          name = match[0]
          refs << name unless generic_config_name?(name)
        end

        # require statements for gems
        source.scan(/require\s+['"]([^'"]+)['"]/).each do |match|
          refs << match[0]
        end

        refs.uniq
      end

      # Detect configuration settings (key = value patterns).
      #
      # @param source [String]
      # @return [Array<String>]
      def detect_config_settings(source)
        # config.something = value
        settings = source.scan(/config\.(\w+(?:\.\w+)*)\s*=/).map { |match| match[0] }

        # self.something = value (inside configure blocks)
        settings.concat(source.scan(/(?:self|config)\.(\w+)\s*=/).map { |match| match[0] })

        settings.uniq
      end

      # Detect Rails.application.configure or similar blocks.
      #
      # @param source [String]
      # @return [Array<String>]
      def detect_rails_config_blocks(source)
        source.scan(/(Rails\.application\.configure|Rails\.application\.config\.\w+)/)
              .map { |match| match[0] }
              .uniq
      end

      # Check if a name is too generic to be a gem reference.
      #
      # @param name [String]
      # @return [Boolean]
      def generic_config_name?(name)
        %w[Rails ActiveRecord ActiveJob ActionMailer ActionController ActiveStorage ActionCable].include?(name)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String]
      # @param config_type [String, nil]
      # @return [Array<Hash>]
      def extract_dependencies(source, config_type = nil)
        deps = detect_gem_references(source, config_type).map do |gem_ref|
          { type: :gem, target: gem_ref, via: :configuration }
        end

        # Initializers and environments keep their service-only scan. Boot,
        # seed, deploy and root files reference models, jobs and mailers too.
        if CONFIG_TYPES_BY_DIRECTORY.include?(config_type)
          deps.concat(scan_service_dependencies(source))
          deps.concat(scan_config_dependencies(source))
        else
          deps.concat(scan_common_dependencies(source))
        end

        consolidate_dependencies(deps)
      end
    end
  end
end
