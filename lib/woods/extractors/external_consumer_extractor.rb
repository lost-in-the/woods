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
    # per declared application, with a `via: :reads_table` edge to each table
    # unit it names. The units are marked `declared`, never observed.
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

      def extract_consumer(name, file_tables, configured_tables, catalog)
        tables = (Array(file_tables) | Array(configured_tables)).sort
        resolved = tables.to_h { |table| [table, catalog.named(table)] }

        unit = ExtractedUnit.new(type: :external_consumer, identifier: "#{IDENTIFIER_PREFIX}#{name}",
                                 file_path: file_tables ? Rails.root.join(declared_path).to_s : nil)
        unit.namespace = nil
        unit.metadata = {
          consumer: name,
          declared: true,
          declared_in: [(declared_path if file_tables), (CONFIGURATION_SOURCE if configured_tables)].compact,
          tables: tables,
          tables_missing: tables.select { |table| resolved[table].empty? }
        }
        unit.source_code = render_source(unit.metadata)
        unit.dependencies = resolved.values.flatten.map(&:identifier).uniq.sort.map do |identifier|
          { type: :database_table, target: identifier, via: :reads_table }
        end
        unit
      end

      def render_source(metadata)
        lines = ["External consumer: #{metadata[:consumer]}",
                 "Another application that reads this database (declared in #{metadata[:declared_in].join(', ')}).",
                 '', 'Tables read:', *metadata[:tables].map { |table| "  #{table}" }]
        missing = metadata[:tables_missing]
        lines.push('', 'Declared tables missing from the live schema:', *missing.map { |t| "  #{t}" }) if missing.any?
        "#{lines.join("\n")}\n"
      end
    end
  end
end
