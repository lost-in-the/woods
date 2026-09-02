# frozen_string_literal: true

require 'time'

module Woods
  module Notion
    module Mappers
      # Extracts latest migration dates per table from migration ExtractedUnits.
      #
      # Used to update Data Models pages with the most recent schema change date.
      #
      # @example
      #   mapper = MigrationMapper.new
      #   changes = mapper.latest_changes(migration_units)
      #   # => { "users" => "2026-02-20T10:00:00Z", "posts" => "2026-01-15T09:00:00Z" }
      #
      class MigrationMapper
        # A migration filename stamp: 20260220100000.
        VERSION_STAMP = /\A(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\z/

        # Compute the latest schema-change date for each affected table.
        #
        # The date is the **migration's own** version stamp, not the unit's
        # +extracted_at+ (EXP-3). `extracted_at` records when Woods ran, so a
        # full extraction re-stamped every unit and made every table read
        # "changed today" — and rewrote every Data Models page to say so.
        # Units with no parseable version fall back to `extracted_at`.
        #
        # @param migration_units [Array<Hash>] Parsed migration ExtractedUnit JSONs
        # @return [Hash<String, String>] Table name to latest ISO8601 timestamp
        def latest_changes(migration_units)
          migration_units.each_with_object({}) do |unit, changes|
            metadata = unit['metadata'] || {}
            changed_at = version_timestamp(metadata['migration_version']) || unit['extracted_at']
            next unless changed_at

            tables = metadata['tables_affected'] || []
            tables.each { |table| update_latest(changes, table, changed_at) }
          end
        end

        private

        # @param version [String, nil] a `%Y%m%d%H%M%S` migration stamp
        # @return [String, nil] ISO8601 UTC, or nil when absent/unparseable
        def version_timestamp(version)
          match = VERSION_STAMP.match(version.to_s)
          return nil unless match

          Time.utc(*match.captures.map(&:to_i)).iso8601
        rescue ArgumentError
          # A well-shaped stamp naming an impossible date (month 13).
          nil
        end

        # @return [void]
        def update_latest(changes, table, changed_at)
          changes[table] = changed_at if changes[table].nil? || changed_at > changes[table]
        end
      end
    end
  end
end
