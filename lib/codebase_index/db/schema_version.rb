# frozen_string_literal: true

module CodebaseIndex
  module Db
    # Tracks which schema migrations have been applied.
    #
    # Uses a simple `codebase_index_schema_migrations` table with a single
    # `version` column. Works with any database connection that supports
    # `execute` and returns arrays (SQLite3, pg, mysql2).
    #
    # @example
    #   db = SQLite3::Database.new('codebase_index.db')
    #   sv = SchemaVersion.new(connection: db)
    #   sv.ensure_table!
    #   sv.current_version  # => 0
    #   sv.record_version(1)
    #   sv.current_version  # => 1
    #
    class SchemaVersion
      TABLE_NAME = 'codebase_index_schema_migrations'

      # @param connection [Object] Database connection supporting #execute
      def initialize(connection:)
        @connection = connection
      end

      # Create the schema migrations table if it does not exist.
      #
      # @return [void]
      def ensure_table!
        @connection.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{TABLE_NAME} (
            version INTEGER PRIMARY KEY NOT NULL,
            applied_at TEXT NOT NULL DEFAULT (datetime('now'))
          )
        SQL
      end

      # List all applied migration version numbers, sorted ascending.
      #
      # @return [Array<Integer>]
      def applied_versions
        rows = @connection.execute("SELECT version FROM #{TABLE_NAME} ORDER BY version ASC")
        rows.map { |row| row.is_a?(Array) ? row[0] : row['version'] }
      end

      # Record a migration version as applied.
      #
      # @param version [Integer] The migration version number
      # @return [void]
      def record_version(version)
        @connection.execute(
          "INSERT OR IGNORE INTO #{TABLE_NAME} (version) VALUES (?)", [version]
        )
      end

      # Check whether a version has been applied.
      #
      # @param version [Integer]
      # @return [Boolean]
      def applied?(version)
        applied_versions.include?(version)
      end

      # The highest applied version, or 0 if none.
      #
      # @return [Integer]
      def current_version
        applied_versions.last || 0
      end
    end
  end
end
