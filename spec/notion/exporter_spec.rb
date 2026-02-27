# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'codebase_index/notion/exporter'

RSpec.describe CodebaseIndex::Notion::Exporter do
  subject(:exporter) { described_class.new(index_dir: index_dir, config: config, client: client, reader: reader) }

  let(:index_dir) { '/tmp/test_codebase_index' }
  let(:client) { instance_double(CodebaseIndex::Notion::Client) }
  let(:config) do
    double(
      'Configuration',
      notion_api_token: 'secret_test_token',
      notion_database_ids: {
        data_models: 'db-models-uuid',
        columns: 'db-columns-uuid'
      }
    )
  end

  let(:model_units) do
    [
      {
        'identifier' => 'User',
        'type' => 'model',
        'file_path' => 'app/models/user.rb',
        'source_code' => "class User < ApplicationRecord\nend",
        'metadata' => {
          'table_name' => 'users',
          'columns' => [
            { 'name' => 'id', 'type' => 'bigint', 'null' => false },
            { 'name' => 'email', 'type' => 'string', 'null' => false }
          ],
          'column_count' => 2,
          'associations' => [],
          'validations' => [{ 'attribute' => 'email', 'type' => 'presence' }],
          'callbacks' => [],
          'scopes' => []
        },
        'dependencies' => []
      },
      {
        'identifier' => 'Post',
        'type' => 'model',
        'file_path' => 'app/models/post.rb',
        'source_code' => "class Post < ApplicationRecord\nend",
        'metadata' => {
          'table_name' => 'posts',
          'columns' => [
            { 'name' => 'id', 'type' => 'bigint', 'null' => false }
          ],
          'column_count' => 1,
          'associations' => [],
          'validations' => [],
          'callbacks' => [],
          'scopes' => []
        },
        'dependencies' => []
      }
    ]
  end

  let(:migration_units) do
    [
      {
        'identifier' => '20260101_CreateUsers',
        'metadata' => { 'tables_affected' => ['users'] },
        'extracted_at' => '2026-01-01T12:00:00Z'
      }
    ]
  end

  let(:reader) do
    r = double('IndexReader')
    allow(r).to receive(:list_units).with(type: 'model').and_return(
      model_units.map { |u| { 'identifier' => u['identifier'] } }
    )
    allow(r).to receive(:list_units).with(type: 'migration').and_return(
      migration_units.map { |u| { 'identifier' => u['identifier'] } }
    )
    allow(r).to receive(:find_unit) do |identifier|
      (model_units + migration_units).find { |u| u['identifier'] == identifier }
    end
    r
  end

  before do
    # Default: no existing pages in Notion
    allow(client).to receive(:find_page_by_title).and_return(nil)
    allow(client).to receive(:create_page).and_return({ 'id' => "page-#{SecureRandom.hex(4)}" })
    allow(client).to receive(:update_page).and_return({ 'id' => 'page-updated' })
  end

  describe '#initialize' do
    it 'raises ConfigurationError when notion_api_token is missing' do
      bad_config = double('Configuration', notion_api_token: nil, notion_database_ids: {})
      expect do
        described_class.new(index_dir: index_dir, config: bad_config, reader: reader)
      end.to raise_error(CodebaseIndex::ConfigurationError, /notion_api_token/)
    end

    it 'succeeds with valid config' do
      expect(exporter).to be_a(described_class)
    end
  end

  describe '#sync_all' do
    it 'syncs data models and columns' do
      stats = exporter.sync_all
      expect(stats[:data_models]).to eq(2)
      expect(stats[:errors]).to be_empty
    end

    it 'creates Data Models pages for each model' do
      exporter.sync_all
      expect(client).to have_received(:create_page).at_least(:twice)
    end

    it 'syncs columns for all models' do
      stats = exporter.sync_all
      # User has 2 columns, Post has 1 = 3 column pages
      expect(stats[:columns]).to eq(3)
    end

    it 'skips columns sync when database ID not configured' do
      no_columns_config = double(
        'Configuration',
        notion_api_token: 'secret_test',
        notion_database_ids: { data_models: 'db-models-uuid' }
      )
      exporter_no_cols = described_class.new(
        index_dir: index_dir, config: no_columns_config, client: client, reader: reader
      )
      stats = exporter_no_cols.sync_all
      expect(stats[:columns]).to eq(0)
    end

    it 'skips data_models sync when database ID not configured' do
      no_models_config = double(
        'Configuration',
        notion_api_token: 'secret_test',
        notion_database_ids: { columns: 'db-columns-uuid' }
      )
      exporter_no_models = described_class.new(
        index_dir: index_dir, config: no_models_config, client: client, reader: reader
      )
      stats = exporter_no_models.sync_all
      expect(stats[:data_models]).to eq(0)
    end
  end

  describe '#sync_data_models' do
    it 'creates pages for models not found in Notion' do
      stats = exporter.sync_data_models
      expect(stats[:synced]).to eq(2)
      expect(client).to have_received(:create_page)
        .with(hash_including(database_id: 'db-models-uuid'))
        .twice
    end

    it 'updates pages for models already in Notion' do
      allow(client).to receive(:find_page_by_title)
        .with(database_id: 'db-models-uuid', title: 'users')
        .and_return({ 'id' => 'existing-page-123' })

      stats = exporter.sync_data_models
      expect(stats[:synced]).to eq(2)
      expect(client).to have_received(:update_page)
        .with(hash_including(page_id: 'existing-page-123'))
    end

    it 'collects errors without stopping' do
      allow(client).to receive(:find_page_by_title).and_raise(StandardError, 'API failure')
      stats = exporter.sync_data_models
      expect(stats[:errors]).to have_attributes(size: 2)
      expect(stats[:errors].first).to include('User')
    end

    it 'enriches models with migration dates' do
      created_properties = []
      allow(client).to receive(:create_page) do |args|
        created_properties << args[:properties]
        { 'id' => "page-#{SecureRandom.hex(4)}" }
      end

      exporter.sync_data_models

      users_props = created_properties.find do |p|
        p['Table Name'] == { title: [{ text: { content: 'users' } }] }
      end
      expect(users_props).to have_key('Last Schema Change')
      expect(users_props['Last Schema Change']).to eq({ date: { start: '2026-01-01T12:00:00Z' } })
    end
  end

  describe '#sync_columns' do
    before do
      # Sync models first to populate page_id_cache
      allow(client).to receive(:create_page).and_return(
        { 'id' => 'page-user-model' },
        { 'id' => 'page-post-model' },
        # Column creates:
        { 'id' => 'page-col-1' },
        { 'id' => 'page-col-2' },
        { 'id' => 'page-col-3' }
      )
      exporter.sync_data_models
    end

    it 'creates column pages with Table relations' do
      stats = exporter.sync_columns

      expect(stats[:synced]).to eq(3) # User: 2 columns, Post: 1 column
      expect(client).to have_received(:create_page)
        .with(hash_including(database_id: 'db-columns-uuid'))
        .at_least(3).times
    end

    it 'collects errors without stopping' do
      call_count = 0
      allow(client).to receive(:find_page_by_title) do
        call_count += 1
        raise StandardError, 'Column sync fail' if call_count == 1

        nil
      end

      stats = exporter.sync_columns
      expect(stats[:errors].size).to be >= 1
    end
  end
end
