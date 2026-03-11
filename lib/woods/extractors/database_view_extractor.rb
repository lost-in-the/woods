# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # DatabaseViewExtractor handles SQL view file extraction.
    #
    # Scans `db/views/` for Scenic gem convention SQL files
    # (e.g., `db/views/active_users_v01.sql`). Extracts one unit per
    # view name using the latest version only, parsing basic SQL metadata
    # (materialized flag, referenced tables, selected columns) via regex.
    #
    # @example
    #   extractor = DatabaseViewExtractor.new
    #   units = extractor.extract_all
    #   view = units.find { |u| u.identifier == "active_users" }
    #   view.metadata[:is_materialized] # => false
    #   view.metadata[:tables_referenced] # => ["users", "orders"]
    #
    class DatabaseViewExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Rails internal tables that should not generate model dependencies
      INTERNAL_TABLES = %w[
        schema_migrations
        ar_internal_metadata
        active_storage_blobs
        active_storage_attachments
        active_storage_variant_records
        action_text_rich_texts
        action_mailbox_inbound_emails
      ].freeze

      # SQL keywords that are not table names
      SQL_KEYWORDS = %w[
        select from where join inner outer left right full cross
        on and or not in is null true false as with having group by
        order limit offset union intersect except distinct all case when
        then else end between like ilike similar to cast values lateral
        returning exists any some
      ].freeze

      def initialize
        @views_dir = Rails.root.join('db/views')
        @has_directory = @views_dir.directory?
      end

      # Extract all database view units from db/views/.
      #
      # Only the latest version of each view is extracted.
      #
      # @return [Array<ExtractedUnit>] List of database view units
      def extract_all
        return [] unless @has_directory

        latest_view_files.filter_map do |file|
          extract_view_file(file)
        end
      end

      # Extract a single SQL view file.
      #
      # @param file_path [String] Absolute path to the SQL file
      # @return [ExtractedUnit, nil] The extracted unit or nil on failure
      def extract_view_file(file_path)
        source = File.read(file_path)
        view_name = extract_view_name(file_path)
        version   = extract_version(file_path)

        return nil unless view_name

        unit = ExtractedUnit.new(
          type: :database_view,
          identifier: view_name,
          file_path: file_path
        )

        unit.namespace = nil
        unit.source_code = annotate_source(source, view_name, version)
        unit.metadata = extract_metadata(source, view_name, version)
        unit.dependencies = extract_dependencies(source, unit.metadata)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract database view #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # File Discovery
      # ──────────────────────────────────────────────────────────────────────

      # Return only the latest-version SQL file for each view name.
      #
      # Scenic filenames: <view_name>_v<NN>.sql (e.g., active_users_v02.sql)
      # Groups by view name, picks the file with the highest version number.
      #
      # @return [Array<String>] Paths to latest-version files
      def latest_view_files
        all_files = Dir[@views_dir.join('*.sql')].select do |f|
          File.basename(f).match?(/\A\w+_v\d+\.sql\z/)
        end

        grouped = all_files.group_by { |f| extract_view_name(f) }
        grouped.values.map do |files|
          files.max_by { |f| extract_version(f) }
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Name and Version Parsing
      # ──────────────────────────────────────────────────────────────────────

      # Extract the view name (without version suffix) from the filename.
      #
      # @param file_path [String] Path to the SQL file
      # @return [String, nil] The view name (e.g., "active_users") or nil
      def extract_view_name(file_path)
        basename = File.basename(file_path, '.sql')
        match = basename.match(/\A(.+?)_v(\d+)\z/)
        match ? match[1] : nil
      end

      # Extract the integer version number from the filename.
      #
      # @param file_path [String] Path to the SQL file
      # @return [Integer] The version number (e.g., 1 for "_v01")
      def extract_version(file_path)
        basename = File.basename(file_path, '.sql')
        match = basename.match(/_v(\d+)\z/)
        match ? match[1].to_i : 0
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # Prepend a summary annotation to the SQL source.
      #
      # @param source [String] SQL source
      # @param view_name [String] The view name
      # @param version [Integer] The version number
      # @return [String] Annotated SQL
      def annotate_source(source, view_name, version)
        materialized = materialized_view?(source) ? 'YES' : 'NO'

        annotation = <<~ANNOTATION
          -- ╔═══════════════════════════════════════════════════════════════════════╗
          -- ║ Database View: #{view_name.ljust(52)}║
          -- ║ Version: #{version.to_s.ljust(59)}║
          -- ║ Materialized: #{materialized.ljust(54)}║
          -- ╚═══════════════════════════════════════════════════════════════════════╝

        ANNOTATION

        annotation + source
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build the metadata hash for a database view unit.
      #
      # @param source [String] SQL source
      # @param view_name [String] The view name
      # @param version [Integer] The version number
      # @return [Hash] View metadata
      def extract_metadata(source, view_name, version)
        {
          view_name: view_name,
          version: version,
          is_materialized: materialized_view?(source),
          tables_referenced: extract_referenced_tables(source),
          columns_selected: extract_selected_columns(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('--') }
        }
      end

      # Detect whether this is a materialized view.
      #
      # @param source [String] SQL source
      # @return [Boolean]
      def materialized_view?(source)
        source.match?(/\bMATERIALIZED\b/i)
      end

      # Extract table names referenced in FROM and JOIN clauses.
      #
      # Uses a simple regex approach. Handles basic FROM/JOIN patterns
      # and filters out SQL keywords and subqueries.
      #
      # @param source [String] SQL source
      # @return [Array<String>] Deduplicated table names (lowercase)
      def extract_referenced_tables(source)
        tables = []

        # FROM clause: FROM table_name [alias]
        source.scan(/\bFROM\s+([a-zA-Z_][a-zA-Z0-9_]*)/i).flatten.each do |t|
          tables << t.downcase unless sql_keyword?(t)
        end

        # JOIN clauses: [INNER|LEFT|RIGHT|...] JOIN table_name
        source.scan(/\bJOIN\s+([a-zA-Z_][a-zA-Z0-9_]*)/i).flatten.each do |t|
          tables << t.downcase unless sql_keyword?(t)
        end

        tables.uniq
      end

      # Extract column names from the SELECT clause.
      #
      # Handles simple column names and table.column patterns.
      # Returns '*' for SELECT * queries.
      #
      # @param source [String] SQL source
      # @return [Array<String>] Column names
      def extract_selected_columns(source)
        # Find the SELECT ... FROM block
        select_match = source.match(/\bSELECT\s+(.+?)\s+FROM\b/im)
        return [] unless select_match

        select_clause = select_match[1].strip
        return ['*'] if select_clause == '*'

        # Split on commas, strip whitespace and aliases, handle table.column
        select_clause.split(',').filter_map do |col|
          col = col.strip
          # Remove AS alias: "col AS alias" or "table.col alias" → take first token
          col = col.split(/\s+AS\s+/i).first.strip
          # For table.column, take the column part
          col = col.split('.').last.strip
          # Skip expressions, subqueries, and empty strings
          next if col.empty? || col.include?('(') || col.include?(')')

          col.delete('"').delete("'")
        end.uniq
      end

      # Check if a token is a SQL keyword.
      #
      # @param token [String] The token to check
      # @return [Boolean]
      def sql_keyword?(token)
        SQL_KEYWORDS.include?(token.downcase)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build the dependency array by linking referenced tables to models.
      #
      # Uses the same table → model classify pattern as MigrationExtractor.
      #
      # @param source [String] SQL source
      # @param metadata [Hash] Extracted metadata
      # @return [Array<Hash>] Dependency hashes with :type, :target, :via
      def extract_dependencies(_source, metadata)
        deps = []

        metadata[:tables_referenced].each do |table|
          next if INTERNAL_TABLES.include?(table)

          model_name = table.classify
          deps << { type: :model, target: model_name, via: :table_name }
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
