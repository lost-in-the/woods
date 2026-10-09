# frozen_string_literal: true

require_relative '../extracted_unit'
require_relative '../source_inputs/consumer_errors'
require_relative 'external_consumer_declarations'
require_relative 'table_catalog'

module Woods
  module Extractors
    # ExternalConsumerExtractor turns declared readers of shared tables into
    # units, so `dependents` of a table shows the other application.
    #
    # A single-repository index cannot observe another application reading
    # the same database. The declaration makes that gap explicit: one unit
    # per declared application, with a `via: :reads_table` or
    # `via: :writes_table` edge to each table unit it names. The units are
    # marked `declared`, never observed.
    #
    # @example
    #   Woods.configure { |c| c.external_table_consumers = { "storefront" => %w[products orders] } }
    #   unit = ExternalConsumerExtractor.new.extract_all.first
    #   unit.identifier # => "external:storefront"
    #
    class ExternalConsumerExtractor
      IDENTIFIER_PREFIX = 'external:'

      # Where a declaration made in the Woods configuration is recorded as coming from.
      CONFIGURATION_SOURCE = 'configuration'

      # Whether a changed path is the declared consumers file.
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def self.trigger_path?(relative_path)
        declared = Woods.configuration&.external_table_consumers_path
        !declared.nil? && relative_path.to_s == declared
      end

      # @param table_catalog [TableCatalog, nil] defaults to the running application's tables
      def initialize(table_catalog: nil)
        @table_catalog = table_catalog
      end

      # Extract one unit per declared external consumer.
      #
      # @return [Array<ExtractedUnit>] sorted by identifier; empty when the
      #   declared file is malformed, so a bad edit never publishes a partial set
      def extract_all
        from_file = file_declarations
        from_configuration = Woods.configuration&.external_table_consumers || {}
        catalog = @table_catalog || TableCatalog.from_runtime

        (from_file.keys | from_configuration.keys).sort.map do |name|
          extract_consumer(name, from_file[name], from_configuration[name], catalog)
        end
      rescue ConfigurationError, Psych::Exception => e
        SourceInputs::ConsumerErrors.log(self, "Failed to read external consumers from #{declared_path}: #{e.message}")
        []
      end

      private

      # @return [String, nil] Rails.root-relative path of the declared file
      def declared_path
        Woods.configuration&.external_table_consumers_path
      end

      def file_declarations
        return {} unless declared_path

        ExternalConsumerDeclarations.load_file(Rails.root.join(declared_path))
      end

      def extract_consumer(name, from_file, from_configuration, catalog)
        roles = merged_roles(from_file, from_configuration)
        tables = roles.values.flatten.uniq.sort
        resolved = tables.to_h { |table| [table, catalog.named(table)] }

        unit = ExtractedUnit.new(type: :external_consumer, identifier: "#{IDENTIFIER_PREFIX}#{name}",
                                 file_path: from_file ? Rails.root.join(declared_path).to_s : nil)
        unit.namespace = nil
        unit.metadata = {
          consumer: name,
          declared: true,
          declared_in: [(declared_path if from_file), (CONFIGURATION_SOURCE if from_configuration)].compact,
          tables: tables,
          tables_read: roles[:reads],
          tables_written: roles[:writes],
          tables_missing: tables.select { |table| resolved[table].empty? }
        }
        unit.source_code = render_source(unit.metadata)
        unit.dependencies = table_edges(roles, resolved)
        unit
      end

      # @return [Hash{Symbol => Array<String>}] reads and writes, each the sorted union of both sources
      def merged_roles(from_file, from_configuration)
        ExternalConsumerDeclarations::ROLES.to_h do |role|
          [role, (Array(from_file&.fetch(role, [])) | Array(from_configuration&.fetch(role, []))).sort]
        end
      end

      # One edge per table unit per role. A table both read and written has
      # two edges to one target; the vias keep them distinct.
      def table_edges(roles, resolved)
        { reads: :reads_table, writes: :writes_table }.flat_map do |role, via|
          roles[role].flat_map { |table| resolved[table] }.map(&:identifier).uniq.sort.map do |identifier|
            { type: :database_table, target: identifier, via: via }
          end
        end
      end

      def render_source(metadata)
        lines = ["External consumer: #{metadata[:consumer]}",
                 "Another application that reads this database (declared in #{metadata[:declared_in].join(', ')}).",
                 '', 'Tables read:', *metadata[:tables_read].map { |table| "  #{table}" }]
        written = metadata[:tables_written]
        lines.push('', 'Tables written:', *written.map { |table| "  #{table}" }) if written.any?
        missing = metadata[:tables_missing]
        lines.push('', 'Declared tables missing from the live schema:', *missing.map { |t| "  #{t}" }) if missing.any?
        "#{lines.join("\n")}\n"
      end
    end
  end
end
