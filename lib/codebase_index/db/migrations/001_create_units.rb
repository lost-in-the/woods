# frozen_string_literal: true

module CodebaseIndex
  module Db
    module Migrations
      # Creates the codebase_units table for storing extracted unit metadata.
      module CreateUnits
        VERSION = 1

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection) # rubocop:disable Metrics/MethodLength
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS codebase_units (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_type TEXT NOT NULL,
              identifier TEXT NOT NULL,
              namespace TEXT,
              file_path TEXT NOT NULL,
              source_code TEXT,
              source_hash TEXT,
              metadata TEXT,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              updated_at TEXT NOT NULL DEFAULT (datetime('now')),
              UNIQUE(identifier)
            )
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_units_type ON codebase_units(unit_type)
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_units_file_path ON codebase_units(file_path)
          SQL
        end
      end
    end
  end
end
