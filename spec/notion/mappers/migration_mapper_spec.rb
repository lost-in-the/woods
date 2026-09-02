# frozen_string_literal: true

require 'spec_helper'
require 'woods/notion/mappers/migration_mapper'

RSpec.describe Woods::Notion::Mappers::MigrationMapper do
  subject(:mapper) { described_class.new }

  # EXP-3. These fixtures used to set extracted_at equal to the migration's
  # own timestamp, so "picks the latest extracted_at" read as correct while
  # asserting the wrong field. A full extraction re-stamps extracted_at for
  # every unit, which made every table read "changed today"; the migration
  # version — sitting unused in the same metadata hash — is the real date.
  let(:extraction_run_at) { '2026-09-01T00:00:00Z' }

  let(:migration_units) do
    [
      {
        'identifier' => '20260101120000_CreateUsers',
        'metadata' => {
          'tables_affected' => %w[users],
          'migration_version' => '20260101120000'
        },
        'extracted_at' => extraction_run_at
      },
      {
        'identifier' => '20260215090000_AddEmailIndexToUsers',
        'metadata' => {
          'tables_affected' => %w[users],
          'migration_version' => '20260215090000'
        },
        'extracted_at' => extraction_run_at
      },
      {
        'identifier' => '20260110080000_CreatePosts',
        'metadata' => {
          'tables_affected' => %w[posts],
          'migration_version' => '20260110080000'
        },
        'extracted_at' => extraction_run_at
      },
      {
        'identifier' => '20260220100000_AddUserIdToPosts',
        'metadata' => {
          'tables_affected' => %w[posts users],
          'migration_version' => '20260220100000'
        },
        'extracted_at' => extraction_run_at
      }
    ]
  end

  describe '#latest_changes' do
    it 'returns latest migration date per table' do
      result = mapper.latest_changes(migration_units)
      expect(result['users']).to eq('2026-02-20T10:00:00Z')
      expect(result['posts']).to eq('2026-02-20T10:00:00Z')
    end

    it 'picks the latest migration version for each table' do
      result = mapper.latest_changes(migration_units)
      # users: affected by migrations 20260101120000, 20260215090000, 20260220100000
      expect(result['users']).to eq('2026-02-20T10:00:00Z')
      expect(result['users']).not_to eq(extraction_run_at)
    end

    it 'falls back to extracted_at when the migration version is absent' do
      units = [
        { 'identifier' => 'LegacyMigration',
          'metadata' => { 'tables_affected' => ['orders'] },
          'extracted_at' => extraction_run_at }
      ]

      expect(mapper.latest_changes(units)['orders']).to eq(extraction_run_at)
    end

    it 'falls back to extracted_at when the migration version does not parse' do
      units = [
        { 'identifier' => 'OddMigration',
          'metadata' => { 'tables_affected' => ['orders'], 'migration_version' => 'not-a-stamp' },
          'extracted_at' => extraction_run_at }
      ]

      expect(mapper.latest_changes(units)['orders']).to eq(extraction_run_at)
    end

    it 'uses the migration version even when the unit has no extracted_at' do
      units = [
        { 'identifier' => '20200101000000_CreateOrders',
          'metadata' => { 'tables_affected' => ['orders'], 'migration_version' => '20200101000000' } }
      ]

      expect(mapper.latest_changes(units)['orders']).to eq('2020-01-01T00:00:00Z')
    end

    it 'returns empty hash for empty input' do
      result = mapper.latest_changes([])
      expect(result).to eq({})
    end

    it 'handles migrations with no tables_affected' do
      units = [
        { 'identifier' => 'SomeMigration', 'metadata' => {}, 'extracted_at' => '2026-01-01T00:00:00Z' }
      ]
      result = mapper.latest_changes(units)
      expect(result).to eq({})
    end

    it 'handles nil metadata' do
      units = [
        { 'identifier' => 'SomeMigration', 'metadata' => nil, 'extracted_at' => '2026-01-01T00:00:00Z' }
      ]
      result = mapper.latest_changes(units)
      expect(result).to eq({})
    end
  end
end
