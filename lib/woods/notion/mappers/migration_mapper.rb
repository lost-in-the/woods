# frozen_string_literal: true

module CodebaseIndex
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
        # Compute the latest migration date for each affected table.
        #
        # @param migration_units [Array<Hash>] Parsed migration ExtractedUnit JSONs
        # @return [Hash<String, String>] Table name to latest extracted_at timestamp
        def latest_changes(migration_units)
          migration_units.each_with_object({}) do |unit, changes|
            extracted_at = unit['extracted_at']
            next unless extracted_at

            tables = (unit['metadata'] || {})['tables_affected'] || []
            tables.each { |table| update_latest(changes, table, extracted_at) }
          end
        end

        private

        # @return [void]
        def update_latest(changes, table, extracted_at)
          changes[table] = extracted_at if changes[table].nil? || extracted_at > changes[table]
        end
      end
    end
  end
end
