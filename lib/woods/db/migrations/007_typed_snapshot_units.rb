# frozen_string_literal: true

module Woods
  module Db
    module Migrations
      # Preserve the full identity of units sharing a name across extractor types.
      module TypedSnapshotUnits
        VERSION = 7

        def self.up(connection)
          sql = connection.get_first_value("SELECT sql FROM sqlite_master WHERE name = 'woods_snapshot_units'")
          CreateSnapshotUnits.up(connection) if sql.nil?
          return if sql&.match?(/UNIQUE\s*\(snapshot_id, identifier, unit_type\)/i)

          connection.transaction do
            create_table(connection)
            connection.execute('INSERT INTO woods_snapshot_units_typed SELECT * FROM woods_snapshot_units')
            connection.execute('DROP TABLE woods_snapshot_units')
            connection.execute('ALTER TABLE woods_snapshot_units_typed RENAME TO woods_snapshot_units')
            connection.execute('CREATE INDEX idx_snapshot_units_identifier ON woods_snapshot_units(identifier)')
            connection.execute('CREATE INDEX idx_snapshot_units_snapshot ON woods_snapshot_units(snapshot_id)')
          end
        end

        def self.create_table(connection)
          connection.execute(<<~SQL)
            CREATE TABLE woods_snapshot_units_typed (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              snapshot_id INTEGER NOT NULL,
              identifier TEXT NOT NULL,
              unit_type TEXT NOT NULL,
              source_hash TEXT,
              metadata_hash TEXT,
              dependencies_hash TEXT,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              FOREIGN KEY (snapshot_id) REFERENCES woods_snapshots(id),
              UNIQUE(snapshot_id, identifier, unit_type)
            )
          SQL
        end
        private_class_method :create_table
      end
    end
  end
end
