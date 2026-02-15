# frozen_string_literal: true

module CodebaseIndex
  module Db
    module Migrations
      # Creates the codebase_edges table for storing unit relationships.
      module CreateEdges
        VERSION = 2

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection) # rubocop:disable Metrics/MethodLength
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS codebase_edges (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source_id INTEGER NOT NULL,
              target_id INTEGER NOT NULL,
              relationship TEXT NOT NULL,
              via TEXT,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              FOREIGN KEY (source_id) REFERENCES codebase_units(id),
              FOREIGN KEY (target_id) REFERENCES codebase_units(id)
            )
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_edges_source ON codebase_edges(source_id)
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_edges_target ON codebase_edges(target_id)
          SQL
        end
      end
    end
  end
end
