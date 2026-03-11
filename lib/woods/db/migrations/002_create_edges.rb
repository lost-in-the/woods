# frozen_string_literal: true

module Woods
  module Db
    module Migrations
      # Creates the woods_edges table for storing unit relationships.
      module CreateEdges
        VERSION = 2

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection)
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS woods_edges (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source_id INTEGER NOT NULL,
              target_id INTEGER NOT NULL,
              relationship TEXT NOT NULL,
              via TEXT,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              FOREIGN KEY (source_id) REFERENCES woods_units(id),
              FOREIGN KEY (target_id) REFERENCES woods_units(id)
            )
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_woods_edges_source ON woods_edges(source_id)
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_woods_edges_target ON woods_edges(target_id)
          SQL
        end
      end
    end
  end
end
