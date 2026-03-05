# frozen_string_literal: true

require 'json'
require 'time'
require 'digest'

module CodebaseIndex
  module Temporal
    # JSON-file-based snapshot store for temporal tracking without SQLite.
    #
    # Stores snapshots as individual JSON files in a `snapshots/` subdirectory
    # of the index output directory. Each file is named by git SHA and contains
    # manifest metadata plus per-unit content hashes.
    #
    # Implements the same public interface as SnapshotStore so the MCP server
    # tools work identically.
    #
    # @example
    #   store = JsonSnapshotStore.new(dir: '/app/tmp/codebase_index')
    #   store.capture(manifest, unit_hashes)
    #   store.list                    # => [{ git_sha: "abc123", ... }]
    #   store.diff("abc123", "def456") # => { added: [...], modified: [...], deleted: [...] }
    #
    class JsonSnapshotStore # rubocop:disable Metrics/ClassLength
      def initialize(dir:)
        @dir = File.join(dir, 'snapshots')
        FileUtils.mkdir_p(@dir)
      end

      def capture(manifest, unit_hashes)
        git_sha = mget(manifest, 'git_sha')
        return nil unless git_sha

        previous = find_latest
        snapshot = build_snapshot(manifest, git_sha, unit_hashes)

        if previous
          diff_result = compute_diff(previous[:units], index_units(unit_hashes))
          snapshot[:units_added] = diff_result[:added].size
          snapshot[:units_modified] = diff_result[:modified].size
          snapshot[:units_deleted] = diff_result[:deleted].size
        end

        write_snapshot(git_sha, snapshot)
        snapshot.except(:units)
      end

      def list(limit: 20, branch: nil)
        snapshots = load_all_summaries
        snapshots.select! { |s| s[:git_branch] == branch } if branch
        snapshots.sort_by { |s| s[:extracted_at] || '' }.reverse.first(limit)
      end

      def find(git_sha)
        path = snapshot_path(git_sha)
        return nil unless File.exist?(path)

        data = JSON.parse(File.read(path))
        symbolize_snapshot(data).except(:units)
      end

      def diff(sha_a, sha_b)
        snap_a = load_snapshot_with_units(sha_a)
        snap_b = load_snapshot_with_units(sha_b)

        return { added: [], modified: [], deleted: [] } unless snap_a && snap_b

        compute_diff(snap_a[:units], snap_b[:units])
      end

      def unit_history(identifier, limit: 20)
        snapshots = load_all_with_units
                    .sort_by { |s| s[:extracted_at] || '' }
                    .reverse
                    .first(limit)

        entries = snapshots.filter_map do |snap|
          unit = snap[:units]&.[](identifier)
          next unless unit

          {
            git_sha: snap[:git_sha],
            extracted_at: snap[:extracted_at],
            git_branch: snap[:git_branch],
            unit_type: unit[:unit_type],
            source_hash: unit[:source_hash],
            metadata_hash: unit[:metadata_hash],
            dependencies_hash: unit[:dependencies_hash]
          }
        end

        mark_changed_entries(entries)
      end

      private

      def mget(hash, key)
        hash[key] || hash[key.to_sym]
      end

      def build_snapshot(manifest, git_sha, unit_hashes)
        {
          git_sha: git_sha,
          git_branch: mget(manifest, 'git_branch'),
          extracted_at: mget(manifest, 'extracted_at') || Time.now.iso8601,
          rails_version: mget(manifest, 'rails_version'),
          ruby_version: mget(manifest, 'ruby_version'),
          total_units: mget(manifest, 'total_units') || unit_hashes.size,
          unit_counts: mget(manifest, 'counts') || {},
          gemfile_lock_sha: mget(manifest, 'gemfile_lock_sha'),
          schema_sha: mget(manifest, 'schema_sha'),
          units_added: 0,
          units_modified: 0,
          units_deleted: 0,
          units: index_units(unit_hashes)
        }
      end

      def index_units(unit_hashes)
        unit_hashes.to_h do |uh|
          id = mget(uh, 'identifier')
          [id, {
            unit_type: mget(uh, 'type').to_s,
            source_hash: mget(uh, 'source_hash'),
            metadata_hash: mget(uh, 'metadata_hash'),
            dependencies_hash: mget(uh, 'dependencies_hash')
          }]
        end
      end

      def compute_diff(units_a, units_b) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        added = []
        modified = []
        deleted = []

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

        units_a.each do |identifier, data_a|
          deleted << { identifier: identifier, unit_type: data_a[:unit_type] } unless units_b.key?(identifier)
        end

        { added: added, modified: modified, deleted: deleted }
      end

      def mark_changed_entries(entries)
        entries.each_with_index do |entry, i|
          entry[:changed] = if i == entries.size - 1
                              true
                            else
                              entry[:source_hash] != entries[i + 1][:source_hash]
                            end
        end
        entries
      end

      def snapshot_path(git_sha)
        File.join(@dir, "#{git_sha}.json")
      end

      def write_snapshot(git_sha, data)
        File.write(snapshot_path(git_sha), JSON.pretty_generate(data))
      end

      def load_snapshot_with_units(git_sha)
        path = snapshot_path(git_sha)
        return nil unless File.exist?(path)

        symbolize_snapshot(JSON.parse(File.read(path)))
      end

      def load_all_summaries
        Dir.glob(File.join(@dir, '*.json')).map do |path|
          data = JSON.parse(File.read(path))
          symbolize_snapshot(data).except(:units)
        end
      end

      def load_all_with_units
        Dir.glob(File.join(@dir, '*.json')).map do |path|
          symbolize_snapshot(JSON.parse(File.read(path)))
        end
      end

      def find_latest
        files = Dir.glob(File.join(@dir, '*.json'))
        return nil if files.empty?

        latest_file = files.max_by { |f| File.mtime(f) }
        symbolize_snapshot(JSON.parse(File.read(latest_file)))
      end

      def symbolize_snapshot(data)
        {
          git_sha: data['git_sha'],
          git_branch: data['git_branch'],
          extracted_at: data['extracted_at'],
          rails_version: data['rails_version'],
          ruby_version: data['ruby_version'],
          total_units: data['total_units'],
          unit_counts: data['unit_counts'] || {},
          gemfile_lock_sha: data['gemfile_lock_sha'],
          schema_sha: data['schema_sha'],
          units_added: data['units_added'],
          units_modified: data['units_modified'],
          units_deleted: data['units_deleted'],
          units: symbolize_units(data['units'])
        }
      end

      def symbolize_units(units)
        return {} unless units

        units.transform_values do |v|
          {
            unit_type: v['unit_type'],
            source_hash: v['source_hash'],
            metadata_hash: v['metadata_hash'],
            dependencies_hash: v['dependencies_hash']
          }
        end
      end
    end
  end
end
