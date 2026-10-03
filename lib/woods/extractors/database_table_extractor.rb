# frozen_string_literal: true

require_relative '../extracted_unit'
require_relative '../source_inputs/consumer_errors'
require_relative 'table_catalog'

module Woods
  module Extractors
    # DatabaseTableExtractor emits one unit per table in the live schema.
    #
    # The connection is the source: columns, indexes, foreign keys and the
    # primary key are asked of each connected database, never parsed out of
    # `db/schema.rb`. A table no Active Record model owns (a legacy table,
    # another application's table, a join or backup table) still gets a unit,
    # flagged `model_less`, so migrations and declared consumers have a node
    # to point at.
    #
    # @example
    #   units = DatabaseTableExtractor.new.extract_all
    #   legacy = units.find { |u| u.identifier == "table:legacy_sessions" }
    #   legacy.metadata[:model_less] # => true
    #
    class DatabaseTableExtractor
      # Schema dumps, one per database (`db/schema.rb`, `db/billing_schema.rb`).
      SCHEMA_FILE_GLOBS = %w[db/schema.rb db/structure.sql db/*_schema.rb db/*_structure.sql].freeze

      MIGRATION_GLOBS = %w[db/migrate/**/*.rb].freeze

      MODEL_DIRECTORY = 'app/models/'

      # Whether a changed path can change the table set or which model owns a
      # table. Table units depend on the live schema and on model ownership,
      # so any of these re-runs the extractor wholesale.
      #
      # @param relative_path [String] Rails.root-relative path
      # @return [Boolean]
      def self.trigger_path?(relative_path)
        path = relative_path.to_s
        return model_path?(path) unless path.start_with?('db/')

        (SCHEMA_FILE_GLOBS + MIGRATION_GLOBS).any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME) }
      end

      # @param path [String]
      # @return [Boolean]
      def self.model_path?(path)
        path.end_with?('.rb') && path.start_with?(MODEL_DIRECTORY)
      end

      # @param table_catalog [TableCatalog, nil] defaults to the running application's tables
      def initialize(table_catalog: nil)
        @table_catalog = table_catalog
      end

      # Extract a unit for every live table.
      #
      # @return [Array<ExtractedUnit>] sorted by identifier
      def extract_all
        catalog = @table_catalog || TableCatalog.from_runtime
        catalog.tables.filter_map { |table| extract_table(table, catalog) }
      end

      # Extract one table.
      #
      # @param table [TableCatalog::Table]
      # @param catalog [TableCatalog] resolves foreign key targets
      # @return [ExtractedUnit, nil] nil when the table's schema cannot be read
      def extract_table(table, catalog)
        schema = table.pool.with_connection { |connection| read_schema(connection, table.name) }

        unit = ExtractedUnit.new(type: :database_table, identifier: table.identifier, file_path: nil)
        unit.namespace = nil
        unit.metadata = build_metadata(table, schema)
        unit.source_code = render_source(unit.metadata)
        unit.dependencies = foreign_key_dependencies(table, schema[:foreign_keys], catalog)
        unit
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract database table #{table.name}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Schema reads
      # ──────────────────────────────────────────────────────────────────────

      # @return [Hash] `{ columns:, indexes:, foreign_keys:, primary_key: }`
      def read_schema(connection, name)
        {
          columns: connection.columns(name).map { |column| column_facts(column) },
          indexes: connection.indexes(name).map { |index| index_facts(index) }.sort_by { |index| index[:name] },
          foreign_keys: read_foreign_keys(connection, name),
          primary_key: primary_key_of(connection, name)
        }
      end

      # Default *presence* only: a default value can be data, and the unit is
      # about shape.
      def column_facts(column)
        function = column.respond_to?(:default_function) ? column.default_function : nil
        {
          name: column.name.to_s,
          type: column.type.to_s,
          sql_type: column.sql_type.to_s,
          null: column.null ? true : false,
          has_default: !column.default.nil? || !function.nil?
        }
      end

      # An expression index reports its columns as one SQL string.
      def index_facts(index)
        { name: index.name.to_s, columns: Array(index.columns).map(&:to_s), unique: index.unique ? true : false }
      end

      def read_foreign_keys(connection, name)
        return [] if connection.respond_to?(:supports_foreign_keys?) && !connection.supports_foreign_keys?

        keys = connection.foreign_keys(name).map do |key|
          { from_table: key.from_table.to_s, to_table: key.to_table.to_s, column: key.column.to_s,
            primary_key: key.primary_key&.to_s, name: key.name&.to_s }
        end
        keys.sort_by { |key| [key[:column], key[:to_table], key[:name].to_s] }
      rescue NotImplementedError
        []
      end

      # @return [String, Array<String>, nil]
      def primary_key_of(connection, name)
        keys = Array(connection.primary_keys(name)).map(&:to_s)
        keys.size > 1 ? keys : keys.first
      end

      # ──────────────────────────────────────────────────────────────────────
      # Unit assembly
      # ──────────────────────────────────────────────────────────────────────

      def build_metadata(table, schema)
        models = Array(table.models)
        {
          table_name: table.name,
          database: table.database,
          model: models.first,
          models: models,
          model_less: models.empty?,
          primary_key: schema[:primary_key],
          column_count: schema[:columns].size,
          columns: schema[:columns],
          indexes: schema[:indexes],
          foreign_keys: schema[:foreign_keys]
        }
      end

      # A foreign key cannot leave its database, so the target is the table of
      # that name in the same database.
      def foreign_key_dependencies(table, foreign_keys, catalog)
        targets = foreign_keys.filter_map do |key|
          next if key[:to_table] == table.name

          catalog.named(key[:to_table]).find { |candidate| candidate.database == table.database }&.identifier
        end
        targets.uniq.sort.map { |identifier| { type: :database_table, target: identifier, via: :foreign_key } }
      end

      def render_source(metadata)
        lines = ["Table: #{metadata[:table_name]}"]
        lines << "Database: #{metadata[:database]}" if metadata[:database]
        lines << "Model: #{metadata[:model] || 'none (no Active Record model owns this table)'}"
        lines << "Primary key: #{Array(metadata[:primary_key]).join(', ')}" if metadata[:primary_key]
        lines.concat(section('Columns', metadata[:columns].map { |column| render_column(column) }))
        lines.concat(section('Indexes', metadata[:indexes].map { |index| render_index(index) }))
        lines.concat(section('Foreign keys', metadata[:foreign_keys].map { |key| render_foreign_key(key) }))
        "#{lines.join("\n")}\n"
      end

      def section(title, rows)
        rows.empty? ? [] : ['', "#{title}:", *rows.map { |row| "  #{row}" }]
      end

      def render_column(column)
        flags = []
        flags << 'NOT NULL' unless column[:null]
        flags << 'DEFAULT' if column[:has_default]
        [column[:name].ljust(28), column[:sql_type].ljust(18), flags.join(' ')].join(' ').rstrip
      end

      def render_index(index)
        "#{index[:name]}: [#{index[:columns].join(', ')}]#{' (unique)' if index[:unique]}"
      end

      def render_foreign_key(key)
        "#{key[:column]} -> #{key[:to_table]}.#{key[:primary_key] || 'id'}"
      end
    end
  end
end
