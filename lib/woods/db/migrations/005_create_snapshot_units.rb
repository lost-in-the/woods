# frozen_string_literal: true

module Woods
  module Db
    module Migrations
      # Creates the woods_snapshot_units table for per-unit temporal tracking.
      #
      # Each row links a unit (by identifier) to a snapshot, storing content hashes
      # for efficient diff computation without duplicating full source code.
      module CreateSnapshotUnits
        VERSION = 5

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection)
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS woods_snapshot_units (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              snapshot_id INTEGER NOT NULL,
              identifier TEXT NOT NULL,
              unit_type TEXT NOT NULL,
              source_hash TEXT,
              metadata_hash TEXT,
              dependencies_hash TEXT,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              FOREIGN KEY (snapshot_id) REFERENCES woods_snapshots(id),
              UNIQUE(snapshot_id, identifier)
            )
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_snapshot_units_identifier ON woods_snapshot_units(identifier)
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_snapshot_units_snapshot ON woods_snapshot_units(snapshot_id)
          SQL
        end
      end
    end
  end
end
