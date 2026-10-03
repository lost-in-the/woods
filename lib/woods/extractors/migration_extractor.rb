# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'migration_declaration'
require_relative 'table_catalog'

module Woods
  module Extractors
    # MigrationExtractor handles ActiveRecord migration file extraction.
    #
    # Scans `db/migrate/*.rb` for migration files and produces one
    # ExtractedUnit per migration. Extracts DDL metadata (tables, columns,
    # indexes, references), reversibility, risk indicators (data migrations,
    # raw SQL), and links every table it names to that table's unit. A model
    # edge is kept only where a model owns the table today, as the live
    # schema reports it; no class name is guessed from a table name.
    #
    # @example
    #   extractor = MigrationExtractor.new
    #   units = extractor.extract_all
    #   create_users = units.find { |u| u.identifier == "CreateUsers" }
    #   create_users.metadata[:tables_affected] # => ["users"]
    #
    class MigrationExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # DDL operations that take a table name as the first symbol argument
      TABLE_OPERATIONS = %w[
        create_table
        change_table
        drop_table
        rename_table
        add_column
        remove_column
        change_column
        rename_column
        add_index
        remove_index
        add_reference
        remove_reference
        add_belongs_to
        remove_belongs_to
        add_foreign_key
        remove_foreign_key
        add_timestamps
        remove_timestamps
        change_column_default
        change_column_null
      ].freeze

      # Block-form DDL openers whose `do |t|` body declares columns. Only
      # `create_table` was scanned, so a `change_table :orders do |t|` block
      # contributed neither a table nor a column (EXTB-18).
      TABLE_BLOCK_OPENERS = '(?:create_table|change_table)'

      # Column type methods used inside create_table and change_table blocks
      COLUMN_TYPE_METHODS = %w[
        string integer float decimal boolean binary text
        date datetime time timestamp
        bigint numeric json jsonb uuid inet cidr
        hstore ltree point polygon
      ].freeze

      # Patterns indicating data migration (not just DDL)
      DATA_MIGRATION_PATTERNS = [
        /\.update_all\b/,
        /\.find_each\b/,
        /\.find_in_batches\b/,
        /\.update!\b/,
        /\.update\b/,
        /\.save!\b/,
        /\.save\b/,
        /\.delete_all\b/,
        /\.destroy_all\b/
      ].freeze

      # A table name written as a symbol or a string literal.
      TABLE_NAME = '(?::(\\w++)|["\'](\\w++)["\'])'

      # Tables named as the second argument of a two-table operation.
      SECOND_TABLE_PATTERN = /(?:add|remove)_foreign_key\s*+\(?\s*+[:"']\w++["']?\s*+,\s*+#{TABLE_NAME}/

      # An explicit foreign key target: `foreign_key: { to_table: :owners }`.
      TO_TABLE_PATTERN = /\bto_table:\s*+#{TABLE_NAME}/

      JOIN_TABLE_PATTERN = /create_join_table\s*+\(?\s*+#{TABLE_NAME}\s*+,\s*+#{TABLE_NAME}/

      # @param table_catalog [TableCatalog, nil] defaults to the running application's tables
      def initialize(table_catalog: nil)
        @table_catalog = table_catalog
        @migrate_dir = Rails.root.join('db/migrate')
        @has_directory = @migrate_dir.directory?
      end

      # Extract all migration files from db/migrate/
      #
      # @return [Array<ExtractedUnit>] List of migration units, sorted by timestamp
      def extract_all
        return [] unless @has_directory

        files = Dir[@migrate_dir.join('*.rb')]
        files.filter_map { |file| extract_migration_file(file) }
      end

      # Extract a single migration file
      #
      # @param file_path [String] Path to the migration file
      # @return [ExtractedUnit, nil] The extracted unit or nil if not a migration
      def extract_migration_file(file_path)
        source = File.read(file_path)
        declaration = MigrationDeclaration.new(source: source, file_path: file_path).call
        return nil unless declaration

        class_name = declaration.fetch(:identifier)

        unit = ExtractedUnit.new(
          type: :migration,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.metadata = extract_metadata(declaration.fetch(:source), file_path)
        unit.source_code = annotate_source(source, class_name, unit.metadata)
        unit.dependencies = extract_dependencies(source, unit.metadata)

        unit
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract migration #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String] Ruby source code
      # @param file_path [String] Path to the migration file
      # @return [Hash] Migration metadata
      def extract_metadata(source, file_path)
        tables = extract_tables_affected(source)
        direction = detect_direction(source)
        references_added = extract_references_added(source)
        references_removed = extract_references_removed(source)
        referenced = extract_tables_referenced(source, references_added + references_removed)

        {
          migration_version: extract_migration_version(file_path),
          rails_version: extract_rails_version(source),
          reversible: %w[change up_down].include?(direction),
          direction: direction,
          tables_affected: tables,
          tables_referenced: referenced,
          tables_unresolved: unresolved_tables(tables + referenced),
          columns_added: extract_columns_added(source),
          columns_removed: extract_columns_removed(source),
          indexes_added: extract_indexes_added(source),
          indexes_removed: extract_indexes_removed(source),
          references_added: references_added,
          references_removed: references_removed,
          operations: extract_operations(source),
          has_data_migration: data_migration?(source),
          has_execute_sql: source.match?(/\bexecute\s/),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') }
        }
      end

      # Extract migration timestamp from filename.
      #
      # @param file_path [String] Path to the migration file
      # @return [String, nil] The timestamp or nil
      def extract_migration_version(file_path)
        basename = File.basename(file_path)
        match = basename.match(/\A(\d{14})_/)
        match ? match[1] : nil
      end

      # Extract Rails version from migration bracket notation.
      #
      # @param source [String] Ruby source code
      # @return [String, nil] The Rails version or nil
      def extract_rails_version(source)
        match = source.match(/ActiveRecord::Migration\[(\d+\.\d+)\]/)
        match ? match[1] : nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Direction / Reversibility
      # ──────────────────────────────────────────────────────────────────────

      # Detect migration direction from method definitions.
      #
      # @param source [String] Ruby source code
      # @return [String] One of "change", "up_down", "up_only", "unknown"
      def detect_direction(source)
        has_change = source.match?(/^\s*def\s+change\b/)
        has_up = source.match?(/^\s*def\s+up\b/)
        has_down = source.match?(/^\s*def\s+down\b/)

        if has_change
          'change'
        elsif has_up && has_down
          'up_down'
        elsif has_up
          'up_only'
        else
          'unknown'
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # DDL Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Extract all tables affected by DDL operations.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Deduplicated table names
      def extract_tables_affected(source)
        tables = []

        TABLE_OPERATIONS.each do |op|
          source.scan(/#{op}\s*+\(?\s*+#{TABLE_NAME}/).each do |symbol, string|
            tables << (symbol || string)
          end
        end

        source.scan(JOIN_TABLE_PATTERN).each { |match| tables << match.compact.sort.join('_') }

        # rename_table has two table arguments
        source.scan(/rename_table\s+:\w+\s*,\s*:(\w+)/).each do |match|
          tables << match[0]
        end

        tables.uniq
      end

      # Tables a migration points at without changing them: reference and
      # foreign key targets, and the two sides of a join table.
      #
      # @param source [String] Ruby source code
      # @param references [Array<Hash>] reference hashes with :reference
      # @return [Array<String>] sorted, deduplicated table names
      def extract_tables_referenced(source, references)
        tables = references.map { |ref| ref[:reference].pluralize }
        [SECOND_TABLE_PATTERN, TO_TABLE_PATTERN, JOIN_TABLE_PATTERN].each do |pattern|
          source.scan(pattern).each { |match| tables.concat(match.compact) }
        end
        tables.uniq.sort
      end

      # Named tables the live schema does not have: dropped since, renamed,
      # or a reference whose table is not the plural of its name.
      #
      # @param tables [Array<String>]
      # @return [Array<String>] sorted
      def unresolved_tables(tables)
        tables.uniq.reject do |table|
          TableCatalog::INTERNAL_TABLES.include?(table) || table_catalog.named(table).any?
        end.sort
      end

      # @return [TableCatalog]
      def table_catalog
        @table_catalog ||= TableCatalog.from_runtime
      end

      # Extract columns added via add_column and create_table block columns.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Column info hashes with :table, :column, :type
      def extract_columns_added(source)
        # add_column :table, :column, :type
        columns = source.scan(/add_column\s+:(\w+)\s*,\s*:(\w+)\s*,\s*:(\w+)/).map do |table, column, type|
          { table: table, column: column, type: type }
        end

        # t.type :column inside create_table/change_table blocks
        extract_block_columns(source, columns)

        # t.column :name, :type
        extract_explicit_column_calls(source, columns)

        columns
      end

      # Extract columns removed via remove_column.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Column info hashes
      def extract_columns_removed(source)
        source.scan(/remove_column\s+:(\w+)\s*,\s*:(\w+)(?:\s*,\s*:(\w+))?/).map do |table, column, type|
          { table: table, column: column, type: type || 'unknown' }
        end
      end

      # Extract indexes added via add_index.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Index info hashes with :table, :column
      def extract_indexes_added(source)
        source.scan(/add_index\s+:(\w+)\s*,\s*(.+?)(?:\s*,\s*\w+:|$)/m).map do |table, column_expr|
          column = column_expr.strip.sub(/\s*,\s*\w+:.*\z/m, '').strip
          # Handle array syntax for composite indexes: [:user_id, :created_at]
          column = if column.start_with?('[')
                     column.gsub(/[\[\]:"\s]/, '')
                   else
                     column.delete(':').strip
                   end
          { table: table, column: column }
        end
      end

      # Extract indexes removed via remove_index.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Index info hashes
      def extract_indexes_removed(source)
        source.scan(/remove_index\s+:(\w+)\s*,\s*:(\w+)/).map do |table, column|
          { table: table, column: column }
        end
      end

      # Extract references added via add_reference or t.references.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Reference info hashes with :table, :reference
      def extract_references_added(source)
        # add_reference :table, :reference
        refs = source.scan(/add_reference\s+:(\w+)\s*,\s*:(\w+)/).map do |table, reference|
          { table: table, reference: reference }
        end

        # t.references :ref inside create_table/change_table blocks
        extract_block_references(source, refs)

        refs
      end

      # Extract references removed via remove_reference.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Reference info hashes
      def extract_references_removed(source)
        source.scan(/remove_reference\s+:(\w+)\s*,\s*:(\w+)/).map do |table, reference|
          { table: table, reference: reference }
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Block Column / Reference Parsing
      # ──────────────────────────────────────────────────────────────────────

      # Extract t.type :column declarations inside create_table/change_table blocks.
      #
      # @param source [String] Ruby source code
      # @param columns [Array<Hash>] Accumulator array
      # @return [void]
      def extract_block_columns(source, columns)
        # Find create_table/change_table blocks and parse t.type :column patterns
        source.scan(/#{TABLE_BLOCK_OPENERS}\s+:(\w+).*?do\s*\|(\w+)\|(.+?)^\s*end/m).each do |table, var, block|
          type_pattern = COLUMN_TYPE_METHODS.join('|')
          block.scan(/#{var}\.(#{type_pattern})\s+:(\w+)/).each do |type, column|
            columns << { table: table, column: column, type: type }
          end
        end
      end

      # Extract t.column :name, :type declarations inside create_table/change_table blocks.
      #
      # @param source [String] Ruby source code
      # @param columns [Array<Hash>] Accumulator array
      # @return [void]
      def extract_explicit_column_calls(source, columns)
        source.scan(/#{TABLE_BLOCK_OPENERS}\s+:(\w+).*?do\s*\|(\w+)\|(.+?)^\s*end/m).each do |table, var, block|
          block.scan(/#{var}\.column\s+:(\w+)\s*,\s*:(\w+)/).each do |column, type|
            columns << { table: table, column: column, type: type }
          end
        end
      end

      # Extract t.references declarations inside create_table/change_table blocks.
      #
      # @param source [String] Ruby source code
      # @param refs [Array<Hash>] Accumulator array
      # @return [void]
      def extract_block_references(source, refs)
        source.scan(/#{TABLE_BLOCK_OPENERS}\s+:(\w+).*?do\s*\|(\w+)\|(.+?)^\s*end/m).each do |table, var, block|
          block.scan(/#{var}\.references\s+:(\w+)/).each do |reference,|
            refs << { table: table, reference: reference }
          end
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Operations Tracking
      # ──────────────────────────────────────────────────────────────────────

      # Extract operation counts from migration source.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Operation hashes with :operation, :count
      def extract_operations(source)
        ops = Hash.new(0)

        TABLE_OPERATIONS.each do |op|
          count = source.scan(/#{op}\s+:/).size
          ops[op] = count if count.positive?
        end

        ops.map { |op, count| { operation: op, count: count } }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Risk Indicators
      # ──────────────────────────────────────────────────────────────────────

      # Detect data migration patterns in source.
      #
      # @param source [String] Ruby source code
      # @return [Boolean]
      def data_migration?(source)
        DATA_MIGRATION_PATTERNS.any? { |pattern| source.match?(pattern) }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String] Ruby source code
      # @param class_name [String] The migration class name
      # @param metadata [Hash] Extracted metadata
      # @return [String] Annotated source
      def annotate_source(source, class_name, metadata)
        version = metadata[:migration_version] || 'none'
        tables = metadata[:tables_affected].join(', ')
        tables_display = tables.length > 59 ? "#{tables[0, 56]}..." : tables
        direction = metadata[:direction]

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Migration: #{class_name.ljust(57)}║
          # ║ Version: #{version.ljust(59)}║
          # ║ Direction: #{direction.ljust(57)}║
          # ║ Tables: #{tables_display.ljust(60)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Every named table resolves through the live table catalog. A table
      # the schema no longer has yields no edge at all, so a migration never
      # points at a model that was renamed or removed.
      #
      # @param source [String] Ruby source code
      # @param metadata [Hash] Extracted metadata
      # @return [Array<Hash>] Dependency hashes
      def extract_dependencies(source, metadata)
        affected = metadata[:tables_affected].flat_map { |name| table_catalog.named(name) }
        referenced = metadata[:tables_referenced].flat_map { |name| table_catalog.named(name) }

        deps = (affected + referenced).map(&:identifier).uniq.sort.map do |identifier|
          { type: :database_table, target: identifier, via: :migrates }
        end
        deps.concat(model_dependencies(affected, :table_name))
        deps.concat(model_dependencies(referenced, :reference))

        # Scan data migration code for common dependencies
        deps.concat(scan_common_dependencies(source))

        consolidate_dependencies(deps)
      end

      # @param tables [Array<TableCatalog::Table>]
      # @param via [Symbol]
      # @return [Array<Hash>] one edge per owning model, sorted by name
      def model_dependencies(tables, via)
        tables.filter_map(&:model).uniq.sort.map { |model| { type: :model, target: model, via: via } }
      end
    end
  end
end
