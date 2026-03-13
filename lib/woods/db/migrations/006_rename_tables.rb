# frozen_string_literal: true

module Woods
  module Db
    module Migrations
      # Renames codebase_* tables to woods_* as part of the gem rename.
      module RenameTables
        VERSION = 6

        # @param connection [Object] Database connection
        # @return [void]
        def self.up(connection)
          renames = {
            'codebase_units' => 'woods_units',
            'codebase_edges' => 'woods_edges',
            'codebase_embeddings' => 'woods_embeddings',
            'codebase_snapshots' => 'woods_snapshots',
            'codebase_snapshot_units' => 'woods_snapshot_units'
          }

          renames.each do |old_name, new_name|
            # Only rename if the old table exists (fresh installs won't have it)
            result = connection.execute(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='#{old_name}'"
            )
            next if result.empty?

            connection.execute("ALTER TABLE #{old_name} RENAME TO #{new_name}")
          end
        end
      end
    end
  end
end
