# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/notion/mappers/migration_mapper'

RSpec.describe CodebaseIndex::Notion::Mappers::MigrationMapper do
  subject(:mapper) { described_class.new }

  let(:migration_units) do
    [
      {
        'identifier' => '20260101120000_CreateUsers',
        'metadata' => {
          'tables_affected' => %w[users],
          'migration_version' => '20260101120000'
        },
        'extracted_at' => '2026-01-01T12:00:00Z'
      },
      {
        'identifier' => '20260215090000_AddEmailIndexToUsers',
        'metadata' => {
          'tables_affected' => %w[users],
          'migration_version' => '20260215090000'
        },
        'extracted_at' => '2026-02-15T09:00:00Z'
      },
      {
        'identifier' => '20260110080000_CreatePosts',
        'metadata' => {
          'tables_affected' => %w[posts],
          'migration_version' => '20260110080000'
        },
        'extracted_at' => '2026-01-10T08:00:00Z'
      },
      {
        'identifier' => '20260220100000_AddUserIdToPosts',
        'metadata' => {
          'tables_affected' => %w[posts users],
          'migration_version' => '20260220100000'
        },
        'extracted_at' => '2026-02-20T10:00:00Z'
      }
    ]
  end

  describe '#latest_changes' do
    it 'returns latest migration date per table' do
      result = mapper.latest_changes(migration_units)
      expect(result['users']).to eq('2026-02-20T10:00:00Z')
      expect(result['posts']).to eq('2026-02-20T10:00:00Z')
    end

    it 'picks the latest extracted_at for each table' do
      result = mapper.latest_changes(migration_units)
      # users: affected by migration at 2026-01-01, 2026-02-15, 2026-02-20 → latest is 2026-02-20
      expect(result['users']).to eq('2026-02-20T10:00:00Z')
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
