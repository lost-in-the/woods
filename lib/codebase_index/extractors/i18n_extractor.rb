# frozen_string_literal: true

require 'yaml'

module CodebaseIndex
  module Extractors
    # I18nExtractor handles internationalization locale file extraction.
    #
    # Parses YAML files from `config/locales/` to extract translation keys,
    # locale information, and key structure. Each locale file becomes one
    # ExtractedUnit.
    #
    # @example
    #   extractor = I18nExtractor.new
    #   units = extractor.extract_all
    #   en = units.find { |u| u.identifier == "en.yml" }
    #
    class I18nExtractor
      # Directories to scan for locale files
      I18N_DIRECTORIES = %w[
        config/locales
      ].freeze

      def initialize
        @directories = I18N_DIRECTORIES.map { |d| Rails.root.join(d) }
                                       .select(&:directory?)
      end

      # Extract all locale files
      #
      # @return [Array<ExtractedUnit>] List of i18n units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.yml')].filter_map do |file|
            extract_i18n_file(file)
          end
        end
      end

      # Extract a single locale file
      #
      # @param file_path [String] Path to the YAML locale file
      # @return [ExtractedUnit, nil] The extracted unit or nil on failure
      def extract_i18n_file(file_path)
        source = File.read(file_path)
        data = YAML.safe_load(source, permitted_classes: [Symbol, Date, Time, Regexp])

        return nil unless data.is_a?(Hash) && data.any?

        identifier = build_identifier(file_path)
        locale = data.keys.first

        unit = ExtractedUnit.new(
          type: :i18n,
          identifier: identifier,
          file_path: file_path
        )

        unit.namespace = locale
        unit.source_code = source
        unit.metadata = build_metadata(data, locale)
        unit.dependencies = []

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract i18n #{file_path}: #{e.message}")
        nil
      end

      private

      # Build a readable identifier from the file path.
      #
      # @param file_path [String] Absolute path
      # @return [String] Relative identifier like "en.yml" or "models/en.yml"
      def build_identifier(file_path)
        relative = file_path.sub("#{Rails.root}/", '')
        relative.sub(%r{^config/locales/}, '')
      end

      # Build metadata for the locale file.
      #
      # @param data [Hash] Parsed YAML data
      # @param locale [String] The locale key (e.g., "en")
      # @return [Hash]
      def build_metadata(data, locale)
        locale_data = data[locale] || {}
        key_paths = flatten_keys(locale_data)

        {
          locale: locale,
          key_count: key_paths.size,
          top_level_keys: locale_data.is_a?(Hash) ? locale_data.keys : [],
          key_paths: key_paths
        }
      end

      # Flatten a nested hash into dot-notation key paths.
      #
      # @param hash [Hash] Nested hash to flatten
      # @param prefix [String] Current key prefix
      # @return [Array<String>] Flattened key paths
      def flatten_keys(hash, prefix = '')
        return ["#{prefix}(leaf)"] unless hash.is_a?(Hash)

        hash.flat_map do |key, value|
          full_key = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
          if value.is_a?(Hash)
            flatten_keys(value, full_key)
          else
            [full_key]
          end
        end
      end
    end
  end
end
