# frozen_string_literal: true

require 'json'
require 'time'

module CodebaseIndex
  module Temporal
    # SnapshotStore captures and queries temporal snapshots of extraction runs.
    #
    # Each snapshot is anchored to a git commit SHA and stores per-unit content
    # hashes for efficient diff computation. Full source is not duplicated —
    # only hashes of source, metadata, and dependencies are stored per snapshot.
    #
    # @example Capturing a snapshot
    #   store = SnapshotStore.new(connection: db)
    #   store.capture(manifest, unit_hashes)
    #
    # @example Comparing snapshots
    #   diff = store.diff("abc123", "def456")
    #   diff[:added]    # => [{ identifier: "NewModel", ... }]
    #   diff[:modified] # => [{ identifier: "User", ... }]
    #   diff[:deleted]  # => [{ identifier: "OldService", ... }]
    #
    class SnapshotStore # rubocop:disable Metrics/ClassLength
      # @param connection [Object] Database connection supporting #execute and #get_first_row
      def initialize(connection:)
        @db = connection
      end

      # Capture a snapshot after extraction completes.
      #
      # Stores the manifest metadata and per-unit content hashes.
      # Computes diff stats vs. the most recent previous snapshot.
      #
      # @param manifest [Hash] The manifest data (string or symbol keys)
      # @param unit_hashes [Array<Hash>] Per-unit content hashes
      # @return [Hash] Snapshot record with diff stats
      def capture(manifest, unit_hashes)
        git_sha = mget(manifest, 'git_sha')
        return nil unless git_sha

        previous = find_latest
        upsert_snapshot(manifest, git_sha, unit_hashes.size)

        snapshot_id = fetch_snapshot_id(git_sha)
        @db.execute('DELETE FROM codebase_snapshot_units WHERE snapshot_id = ?', [snapshot_id])
        insert_unit_hashes(snapshot_id, unit_hashes)

        update_diff_stats(snapshot_id, previous)
        find(git_sha)
      end

      # List snapshots, optionally filtered by branch.
      #
      # @param limit [Integer] Max results (default 20)
      # @param branch [String, nil] Filter by branch name
      # @return [Array<Hash>] Snapshot summaries sorted by extracted_at descending
      def list(limit: 20, branch: nil)
        rows = if branch
                 @db.execute(
                   'SELECT * FROM codebase_snapshots WHERE git_branch = ? ORDER BY extracted_at DESC LIMIT ?',
                   [branch, limit]
                 )
               else
                 @db.execute(
                   'SELECT * FROM codebase_snapshots ORDER BY extracted_at DESC LIMIT ?',
                   [limit]
                 )
               end

        rows.map { |row| row_to_hash(row) }
      end

      # Find a specific snapshot by git SHA.
      #
      # @param git_sha [String]
      # @return [Hash, nil] Snapshot metadata or nil if not found
      def find(git_sha)
        row = @db.get_first_row('SELECT * FROM codebase_snapshots WHERE git_sha = ?', [git_sha])
        return nil unless row

        row_to_hash(row)
      end

      # Compute diff between two snapshots.
      #
      # @param sha_a [String] Before snapshot git SHA
      # @param sha_b [String] After snapshot git SHA
      # @return [Hash] {added: [...], modified: [...], deleted: [...]}
      def diff(sha_a, sha_b)
        id_a = fetch_snapshot_id(sha_a)
        id_b = fetch_snapshot_id(sha_b)

        return { added: [], modified: [], deleted: [] } unless id_a && id_b

        units_a = load_snapshot_units(id_a)
        units_b = load_snapshot_units(id_b)

        compute_diff(units_a, units_b)
      end

      # History of a single unit across snapshots.
      #
      # @param identifier [String] Unit identifier
      # @param limit [Integer] Max snapshots to return (default 20)
      # @return [Array<Hash>] Entries with git_sha, extracted_at, source_hash, changed flag
      def unit_history(identifier, limit: 20)
        rows = @db.execute(<<~SQL, [identifier, limit])
          SELECT su.source_hash, su.metadata_hash, su.dependencies_hash, su.unit_type,
                 s.git_sha, s.extracted_at, s.git_branch
          FROM codebase_snapshot_units su
          JOIN codebase_snapshots s ON s.id = su.snapshot_id
          WHERE su.identifier = ?
          ORDER BY s.extracted_at DESC
          LIMIT ?
        SQL

        entries = rows.map { |row| history_entry_from_row(row) }
        mark_changed_entries(entries)
      end

      private

      # Build a history entry hash from a database row.
      #
      # @param row [Hash]
      # @return [Hash]
      def history_entry_from_row(row)
        {
          git_sha: row['git_sha'],
          extracted_at: row['extracted_at'],
          git_branch: row['git_branch'],
          unit_type: row['unit_type'],
          source_hash: row['source_hash'],
          metadata_hash: row['metadata_hash'],
          dependencies_hash: row['dependencies_hash']
        }
      end

      # Mark changed flag on history entries by comparing source hashes.
      #
      # @param entries [Array<Hash>]
      # @return [Array<Hash>]
      def mark_changed_entries(entries)
        entries.each_with_index do |entry, i|
          entry[:changed] = if i == entries.size - 1
                              true # Oldest version is always "changed" (first appearance)
                            else
                              entry[:source_hash] != entries[i + 1][:source_hash]
                            end
        end
        entries
      end

      # Get a value from a hash that may have string or symbol keys.
      #
      # @param hash [Hash]
      # @param key [String]
      # @return [Object, nil]
      def mget(hash, key)
        hash[key] || hash[key.to_sym]
      end

      # Insert or replace the snapshot row from manifest data.
      #
      # @param manifest [Hash]
      # @param git_sha [String]
      # @param default_total [Integer]
      # @return [void]
      def upsert_snapshot(manifest, git_sha, default_total)
        params = [
          git_sha,
          mget(manifest, 'git_branch'),
          mget(manifest, 'extracted_at') || Time.now.iso8601,
          mget(manifest, 'rails_version'),
          mget(manifest, 'ruby_version'),
          mget(manifest, 'total_units') || default_total,
          JSON.generate(mget(manifest, 'counts') || {}),
          mget(manifest, 'gemfile_lock_sha'),
          mget(manifest, 'schema_sha')
        ]
        @db.execute(<<~SQL, params)
          INSERT OR REPLACE INTO codebase_snapshots
            (git_sha, git_branch, extracted_at, rails_version, ruby_version,
             total_units, unit_counts, gemfile_lock_sha, schema_sha)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end

      # Update a snapshot's diff stats vs. a previous snapshot.
      #
      # @param snapshot_id [Integer]
      # @param previous [Hash, nil]
      # @return [void]
      def update_diff_stats(snapshot_id, previous)
        diff_stats = compute_diff_stats(snapshot_id, previous)
        @db.execute(
          'UPDATE codebase_snapshots SET units_added = ?, units_modified = ?, units_deleted = ? WHERE id = ?',
          [diff_stats[:added], diff_stats[:modified], diff_stats[:deleted], snapshot_id]
        )
      end

      # Find the most recent snapshot.
      #
      # @return [Hash, nil]
      def find_latest
        row = @db.get_first_row('SELECT * FROM codebase_snapshots ORDER BY extracted_at DESC LIMIT 1')
        return nil unless row

        row_to_hash(row)
      end

      # Fetch a snapshot's ID by git SHA.
      #
      # @param git_sha [String]
      # @return [Integer, nil]
      def fetch_snapshot_id(git_sha)
        @db.get_first_value('SELECT id FROM codebase_snapshots WHERE git_sha = ?', [git_sha])
      end

      # Insert per-unit hash records for a snapshot.
      #
      # @param snapshot_id [Integer]
      # @param unit_hashes [Array<Hash>]
      # @return [void]
      def insert_unit_hashes(snapshot_id, unit_hashes)
        sql = <<~SQL
          INSERT INTO codebase_snapshot_units
            (snapshot_id, identifier, unit_type, source_hash, metadata_hash, dependencies_hash)
          VALUES (?, ?, ?, ?, ?, ?)
        SQL

        unit_hashes.each do |uh|
          params = [
            snapshot_id,
            uh[:identifier] || uh['identifier'],
            (uh[:type] || uh['type']).to_s,
            uh[:source_hash] || uh['source_hash'],
            uh[:metadata_hash] || uh['metadata_hash'],
            uh[:dependencies_hash] || uh['dependencies_hash']
          ]
          @db.execute(sql, params)
        end
      end

      # Load all unit records for a snapshot as a hash keyed by identifier.
      #
      # @param snapshot_id [Integer]
      # @return [Hash{String => Hash}]
      def load_snapshot_units(snapshot_id)
        sql = <<~SQL
          SELECT identifier, unit_type, source_hash, metadata_hash, dependencies_hash
          FROM codebase_snapshot_units WHERE snapshot_id = ?
        SQL
        rows = @db.execute(sql, [snapshot_id])

        rows.each_with_object({}) do |row, hash|
          hash[row['identifier']] = {
            unit_type: row['unit_type'],
            source_hash: row['source_hash'],
            metadata_hash: row['metadata_hash'],
            dependencies_hash: row['dependencies_hash']
          }
        end
      end

      # Compute diff between two sets of unit hashes.
      #
      # @param units_a [Hash{String => Hash}] Before
      # @param units_b [Hash{String => Hash}] After
      # @return [Hash] {added: [...], modified: [...], deleted: [...]}
      def compute_diff(units_a, units_b) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        added = []
        modified = []
        deleted = []

        # Units in B but not A → added
        # Units in both → check for modifications
        units_b.each do |identifier, data_b|
          if units_a.key?(identifier)
            data_a = units_a[identifier]
            if data_a[:source_hash] != data_b[:source_hash] ||
               data_a[:metadata_hash] != data_b[:metadata_hash] ||
               data_a[:dependencies_hash] != data_b[:dependencies_hash]
              modified << { identifier: identifier, unit_type: data_b[:unit_type] }
            end
          else
            added << { identifier: identifier, unit_type: data_b[:unit_type] }
          end
        end

        # Units in A but not B → deleted
        units_a.each do |identifier, data_a|
          deleted << { identifier: identifier, unit_type: data_a[:unit_type] } unless units_b.key?(identifier)
        end

        { added: added, modified: modified, deleted: deleted }
      end

      # Compute aggregate diff stats.
      #
      # @param current_snapshot_id [Integer]
      # @param previous_snapshot [Hash, nil]
      # @return [Hash] {added:, modified:, deleted:}
      def compute_diff_stats(current_snapshot_id, previous_snapshot)
        return { added: 0, modified: 0, deleted: 0 } unless previous_snapshot

        prev_id = fetch_snapshot_id(previous_snapshot[:git_sha])
        return { added: 0, modified: 0, deleted: 0 } unless prev_id

        units_prev = load_snapshot_units(prev_id)
        units_curr = load_snapshot_units(current_snapshot_id)

        result = compute_diff(units_prev, units_curr)
        { added: result[:added].size, modified: result[:modified].size, deleted: result[:deleted].size }
      end

      # Convert a database row to a normalized hash.
      #
      # @param row [Hash] SQLite3 result row
      # @return [Hash]
      def row_to_hash(row)
        {
          id: row['id'],
          git_sha: row['git_sha'],
          git_branch: row['git_branch'],
          extracted_at: row['extracted_at'],
          rails_version: row['rails_version'],
          ruby_version: row['ruby_version'],
          total_units: row['total_units'],
          unit_counts: row['unit_counts'] ? JSON.parse(row['unit_counts']) : {},
          gemfile_lock_sha: row['gemfile_lock_sha'],
          schema_sha: row['schema_sha'],
          units_added: row['units_added'],
          units_modified: row['units_modified'],
          units_deleted: row['units_deleted']
        }
      end
    end
  end
end
