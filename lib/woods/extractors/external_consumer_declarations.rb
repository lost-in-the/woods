# frozen_string_literal: true

require 'yaml'

module Woods
  module Extractors
    # Validation and loading for declared external table consumers: other
    # applications that read tables in this application's database.
    #
    # A declaration is plain data, `{ "consumer" => ["table", ...] }`, whether
    # it comes from `config.external_table_consumers` or from the YAML file
    # named by `config.external_table_consumers_path`. Nothing callable is
    # accepted: the declaration decides index content, so it has to mean the
    # same thing in every process.
    module ExternalConsumerDeclarations
      module_function

      # Table lists a consumer can declare.
      ROLES = %i[reads writes].freeze

      # @param value [Hash] consumer name => table names (reads), or
      #   `{ reads: [...], writes: [...] }`
      # @param label [String] setting name used in error messages
      # @return [Hash{String => Hash{Symbol => Array<String>}}] frozen;
      #   `{ "name" => { reads: [...], writes: [...] } }`, names and tables sorted
      # @raise [ConfigurationError] if the value is malformed
      def normalize!(value, label:)
        raise ConfigurationError, "#{label} must be a Hash, got #{value.inspect}" unless value.is_a?(Hash)

        entries = value.map do |name, declared|
          consumer = name_of(name, "#{label} consumer name")
          [consumer, normalize_roles!(declared, "#{label}[#{consumer.inspect}]")]
        end
        entries.sort_by(&:first).to_h.freeze
      end

      # @return [Hash{Symbol => Array<String>}] frozen, every role present
      def normalize_roles!(declared, label)
        declared = { reads: declared } if declared.is_a?(Array)
        unless declared.is_a?(Hash)
          raise ConfigurationError, "#{label} must be an Array of table names or a reads/writes Hash, " \
                                    "got #{declared.inspect}"
        end

        by_role = declared.to_h { |role, tables| [role.to_s.to_sym, tables] }
        unknown = by_role.keys - ROLES
        raise ConfigurationError, "#{label} has unknown keys #{unknown.inspect}; use reads and writes" if unknown.any?

        ROLES.to_h { |role| [role, table_list!(by_role.fetch(role, []), "#{label} #{role}")] }.freeze
      end

      # @return [Array<String>] frozen, sorted, deduplicated
      def table_list!(tables, label)
        unless tables.is_a?(Array)
          raise ConfigurationError, "#{label} must be an Array of table names, got #{tables.inspect}"
        end

        tables.map { |table| name_of(table, "#{label} table") }.uniq.sort.freeze
      end

      # @param value [String, nil] Rails.root-relative path, or nil for no file
      # @param label [String] setting name used in error messages
      # @return [String, nil] frozen
      # @raise [ConfigurationError] unless nil or a relative path without `..`
      def normalize_path!(value, label:)
        return nil if value.nil?

        relative = value.is_a?(String) && !value.empty? && !value.start_with?('/') && !value.split('/').include?('..')
        raise ConfigurationError, "#{label} must be a path relative to Rails.root, got #{value.inspect}" unless relative

        value.dup.freeze
      end

      # Read declarations from a YAML file of plain data. A missing file
      # declares nothing.
      #
      # @param path [String, Pathname] absolute path
      # @return [Hash{String => Array<String>}]
      # @raise [ConfigurationError] if the content is not a valid declaration
      # @raise [Psych::Exception] if the file is not plain YAML
      def load_file(path)
        return {} unless File.file?(path)

        content = YAML.safe_load(File.read(path, encoding: Encoding::UTF_8))
        normalize!(content || {}, label: File.basename(path.to_s))
      end

      # @return [String] frozen, non-empty
      def name_of(value, label)
        return value.to_s.dup.freeze if (value.is_a?(String) || value.is_a?(Symbol)) && !value.to_s.strip.empty?

        raise ConfigurationError, "#{label} must be a non-empty String, got #{value.inspect}"
      end
    end
  end
end
