# frozen_string_literal: true

require 'woods'
require_relative 'client'
require_relative 'mapper'
require_relative 'rate_limiter'
require_relative 'sync_manifest'

module Woods
  module Notion
    # Orchestrates syncing Woods extraction data to Notion databases.
    #
    # Reads extraction output from disk via IndexReader, maps model and column data
    # to Notion page properties, and pushes via the Notion API. All syncs are idempotent —
    # existing pages are updated, new pages are created.
    #
    # Syncs are incremental (#207 / B-095): a {SyncManifest} persisted under
    # the index directory records each page's Notion page_id and a content
    # hash of its mapped properties, keyed by the page's qualified title
    # (#149). An unchanged page is skipped with zero API calls; a changed
    # page is PATCHed directly by its cached page_id (one call, no
    # find-by-title query); only a manifest miss pays the full lookup /
    # legacy-adoption / create path. A cold manifest (first run, deleted
    # file) therefore degrades to exactly the pre-manifest behavior, plus
    # manifest writes. Set +WOODS_NOTION_FORCE=1+ (or pass
    # +force_full: true+) to ignore the manifest for one run.
    #
    # @example
    #   exporter = Exporter.new(index_dir: "tmp/woods")
    #   stats = exporter.sync_all
    #   # => { data_models: 10, columns: 45, skipped: 0, errors: [] }
    #
    # rubocop:disable-next Metrics/ClassLength
    class Exporter
      MAX_ERRORS = 100

      # Manifest scope for the Data Models database.
      SCOPE_DATA_MODELS = 'data_models'
      # Manifest scope for the Columns database.
      SCOPE_COLUMNS = 'columns'
      # Manifest file name, stored under the index/output directory
      # (mirrors Unblocked's +unblocked_sync_manifest.json+).
      MANIFEST_FILENAME = 'notion_sync_manifest.json'
      # Escape hatch: set to 1/true/yes to ignore the manifest for one run
      # (the Notion counterpart of +UNBLOCKED_FORCE_FULL_SYNC+). Read here
      # rather than in the rake task so the MCP notion tool and embedded
      # callers honor it too.
      FORCE_ENV_VAR = 'WOODS_NOTION_FORCE'

      # Client errors that mean a cached page is gone (deleted or archived
      # behind the manifest), so the sync should self-heal by recreating it.
      # {Client} raises untyped +Woods::Error+ with the Notion status code
      # baked into the message ("Notion API error 404: ..."), so this is a
      # message-level match: 404/410 (page gone) or an archived-page
      # complaint (Notion answers 400 "Can't update a page that is
      # archived..." for trashed pages).
      STALE_PAGE_ERROR = /\ANotion API error (?:404|410)\b|archiv/i

      # @param index_dir [String] Path to extraction output directory
      # @param config [Configuration] Woods configuration (default: global config)
      # @param client [Client, nil] Notion API client (auto-created from config if nil)
      # @param reader [Object, nil] IndexReader instance (auto-created from index_dir if nil)
      # @param manifest [SyncManifest, nil] Sync manifest (auto-created under index_dir if nil)
      # @param force_full [Boolean, nil] Ignore the manifest for this run —
      #   every page goes through the full find-by-title path (results are
      #   still recorded). Defaults to the {FORCE_ENV_VAR} env flag.
      # @raise [ConfigurationError] if notion_api_token is not configured
      # rubocop:disable-next Metrics/ParameterLists -- injectable collaborators, mirrors Unblocked::Exporter
      def initialize(index_dir:, config: Woods.configuration, client: nil, reader: nil,
                     manifest: nil, force_full: nil)
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
        @manifest = manifest || build_manifest(index_dir)
        @force_full = force_full.nil? ? env_force? : force_full
        @page_id_cache = {}
      end

      # Sync all configured databases. Idempotent — safe to re-run; a re-run
      # against an unchanged index issues zero API calls (see class docs).
      #
      # @return [Hash] { data_models: Integer, columns: Integer,
      #   skipped: Integer, errors: Array<String> }
      def sync_all
        model_stats = @database_ids[:data_models] ? sync_data_models : empty_stats
        column_stats = @database_ids[:columns] && @database_ids[:data_models] ? sync_columns : empty_stats

        all_errors = model_stats[:errors] + column_stats[:errors]

        {
          data_models: model_stats[:synced],
          columns: column_stats[:synced],
          skipped: model_stats[:skipped] + column_stats[:skipped],
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
      # Manifest entries whose title vanished from the current model set are
      # pruned afterwards; the Notion pages themselves are left alone (no
      # deletion path exists, and none is invented here).
      #
      # @return [Hash] { synced: Integer, skipped: Integer, errors: Array<String> }
      def sync_data_models
        database_id = @database_ids[:data_models]
        return empty_stats unless database_id

        begin
          migration_dates = load_migration_dates
          shared_tables = shared_table_names
          stats = sync_units('model', database_id, 'Table Name', SCOPE_DATA_MODELS) do |unit_data|
            properties = Mappers::ModelMapper.new.map(unit_data)
            # Enrichment reads the bare table name from the title — run it
            # before any qualification rewrites the title.
            enrich_with_migration_date(properties, migration_dates)
            legacy_title = qualify_shared_table_title(properties, unit_data, shared_tables)
            [properties, legacy_title]
          end
          @manifest.prune(SCOPE_DATA_MODELS, stats.delete(:current_keys))
          stats
        ensure
          save_manifest
        end
      end

      # Sync column data to the Columns Notion database.
      #
      # Manifest entries whose qualified title vanished from the current
      # column set are pruned afterwards; the Notion pages themselves are
      # left alone (no deletion path exists, and none is invented here).
      #
      # @return [Hash] { synced: Integer, skipped: Integer, errors: Array<String> }
      def sync_columns
        database_id = @database_ids[:columns]
        return empty_stats unless database_id

        begin
          totals = { synced: 0, skipped: 0, errors: [] }
          current_keys = []

          each_model_unit do |entry, unit_data|
            result = sync_model_columns(entry, unit_data, database_id, current_keys)
            totals[:synced] += result[:synced]
            totals[:skipped] += result[:skipped]
            totals[:errors].concat(result[:errors])
          end

          @manifest.prune(SCOPE_COLUMNS, current_keys)
          totals
        ensure
          save_manifest
        end
      end

      private

      # Sync all units of a type, yielding each for property mapping.
      #
      # @param type [String] Unit type to list
      # @param database_id [String] Notion database UUID
      # @param title_property [String] Name of the title property
      # @param scope [String] Manifest scope for this database
      # @yield [Hash] Unit data hash; expects back +[properties, legacy_title]+
      #   where +legacy_title+ (String, nil) is a pre-qualification title an
      #   already-synced page may still carry (see {#adopt_legacy_page})
      # @return [Hash] { synced:, skipped:, errors:, current_keys: }
      def sync_units(type, database_id, title_property, scope)
        stats = { synced: 0, skipped: 0, errors: [], current_keys: [] }

        @reader.list_units(type: type).each do |entry|
          unit_data = @reader.find_unit(entry['identifier'])
          next unless unit_data

          begin
            properties, legacy_title = yield(unit_data)
            title_value = extract_title_text(properties[title_property])
            stats[:current_keys] << title_value
            legacy = legacy_title ? { title: legacy_title } : nil
            status, page_id = sync_page(scope: scope, database_id: database_id, title_value: title_value,
                                        properties: properties, legacy: legacy)
            @page_id_cache[entry['identifier']] = page_id
            stats[status] += 1
          rescue AuthenticationError
            # Not a per-unit failure: the token is wrong or the integration is
            # not shared with this database, so every remaining call in the run
            # would fail too — at Notion's 3 req/sec. Abort instead of spending
            # the whole sync proving it.
            raise
          rescue StandardError => e
            stats[:errors] << "#{entry['identifier']}: #{e.message}"
          end
        end

        stats
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
      # The parent page id comes from the page-id cache, which the manifest
      # skip path populates too — so on a warm run the Table relation is
      # byte-identical to the previous run and unchanged columns hash stable.
      #
      # @param current_keys [Array<String>] Sink for this run's column titles
      # @return [Hash] { synced: Integer, skipped: Integer, errors: Array<String> }
      def sync_model_columns(entry, unit_data, database_id, current_keys)
        parent_page_id = @page_id_cache[entry['identifier']]
        table_name = Mappers::ModelMapper.table_name_for(unit_data)
        columns = unit_data.dig('metadata', 'columns') || []
        validations = unit_data.dig('metadata', 'validations') || []
        mapper = Mappers::ColumnMapper.new
        stats = { synced: 0, skipped: 0, errors: [] }

        columns.each do |column|
          properties = mapper.map(column, model_identifier: entry['identifier'], table_name: table_name,
                                          validations: validations, parent_page_id: parent_page_id)
          title_value = extract_title_text(properties['Column Name'])
          current_keys << title_value
          status, = sync_page(scope: SCOPE_COLUMNS, database_id: database_id, title_value: title_value,
                              properties: properties, legacy: column_legacy_descriptor(column, parent_page_id))
          stats[status] += 1
        rescue AuthenticationError
          raise # see sync_units — an auth failure dooms the whole run
        rescue StandardError => e
          stats[:errors] << "#{entry['identifier']}.#{column['name']}: #{e.message}"
        end

        stats
      end

      # Sync one page through the manifest. Three tiers, cheapest first:
      # manifest hit with an unchanged hash — skip, zero API calls; hit with
      # a changed hash — PATCH the cached page_id directly (one call, with
      # gone-page self-heal); miss — the full #149 path ({#upsert_page}:
      # find by qualified title, legacy adoption, create/update). Every
      # non-skip outcome records page_id + content hash for the next run.
      # +force_full+ bypasses the manifest reads entirely (tier three for
      # everything) but still records.
      #
      # @param scope [String] Manifest scope
      # @param database_id [String] Notion database UUID
      # @param title_value [String] Qualified title — the manifest key
      # @param properties [Hash] Full property payload to write
      # @param legacy [Hash, nil] Legacy descriptor for {#upsert_page}
      # @return [Array(Symbol, String)] [:skipped or :synced, page id]
      def sync_page(scope:, database_id:, title_value:, properties:, legacy: nil)
        content_hash = SyncManifest.content_hash(properties)

        unless @force_full
          if @manifest.unchanged?(scope, title_value, content_hash)
            return [:skipped, @manifest.page_id_for(scope, title_value)]
          end

          cached_id = @manifest.page_id_for(scope, title_value)
          if cached_id && (page_id = update_cached_page(scope, title_value, cached_id, properties))
            @manifest.record(scope: scope, key: title_value, hash: content_hash, page_id: page_id)
            return [:synced, page_id]
          end
        end

        page_id = upsert_page(database_id: database_id, title_value: title_value,
                              properties: properties, legacy: legacy)
        @manifest.record(scope: scope, key: title_value, hash: content_hash, page_id: page_id)
        [:synced, page_id]
      end

      # PATCH a page by its manifest-cached id — the one-call path for
      # changed content. When Notion reports the page gone ({STALE_PAGE_ERROR}:
      # deleted or archived behind the cache), warn once, drop the manifest
      # entry, and return nil so the caller falls through to the create path
      # (self-heal). Any other API failure propagates to the per-unit rescue
      # so it lands in the error list with the entry retained for a retry.
      #
      # @return [String, nil] the page id on success, nil when the cached page is gone
      def update_cached_page(scope, key, page_id, properties)
        @client.update_page(page_id: page_id, properties: properties)
        page_id
      rescue Woods::Error => e
        raise unless e.message.match?(STALE_PAGE_ERROR)

        warn "woods: notion sync cached page #{page_id} for #{key.inspect} is gone (#{e.message}) — recreating"
        @manifest.forget(scope, key)
        nil
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

      # Persist the manifest, downgrading failures to a warning: a lost
      # manifest only costs a full re-check next run, which must not turn an
      # otherwise-successful sync into a crash (called from ensure blocks,
      # where a raise would also mask any in-flight exception).
      #
      # @return [void]
      def save_manifest
        @manifest.save
      rescue StandardError => e
        warn "woods: notion sync manifest not persisted (#{e.message}) — next run re-checks every page"
      end

      # @param index_dir [String]
      # @return [SyncManifest]
      def build_manifest(index_dir)
        SyncManifest.new(path: File.join(index_dir, MANIFEST_FILENAME), database_ids: @database_ids)
      end

      # Truthy set mirrors the rake tasks' env_flag convention, so
      # WOODS_NOTION_FORCE=false / =0 disables rather than silently enabling.
      #
      # @return [Boolean]
      def env_force?
        %w[1 true yes].include?(ENV.fetch(FORCE_ENV_VAR, '').strip.downcase)
      end

      # @return [Hash]
      def empty_stats
        { synced: 0, skipped: 0, errors: [] }
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
