# frozen_string_literal: true

module Woods
  module Db
    # Tracks which schema migrations have been applied.
    #
    # Uses a simple `woods_schema_migrations` table with a single
    # `version` column. **SQLite-only**: the DDL/DML here relies on
    # SQLite-specific syntax (`datetime('now')` as a column default,
    # `INSERT OR IGNORE`, `?` positional placeholders), and both real call
    # sites ({Woods::Db::Migrator}'s callers) pass an `SQLite3::Database`.
    # Pgvector/MySQL hosts should use their own migration path (see the
    # pgvector generator's own migrations) rather than this class.
    #
    # @example
    #   db = SQLite3::Database.new('woods.db')
    #   sv = SchemaVersion.new(connection: db)
    #   sv.ensure_table!
    #   sv.current_version  # => 0
    #   sv.record_version(1)
    #   sv.current_version  # => 1
    #
    class SchemaVersion
      TABLE_NAME = 'woods_schema_migrations'

      # The pre-rename gem's ledger. Migration 006 renames the data tables but
      # nothing renames the bookkeeping table itself, so a genuine legacy
      # database would otherwise present an empty ledger, re-run 001-005 and
      # then wedge on 006's `ALTER TABLE codebase_units RENAME TO woods_units`
      # against a table 001 had just created.
      LEGACY_TABLE_NAME = 'codebase_index_schema_migrations'

      # @param connection [Object] Database connection supporting #execute
      def initialize(connection:)
        @connection = connection
      end

      # Create the schema migrations table if it does not exist.
      #
      # Adopts a pre-rename ledger first, so applied versions carried over from
      # the `codebase_index` era are honoured instead of replayed.
      #
      # @return [void]
      def ensure_table!
        adopt_legacy_table!
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

      private

      # Rename a pre-rename ledger into place. Idempotent: a no-op once the
      # rename has happened, and on fresh installs where no legacy table
      # exists. When both ledgers exist (a database wedged by the pre-fix
      # migrator, then upgraded) the woods table wins and the legacy one is
      # left in place for the operator rather than merged or dropped.
      #
      # @return [void]
      def adopt_legacy_table!
        return unless table_exists?(LEGACY_TABLE_NAME)

        if table_exists?(TABLE_NAME)
          warn "[woods] both #{LEGACY_TABLE_NAME} and #{TABLE_NAME} exist; using #{TABLE_NAME} and " \
               "leaving the legacy ledger in place — drop #{LEGACY_TABLE_NAME} once its versions are reconciled"
          return
        end

        @connection.execute("ALTER TABLE #{LEGACY_TABLE_NAME} RENAME TO #{TABLE_NAME}")
      end

      # @param name [String] Table name
      # @return [Boolean] Whether the table exists in this SQLite database
      def table_exists?(name)
        rows = @connection.execute(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?", [name]
        )
        !rows.empty?
      end
    end
  end
end
