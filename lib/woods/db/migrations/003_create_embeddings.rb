# frozen_string_literal: true

module Woods
  module Db
    module Migrations
      # Creates the woods_embeddings table for storing vector embeddings.
      # Uses TEXT for embedding storage (JSON array) for database portability.
      # Pgvector users should use the pgvector generator for native vector columns.
      module CreateEmbeddings
        VERSION = 3

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection)
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS woods_embeddings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_id INTEGER NOT NULL,
              chunk_type TEXT,
              embedding TEXT NOT NULL,
              content_hash TEXT NOT NULL,
              dimensions INTEGER NOT NULL,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              FOREIGN KEY (unit_id) REFERENCES woods_units(id)
            )
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_woods_embeddings_unit ON woods_embeddings(unit_id)
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_woods_embeddings_hash ON woods_embeddings(content_hash)
          SQL
        end
      end
    end
  end
end
