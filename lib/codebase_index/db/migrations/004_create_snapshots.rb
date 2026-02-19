# frozen_string_literal: true

module CodebaseIndex
  module Db
    module Migrations
      # Creates the codebase_snapshots table for temporal index tracking.
      #
      # Each row represents one extraction run anchored to a git commit SHA.
      # Stores aggregate stats and diff counts vs. the previous snapshot.
      module CreateSnapshots
        VERSION = 4

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection) # rubocop:disable Metrics/MethodLength
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS codebase_snapshots (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              git_sha TEXT NOT NULL,
              git_branch TEXT,
              extracted_at TEXT NOT NULL,
              rails_version TEXT,
              ruby_version TEXT,
              total_units INTEGER NOT NULL DEFAULT 0,
              unit_counts TEXT,
              gemfile_lock_sha TEXT,
              schema_sha TEXT,
              units_added INTEGER DEFAULT 0,
              units_modified INTEGER DEFAULT 0,
              units_deleted INTEGER DEFAULT 0,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              UNIQUE(git_sha)
            )
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_snapshots_extracted_at ON codebase_snapshots(extracted_at)
          SQL
          connection.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS idx_snapshots_branch ON codebase_snapshots(git_branch)
          SQL
        end
      end
    end
  end
end
