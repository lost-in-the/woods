# frozen_string_literal: true

require 'json'
require 'time'

module Woods
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
      # @param validate_schema [Boolean] If true (default), probe both required
      #   tables at construction time and raise a descriptive error pointing at
      #   migrations 004+005 when they are missing. Set false in tests that
      #   construct the store with a bare mock.
      def initialize(connection:, validate_schema: true)
        @db = connection
        @db.busy_timeout = 5_000 if @db.respond_to?(:busy_timeout=)
        validate_schema! if validate_schema
      end

      REQUIRED_TABLES = %w[woods_snapshots woods_snapshot_units].freeze

      # Probe that `woods_snapshots` and `woods_snapshot_units` exist. If
      # they don't, raise with guidance to run migrations 004 + 005 —
      # without this, the first call to {#capture}/{#find} raises a generic
      # adapter error that doesn't tell operators why.
      #
      # When the connection responds to `#columns` (ActiveRecord-shaped) or
      # `#table_exists?`, use that — these are hard to spoof from a test
      # mock, so a partial mock can no longer silently pass. Falls back to
      # the `SELECT 1 FROM t LIMIT 1` probe for minimal connections.
      #
      # @raise [Woods::Error]
      def validate_schema!
        REQUIRED_TABLES.each { |t| probe_table!(t) }
      rescue Woods::Error
        raise
      rescue StandardError => e
        raise Woods::Error, schema_error_message(e)
      end

      private

      def probe_table!(table)
        if @db.respond_to?(:table_exists?)
          raise Woods::Error, schema_error_message("table `#{table}` does not exist") unless @db.table_exists?(table)
        elsif @db.respond_to?(:columns)
          cols = @db.columns(table)
          raise Woods::Error, schema_error_message("no columns for `#{table}`") if cols.nil? || cols.empty?
        else
          @db.execute("SELECT 1 FROM #{table} LIMIT 1")
        end
      end

      def schema_error_message(detail)
        'SnapshotStore requires the `woods_snapshots` and ' \
          '`woods_snapshot_units` tables (migrations 004 + 005 under ' \
          '`lib/woods/db/migrations/`). These run automatically on woods-mcp ' \
          'boot (Bootstrapper.build_snapshot_store auto-migrates), or run them ' \
          'directly with `Woods::Db::Migrator.new(connection: db).migrate!`. ' \
          "Underlying error: #{detail}"
      end

      public

      # Capture a snapshot after extraction completes.
      #
      # Stores the manifest metadata and per-unit content hashes.
      # Computes diff stats vs. the most recent previous snapshot.
      #
      # Re-capturing at an unchanged HEAD updates the snapshot row **in
      # place** — the row id is stable across captures (#206), so the
      # per-unit DELETE below genuinely clears the previous capture's unit
      # set instead of leaking it. Unit rows orphaned by the pre-#206
      # INSERT OR REPLACE (which minted a fresh id per capture) are swept
      # on every capture so historical leaks self-heal.
      #
      # @param manifest [Hash] The manifest data (string or symbol keys)
      # @param unit_hashes [Array<Hash>] Per-unit content hashes
      # @return [Hash] Snapshot record with diff stats
      def capture(manifest, unit_hashes)
        git_sha = mget(manifest, 'git_sha')
        # Snapshots are keyed by commit SHA — skip a missing or non-SHA value
        # (e.g. the "unknown" provenance sentinel, #137) so it can't key or
        # collide a snapshot row. Mirrors JsonSnapshotStore's path validation.
        return nil unless git_sha.is_a?(String) && git_sha.match?(/\A[0-9a-f]+\z/i)

        captured = nil
        with_lock_retry do
          @db.transaction(:immediate) do
            previous = find_latest
            upsert_snapshot(manifest, git_sha, unit_hashes.size)

            snapshot_id = fetch_snapshot_id(git_sha)
            @db.execute('DELETE FROM woods_snapshot_units WHERE snapshot_id = ?', [snapshot_id])
            prune_orphaned_units
            insert_unit_hashes(snapshot_id, unit_hashes)

            update_diff_stats(snapshot_id, previous)
            captured = find(git_sha)
          end
        end
        captured
      end

      # Attempts for {#with_lock_retry}, including the first.
      LOCK_ATTEMPTS = 3

      # SQLite skips the busy handler when it detects a lock-order deadlock
      # (this connection holds SHARED and asks for RESERVED while another
      # already holds RESERVED), so `BEGIN IMMEDIATE` can raise "database is
      # locked" at once despite busy_timeout. Two extractions capturing into
      # one metadata database hit that on CI. A short bounded retry lets the
      # other writer finish; anything else, or a non-SQLite connection,
      # raises straight through.
      def with_lock_retry
        attempt = 0
        begin
          attempt += 1
          yield
        rescue StandardError => e
          raise unless sqlite_busy?(e) && attempt < LOCK_ATTEMPTS

          sleep(0.05 * attempt)
          retry
        end
      end

      def sqlite_busy?(error)
        defined?(SQLite3::BusyException) && error.is_a?(SQLite3::BusyException)
      end

      # List snapshots, optionally filtered by branch.
      #
      # @param limit [Integer] Max results (default 20)
      # @param branch [String, nil] Filter by branch name
      # @return [Array<Hash>] Snapshot summaries sorted by extracted_at descending
      def list(limit: 20, branch: nil)
        rows = if branch
                 @db.execute(
                   'SELECT * FROM woods_snapshots WHERE git_branch = ? ORDER BY extracted_at DESC LIMIT ?',
                   [branch, limit]
                 )
               else
                 @db.execute(
                   'SELECT * FROM woods_snapshots ORDER BY extracted_at DESC LIMIT ?',
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
        row = @db.get_first_row('SELECT * FROM woods_snapshots WHERE git_sha = ?', [git_sha])
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
          FROM woods_snapshot_units su
          JOIN woods_snapshots s ON s.id = su.snapshot_id
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

      # Upsert SQL for the snapshot row, keyed on UNIQUE(git_sha).
      #
      # Deliberately `ON CONFLICT ... DO UPDATE` (SQLite >= 3.24 — the same
      # syntax `Storage::MetadataStore` already relies on), **not**
      # `INSERT OR REPLACE`: REPLACE resolves the conflict by deleting the
      # old row and inserting a fresh one with a new AUTOINCREMENT id, so
      # {#capture}'s subsequent `DELETE ... WHERE snapshot_id = ?` matched
      # nothing and every re-extraction at an unchanged HEAD leaked a full
      # unit-hash set — unboundedly, since foreign keys are never enabled on
      # this connection (#206).
      UPSERT_SNAPSHOT_SQL = <<~SQL
        INSERT INTO woods_snapshots
          (git_sha, git_branch, extracted_at, rails_version, ruby_version,
           total_units, unit_counts, gemfile_lock_sha, schema_sha)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(git_sha) DO UPDATE SET
          git_branch = excluded.git_branch,
          extracted_at = excluded.extracted_at,
          rails_version = excluded.rails_version,
          ruby_version = excluded.ruby_version,
          total_units = excluded.total_units,
          unit_counts = excluded.unit_counts,
          gemfile_lock_sha = excluded.gemfile_lock_sha,
          schema_sha = excluded.schema_sha
      SQL

      private_constant :UPSERT_SNAPSHOT_SQL

      # Insert the snapshot row, or update it in place when this git SHA was
      # captured before. The row id is preserved either way (see
      # {UPSERT_SNAPSHOT_SQL}).
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
        @db.execute(UPSERT_SNAPSHOT_SQL, params)
      end

      # Delete unit rows whose snapshot row no longer exists.
      #
      # Before #206, every re-capture of an unchanged SHA stranded the
      # previous capture's unit rows under a snapshot id REPLACE had deleted
      # (foreign keys are never enabled on this connection, so nothing else
      # cleans them up). One cheap sweep per capture lets databases that
      # accumulated those leaks self-heal.
      #
      # @return [void]
      def prune_orphaned_units
        @db.execute(<<~SQL)
          DELETE FROM woods_snapshot_units
          WHERE snapshot_id NOT IN (SELECT id FROM woods_snapshots)
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
          'UPDATE woods_snapshots SET units_added = ?, units_modified = ?, units_deleted = ? WHERE id = ?',
          [diff_stats[:added], diff_stats[:modified], diff_stats[:deleted], snapshot_id]
        )
      end

      # Find the most recent snapshot.
      #
      # @return [Hash, nil]
      def find_latest
        row = @db.get_first_row('SELECT * FROM woods_snapshots ORDER BY extracted_at DESC LIMIT 1')
        return nil unless row

        row_to_hash(row)
      end

      # Fetch a snapshot's ID by git SHA.
      #
      # @param git_sha [String]
      # @return [Integer, nil]
      def fetch_snapshot_id(git_sha)
        @db.get_first_value('SELECT id FROM woods_snapshots WHERE git_sha = ?', [git_sha])
      end

      # Insert per-unit hash records for a snapshot.
      #
      # @param snapshot_id [Integer]
      # @param unit_hashes [Array<Hash>]
      # @return [void]
      def insert_unit_hashes(snapshot_id, unit_hashes)
        sql = <<~SQL
          INSERT INTO woods_snapshot_units
            (snapshot_id, identifier, unit_type, source_hash, metadata_hash, dependencies_hash)
          VALUES (?, ?, ?, ?, ?, ?)
        SQL

        unit_hashes.each do |uh|
          params = [
            snapshot_id,
            mget(uh, 'identifier'),
            mget(uh, 'type').to_s,
            mget(uh, 'source_hash'),
            mget(uh, 'metadata_hash'),
            mget(uh, 'dependencies_hash')
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
          FROM woods_snapshot_units WHERE snapshot_id = ?
        SQL
        rows = @db.execute(sql, [snapshot_id])

        rows.to_h do |row|
          [row['identifier'], {
            unit_type: row['unit_type'],
            source_hash: row['source_hash'],
            metadata_hash: row['metadata_hash'],
            dependencies_hash: row['dependencies_hash']
          }]
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
