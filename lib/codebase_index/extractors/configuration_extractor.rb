# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # ConfigurationExtractor handles Rails configuration file extraction.
    #
    # Scans `config/initializers/` and `config/environments/` for Ruby
    # configuration files. Each file becomes one ExtractedUnit with metadata
    # about config type, gem references, and detected settings.
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

      def initialize
        @directories = CONFIG_DIRECTORIES.map { |d| Rails.root.join(d) }
                                         .select(&:directory?)
      end

      # Extract all configuration files
      #
      # @return [Array<ExtractedUnit>] List of configuration units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.rb')].filter_map do |file|
            extract_configuration_file(file)
          end
        end
      end

      # Extract a single configuration file
      #
      # @param file_path [String] Path to the configuration file
      # @return [ExtractedUnit, nil] The extracted unit or nil on failure
      def extract_configuration_file(file_path)
        source = File.read(file_path)
        identifier = build_identifier(file_path)
        config_type = detect_config_type(file_path)

        unit = ExtractedUnit.new(
          type: :configuration,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace = config_type
        unit.source_code = annotate_source(source, identifier, config_type)
        unit.metadata = extract_metadata(source, config_type)
        unit.dependencies = extract_dependencies(source)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract configuration #{file_path}: #{e.message}")
        nil
      end

      private

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

      # Detect whether this is an initializer or environment config.
      #
      # @param file_path [String]
      # @return [String]
      def detect_config_type(file_path)
        if file_path.include?('config/initializers')
          'initializer'
        elsif file_path.include?('config/environments')
          'environment'
        else
          'configuration'
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String]
      # @param identifier [String]
      # @param config_type [String]
      # @return [String]
      def annotate_source(source, identifier, config_type)
        gem_refs = detect_gem_references(source)

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
          gem_references: detect_gem_references(source),
          config_settings: detect_config_settings(source),
          rails_config_blocks: detect_rails_config_blocks(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') },
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size
        }
      end

      # Detect gem/library references in configuration.
      #
      # @param source [String]
      # @return [Array<String>]
      def detect_gem_references(source)
        refs = []

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
      # @return [Array<Hash>]
      def extract_dependencies(source)
        deps = detect_gem_references(source).map do |gem_ref|
          { type: :gem, target: gem_ref, via: :configuration }
        end

        deps.concat(scan_service_dependencies(source))

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
