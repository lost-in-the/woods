# frozen_string_literal: true

module CodebaseIndex
  module Db
    module Migrations
      # Creates the codebase_embeddings table for storing vector embeddings.
      # Uses TEXT for embedding storage (JSON array) for database portability.
      # Pgvector users should use the pgvector generator for native vector columns.
      module CreateEmbeddings
        VERSION = 3

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection) # rubocop:disable Metrics/MethodLength
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS codebase_embeddings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_id INTEGER NOT NULL,
              chunk_type TEXT,
              embedding TEXT NOT NULL,
              content_hash TEXT NOT NULL,
              dimensions INTEGER NOT NULL,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              FOREIGN KEY (unit_id) REFERENCES codebase_units(id)
            )
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_embeddings_unit ON codebase_embeddings(unit_id)
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_codebase_embeddings_hash ON codebase_embeddings(content_hash)
          SQL
        end
      end
    end
  end
end
