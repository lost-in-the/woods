# frozen_string_literal: true

require_relative 'client'
require_relative 'mapper'
require_relative 'rate_limiter'

module CodebaseIndex
  class ConfigurationError < Error; end unless defined?(CodebaseIndex::ConfigurationError)

  module Notion
    # Orchestrates syncing CodebaseIndex extraction data to Notion databases.
    #
    # Reads extraction output from disk via IndexReader, maps model and column data
    # to Notion page properties, and pushes via the Notion API. All syncs are idempotent —
    # existing pages are updated, new pages are created.
    #
    # @example
    #   exporter = Exporter.new(index_dir: "tmp/codebase_index")
    #   stats = exporter.sync_all
    #   # => { data_models: 10, columns: 45, errors: [] }
    #
    class Exporter # rubocop:disable Metrics/ClassLength
      # @param index_dir [String] Path to extraction output directory
      # @param config [Configuration] CodebaseIndex configuration (default: global config)
      # @param client [Client, nil] Notion API client (auto-created from config if nil)
      # @param reader [Object, nil] IndexReader instance (auto-created from index_dir if nil)
      # @raise [ConfigurationError] if notion_api_token is not configured
      def initialize(index_dir:, config: CodebaseIndex.configuration, client: nil, reader: nil)
        api_token = config.notion_api_token
        raise ConfigurationError, 'notion_api_token is required for Notion export' unless api_token

        @database_ids = config.notion_database_ids || {}
        @client = client || Client.new(api_token: api_token)
        @reader = reader || build_reader(index_dir)
        @page_id_cache = {}
      end

      # Sync all configured databases. Idempotent — safe to re-run.
      #
      # @return [Hash] { data_models: Integer, columns: Integer, errors: Array<String> }
      def sync_all
        model_stats = @database_ids[:data_models] ? sync_data_models : empty_stats
        column_stats = @database_ids[:columns] && @database_ids[:data_models] ? sync_columns : empty_stats

        all_errors = model_stats[:errors] + column_stats[:errors]

        {
          data_models: model_stats[:synced],
          columns: column_stats[:synced],
          errors: cap_errors(all_errors)
        }
      end

      # Sync model units to the Data Models Notion database.
      #
      # @return [Hash] { synced: Integer, errors: Array<String> }
      def sync_data_models
        database_id = @database_ids[:data_models]
        return empty_stats unless database_id

        migration_dates = load_migration_dates
        sync_units('model', database_id, 'Table Name') do |unit_data|
          properties = Mappers::ModelMapper.new.map(unit_data)
          enrich_with_migration_date(properties, migration_dates)
          properties
        end
      end

      # Sync column data to the Columns Notion database.
      #
      # @return [Hash] { synced: Integer, errors: Array<String> }
      def sync_columns
        database_id = @database_ids[:columns]
        return empty_stats unless database_id

        synced = 0
        errors = []

        each_model_unit do |entry, unit_data|
          synced_count, unit_errors = sync_model_columns(entry, unit_data, database_id)
          synced += synced_count
          errors.concat(unit_errors)
        end

        { synced: synced, errors: errors }
      end

      MAX_ERRORS = 100

      private

      # Sync all units of a type, yielding each for property mapping.
      #
      # @param type [String] Unit type to list
      # @param database_id [String] Notion database UUID
      # @param title_property [String] Name of the title property
      # @yield [Hash] Unit data hash, expects Notion properties hash back
      # @return [Hash] { synced: Integer, errors: Array<String> }
      def sync_units(type, database_id, title_property)
        synced = 0
        errors = []

        @reader.list_units(type: type).each do |entry|
          unit_data = @reader.find_unit(entry['identifier'])
          next unless unit_data

          begin
            properties = yield(unit_data)
            title_value = extract_title_text(properties[title_property])
            page_id = upsert_page(database_id: database_id, title_value: title_value, properties: properties)
            @page_id_cache[entry['identifier']] = page_id
            synced += 1
          rescue StandardError => e
            errors << "#{entry['identifier']}: #{e.message}"
          end
        end

        { synced: synced, errors: errors }
      end

      # Iterate over loaded model units.
      #
      # @yield [Hash, Hash] Index entry and full unit data
      def each_model_unit
        @reader.list_units(type: 'model').each do |entry|
          unit_data = @reader.find_unit(entry['identifier'])
          next unless unit_data

          yield(entry, unit_data)
        end
      end

      # Sync columns for a single model.
      #
      # @return [Array(Integer, Array<String>)] Count of synced columns and errors
      def sync_model_columns(entry, unit_data, database_id)
        parent_page_id = @page_id_cache[entry['identifier']]
        columns = unit_data.dig('metadata', 'columns') || []
        validations = unit_data.dig('metadata', 'validations') || []
        mapper = Mappers::ColumnMapper.new
        synced = 0
        errors = []

        columns.each do |column|
          properties = mapper.map(column, model_identifier: entry['identifier'],
                                          validations: validations, parent_page_id: parent_page_id)
          upsert_page(database_id: database_id, title_value: column['name'], properties: properties)
          synced += 1
        rescue StandardError => e
          errors << "#{entry['identifier']}.#{column['name']}: #{e.message}"
        end

        [synced, errors]
      end

      # Enrich model properties with migration date if available.
      #
      # @param properties [Hash] Notion properties hash (mutated)
      # @param migration_dates [Hash] { table_name => date_string }
      def enrich_with_migration_date(properties, migration_dates)
        table_name = extract_title_text(properties['Table Name'])
        return unless migration_dates[table_name]

        properties['Last Schema Change'] = { date: { start: migration_dates[table_name] } }
      end

      # Load migration units and compute latest change dates per table.
      #
      # @return [Hash<String, String>] { table_name => latest_date }
      def load_migration_dates
        mapper = Mappers::MigrationMapper.new
        units = @reader.list_units(type: 'migration').filter_map { |e| @reader.find_unit(e['identifier']) }
        mapper.latest_changes(units)
      rescue StandardError
        {}
      end

      # Upsert a Notion page: find by title, update if exists, create if not.
      #
      # @return [String] Notion page ID
      def upsert_page(database_id:, title_value:, properties:)
        existing = @client.find_page_by_title(database_id: database_id, title: title_value)

        if existing
          @client.update_page(page_id: existing['id'], properties: properties)
          existing['id']
        else
          result = @client.create_page(database_id: database_id, properties: properties)
          result['id']
        end
      end

      # @return [Hash]
      def empty_stats
        { synced: 0, errors: [] }
      end

      # Cap errors to prevent unbounded memory growth.
      #
      # @param errors [Array<String>]
      # @return [Array<String>]
      def cap_errors(errors)
        return errors if errors.size <= MAX_ERRORS

        errors.first(MAX_ERRORS) + ["... and #{errors.size - MAX_ERRORS} more errors"]
      end

      # @return [String]
      def extract_title_text(title_prop)
        title_prop&.dig(:title, 0, :text, :content) || ''
      end

      # @return [Object] IndexReader
      def build_reader(index_dir)
        require_relative '../mcp/index_reader'
        CodebaseIndex::MCP::IndexReader.new(index_dir)
      end
    end
  end
end
