# frozen_string_literal: true

require 'woods'
require_relative 'client'
require_relative 'mapper'
require_relative 'rate_limiter'

module Woods
  module Notion
    # Orchestrates syncing Woods extraction data to Notion databases.
    #
    # Reads extraction output from disk via IndexReader, maps model and column data
    # to Notion page properties, and pushes via the Notion API. All syncs are idempotent —
    # existing pages are updated, new pages are created.
    #
    # @example
    #   exporter = Exporter.new(index_dir: "tmp/woods")
    #   stats = exporter.sync_all
    #   # => { data_models: 10, columns: 45, errors: [] }
    #
    class Exporter # rubocop:disable Metrics/ClassLength
      # @param index_dir [String] Path to extraction output directory
      # @param config [Configuration] Woods configuration (default: global config)
      # @param client [Client, nil] Notion API client (auto-created from config if nil)
      # @param reader [Object, nil] IndexReader instance (auto-created from index_dir if nil)
      # @raise [ConfigurationError] if notion_api_token is not configured
      def initialize(index_dir:, config: Woods.configuration, client: nil, reader: nil)
        # A non-blank NOTION_API_TOKEN overrides the configured token
        # (documented contract; also what the MCP notion_wired? gate keys on).
        # Resolve via the shared Woods.resolve_notion_token so the exporter,
        # the MCP tool, and the rake task treat a blank env var identically —
        # a set-but-empty NOTION_API_TOKEN must not mask a configured token or
        # pass through as a blank bearer.
        api_token = Woods.resolve_notion_token(config)
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
      # Pages are titled with the table name. When several models share one
      # table (STI hierarchies, custom +self.table_name+ overlaps) a bare
      # table-name title makes each model overwrite the others' pages (#149),
      # so those titles are qualified as "<table> (<ModelName>)". Models with
      # a unique table keep the bare title — no churn for the common case.
      #
      # @return [Hash] { synced: Integer, errors: Array<String> }
      def sync_data_models
        database_id = @database_ids[:data_models]
        return empty_stats unless database_id

        migration_dates = load_migration_dates
        shared_tables = shared_table_names
        sync_units('model', database_id, 'Table Name') do |unit_data|
          properties = Mappers::ModelMapper.new.map(unit_data)
          # Enrichment reads the bare table name from the title — run it
          # before any qualification rewrites the title.
          enrich_with_migration_date(properties, migration_dates)
          legacy_title = qualify_shared_table_title(properties, unit_data, shared_tables)
          [properties, legacy_title]
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
      # @yield [Hash] Unit data hash; expects back +[properties, legacy_title]+
      #   where +legacy_title+ (String, nil) is a pre-qualification title an
      #   already-synced page may still carry (see {#adopt_legacy_page})
      # @return [Hash] { synced: Integer, errors: Array<String> }
      def sync_units(type, database_id, title_property)
        synced = 0
        errors = []

        @reader.list_units(type: type).each do |entry|
          unit_data = @reader.find_unit(entry['identifier'])
          next unless unit_data

          begin
            properties, legacy_title = yield(unit_data)
            title_value = extract_title_text(properties[title_property])
            legacy = legacy_title ? { title: legacy_title } : nil
            page_id = upsert_page(database_id: database_id, title_value: title_value,
                                  properties: properties, legacy: legacy)
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
      # Column pages are titled "<table>.<column>" (#149). Every model shares
      # id/created_at/updated_at, and upserting by the bare column name found
      # the previous model's page by title equality across the whole Columns
      # database — churning it down to one page per distinct column name.
      # The table qualifier comes from {Mappers::ModelMapper.table_name_for},
      # the same value the Table relation's target page is titled with.
      #
      # @return [Array(Integer, Array<String>)] Count of synced columns and errors
      def sync_model_columns(entry, unit_data, database_id)
        parent_page_id = @page_id_cache[entry['identifier']]
        table_name = Mappers::ModelMapper.table_name_for(unit_data)
        columns = unit_data.dig('metadata', 'columns') || []
        validations = unit_data.dig('metadata', 'validations') || []
        mapper = Mappers::ColumnMapper.new
        synced = 0
        errors = []

        columns.each do |column|
          properties = mapper.map(column, model_identifier: entry['identifier'], table_name: table_name,
                                          validations: validations, parent_page_id: parent_page_id)
          upsert_page(database_id: database_id, title_value: extract_title_text(properties['Column Name']),
                      properties: properties, legacy: column_legacy_descriptor(column, parent_page_id))
          synced += 1
        rescue StandardError => e
          errors << "#{entry['identifier']}.#{column['name']}: #{e.message}"
        end

        [synced, errors]
      end

      # Describe the pre-#149 page a column may still be stored under: the
      # bare column name, verified against this model's Table relation when
      # the parent Data Models page is known.
      #
      # @param column [Hash]
      # @param parent_page_id [String, nil]
      # @return [Hash] Legacy descriptor for {#upsert_page}
      def column_legacy_descriptor(column, parent_page_id)
        legacy = { title: column['name'].to_s }
        if parent_page_id
          legacy[:relation_property] = 'Table'
          legacy[:relation_page_id] = parent_page_id
        end
        legacy
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
      # When the qualified-title lookup misses and a +legacy+ descriptor is
      # given, a page still carrying the pre-qualification title may be
      # adopted instead of creating a duplicate (see {#adopt_legacy_page}).
      # Updating the adopted page rewrites its title to the qualified form,
      # so the legacy lookup is a one-time migration cost per page.
      #
      # @param database_id [String] Notion database UUID
      # @param title_value [String] Title to find the page by
      # @param properties [Hash] Full property payload to write
      # @param legacy [Hash, nil] { title:, relation_property:, relation_page_id: }
      # @return [String] Notion page ID
      def upsert_page(database_id:, title_value:, properties:, legacy: nil)
        existing = @client.find_page_by_title(database_id: database_id, title: title_value)
        if existing.nil? && legacy && legacy[:title] != title_value
          existing = adopt_legacy_page(database_id: database_id, legacy: legacy, new_title: title_value)
        end

        if existing
          @client.update_page(page_id: existing['id'], properties: properties)
          existing['id']
        else
          result = @client.create_page(database_id: database_id, properties: properties)
          result['id']
        end
      end

      # Locate a page still titled with the pre-#149 (unqualified) title so
      # the sync can adopt it — update it in place, which also rewrites its
      # title to the qualified form — rather than strand it next to a fresh
      # duplicate forever.
      #
      # Adoption is deliberately conservative:
      # - With a relation qualifier (Columns), the title-equality filter is
      #   AND-ed with a `relation contains` filter on the parent Data Models
      #   page, so only a legacy page actually belonging to this model can be
      #   adopted. Multiple matches are same-parent duplicates; the first is
      #   adopted with a warning.
      # - Without one (Data Models), the page is adopted only when exactly one
      #   match exists; an ambiguous set is left alone with a warning and a
      #   fresh qualified page is created instead.
      #
      # @param database_id [String] Notion database UUID
      # @param legacy [Hash] { title:, relation_property:, relation_page_id: }
      # @param new_title [String] Qualified title the adopted page will get
      # @return [Hash, nil] Adoptable page, or nil to create fresh
      def adopt_legacy_page(database_id:, legacy:, new_title:)
        results = query_legacy_pages(database_id, legacy)
        return nil if results.empty?

        if results.size > 1
          return warn_ambiguous_legacy(legacy, results) unless legacy[:relation_page_id]

          warn "woods: notion sync found #{results.size} legacy pages titled #{legacy[:title].inspect} " \
               "for one Table relation; adopting the first (#{results.first['id']})"
        end

        warn "woods: notion sync adopting legacy page #{results.first['id']} " \
             "(#{legacy[:title].inspect} -> #{new_title.inspect})"
        results.first
      end

      # @param legacy [Hash]
      # @param results [Array<Hash>]
      # @return [nil]
      def warn_ambiguous_legacy(legacy, results)
        warn "woods: notion sync found #{results.size} pages sharing the legacy title " \
             "#{legacy[:title].inspect} and cannot tell them apart; creating a qualified page " \
             'instead — clean up the legacy pages manually'
        nil
      end

      # Query pages carrying the legacy title, narrowed by the parent relation
      # when the descriptor names one. This is the only extra API call the
      # qualified-title scheme introduces, and it runs solely on the
      # qualified-lookup miss path.
      #
      # @param database_id [String]
      # @param legacy [Hash]
      # @return [Array<Hash>] Matching pages
      def query_legacy_pages(database_id, legacy)
        filter = { property: 'title', title: { equals: legacy[:title] } }
        if legacy[:relation_property] && legacy[:relation_page_id]
          filter = { and: [filter, { property: legacy[:relation_property],
                                     relation: { contains: legacy[:relation_page_id] } }] }
        end

        response = @client.query_database(database_id: database_id, filter: filter)
        response['results'] || []
      end

      # Table names claimed by more than one model unit in the index — STI
      # hierarchies, or models sharing a table via +self.table_name=+.
      #
      # @return [Array<String>]
      def shared_table_names
        counts = Hash.new(0)
        each_model_unit do |_entry, unit_data|
          counts[Mappers::ModelMapper.table_name_for(unit_data)] += 1
        end
        counts.select { |_table, count| count > 1 }.keys
      end

      # Rewrite the Data Models title to "<table> (<ModelName>)" for a model
      # whose table name is shared with another model, so the two stop
      # overwriting each other's pages (#149).
      #
      # @param properties [Hash] Mapped Notion properties (mutated)
      # @param unit_data [Hash]
      # @param shared_tables [Array<String>]
      # @return [String, nil] The bare table name as the legacy title when
      #   qualification was applied, nil otherwise
      def qualify_shared_table_title(properties, unit_data, shared_tables)
        table_name = Mappers::ModelMapper.table_name_for(unit_data)
        return nil unless shared_tables.include?(table_name)

        qualified = "#{table_name} (#{unit_data['identifier']})"
        properties['Table Name'] = { title: [{ text: { content: qualified } }] }
        table_name
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
        Woods::MCP::IndexReader.new(index_dir)
      end
    end
  end
end
