# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'woods/notion/exporter'

RSpec.describe Woods::Notion::Exporter do
  subject(:exporter) { described_class.new(index_dir: index_dir, config: config, client: client, reader: reader) }

  let(:index_dir) { '/tmp/test_woods' }
  let(:client) { instance_double(Woods::Notion::Client) }
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
    # Default: no existing pages in Notion (and no legacy pages either)
    allow(client).to receive(:find_page_by_title).and_return(nil)
    allow(client).to receive(:query_database).and_return({ 'results' => [] })
    allow(client).to receive(:create_page).and_return({ 'id' => "page-#{SecureRandom.hex(4)}" })
    allow(client).to receive(:update_page).and_return({ 'id' => 'page-updated' })
  end

  describe '#initialize' do
    it 'raises ConfigurationError when notion_api_token is missing' do
      # Ensure no ambient ENV token satisfies the (new) ENV-override path.
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('NOTION_API_TOKEN', nil).and_return(nil)
      bad_config = double('Configuration', notion_api_token: nil, notion_database_ids: {})
      expect do
        described_class.new(index_dir: index_dir, config: bad_config, reader: reader)
      end.to raise_error(Woods::ConfigurationError, /notion_api_token/)
    end

    it 'succeeds with valid config' do
      expect(exporter).to be_a(described_class)
    end

    it 'accepts the NOTION_API_TOKEN env var when config has no token' do
      # Documented override: an ENV-only host must construct successfully,
      # matching what the MCP notion_wired? gate promises.
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('NOTION_API_TOKEN', nil).and_return('secret_env_token')
      env_config = double('Configuration', notion_api_token: nil, notion_database_ids: { 'data_models' => 'db1' })

      expect do
        described_class.new(index_dir: index_dir, config: env_config, reader: reader)
      end.not_to raise_error
    end

    it 'treats a blank NOTION_API_TOKEN env var as absent, using the configured token' do
      # A set-but-empty env var (docker-compose ${VAR} of an unset host var)
      # must not mask a valid configured token nor pass through as a blank
      # bearer that only fails later with 401s.
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('NOTION_API_TOKEN', nil).and_return('')
      built = nil

      expect do
        built = described_class.new(index_dir: index_dir, config: config, reader: reader)
      end.not_to raise_error
      expect(built).to be_a(described_class)
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

  describe 'title qualification and collision safety (#149 / B-060)' do
    # These examples drive the client against an in-memory page registry
    # instead of blanket find_page_by_title(nil) stubs, so title collisions
    # actually collide: a lookup finds whatever an earlier upsert stored,
    # exactly like the real Columns database does.
    let(:registry) { {} }

    before do
      allow(client).to receive(:create_page) do |database_id:, properties:|
        id = "page-#{registry.size + 1}"
        registry[id] = { 'id' => id, db: database_id, properties: properties }
        { 'id' => id }
      end
      allow(client).to receive(:update_page) do |page_id:, properties:|
        registry.fetch(page_id)[:properties] = registry.fetch(page_id)[:properties].merge(properties)
        { 'id' => page_id }
      end
      allow(client).to receive(:find_page_by_title) do |database_id:, title:|
        pages_titled(database_id, title).first
      end
      allow(client).to receive(:query_database) do |database_id:, filter:|
        { 'results' => apply_filter(database_id, filter) }
      end
    end

    def seed_page(id, database_id, properties)
      registry[id] = { 'id' => id, db: database_id, properties: properties }
    end

    def page_title(page)
      title_prop = page[:properties].values.find { |v| v.is_a?(Hash) && v.key?(:title) }
      title_prop&.dig(:title, 0, :text, :content)
    end

    def pages_titled(database_id, title)
      registry.values.select { |page| page[:db] == database_id && page_title(page) == title }
    end

    def pages_in(database_id)
      registry.values.select { |page| page[:db] == database_id }
    end

    # Interpret the two filter shapes the exporter produces: bare title
    # equality, or title equality AND-ed with a `relation contains` clause.
    def apply_filter(database_id, filter)
      clauses = filter[:and] || [filter]
      title_clause = clauses.find { |clause| clause[:title] }
      relation_clause = clauses.find { |clause| clause[:relation] }
      results = pages_titled(database_id, title_clause[:title][:equals])
      return results unless relation_clause

      results.select { |page| page_related_to?(page, relation_clause) }
    end

    def page_related_to?(page, relation_clause)
      related = page[:properties].dig(relation_clause[:property], :relation) || []
      related.any? { |ref| ref[:id] == relation_clause[:relation][:contains] }
    end

    context 'when two models share a column name' do
      let(:model_units) do
        [
          {
            'identifier' => 'User', 'type' => 'model', 'file_path' => 'app/models/user.rb',
            'source_code' => "class User < ApplicationRecord\nend",
            'metadata' => {
              'table_name' => 'users',
              'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false }],
              'column_count' => 1, 'associations' => [], 'validations' => [], 'callbacks' => [], 'scopes' => []
            },
            'dependencies' => []
          },
          {
            'identifier' => 'Order', 'type' => 'model', 'file_path' => 'app/models/order.rb',
            'source_code' => "class Order < ApplicationRecord\nend",
            'metadata' => {
              'table_name' => 'orders',
              'columns' => [{ 'name' => 'id', 'type' => 'uuid', 'null' => false }],
              'column_count' => 1, 'associations' => [], 'validations' => [], 'callbacks' => [], 'scopes' => []
            },
            'dependencies' => []
          }
        ]
      end

      let(:migration_units) { [] }

      it 'keeps one column page per model instead of collapsing on the shared name' do
        exporter.sync_all

        titles = pages_in('db-columns-uuid').map { |page| page_title(page) }
        expect(titles).to contain_exactly('users.id', 'orders.id')
      end

      it 'preserves each column page own attributes' do
        exporter.sync_all

        users_id = pages_titled('db-columns-uuid', 'users.id').first
        orders_id = pages_titled('db-columns-uuid', 'orders.id').first
        expect(users_id[:properties]['Data Type']).to eq({ select: { name: 'bigint' } })
        expect(orders_id[:properties]['Data Type']).to eq({ select: { name: 'uuid' } })
      end

      it 'links each column page to its own Data Models page' do
        exporter.sync_all

        users_model = pages_titled('db-models-uuid', 'users').first
        orders_model = pages_titled('db-models-uuid', 'orders').first
        users_id = pages_titled('db-columns-uuid', 'users.id').first
        orders_id = pages_titled('db-columns-uuid', 'orders.id').first
        expect(users_id[:properties]['Table']).to eq({ relation: [{ id: users_model['id'] }] })
        expect(orders_id[:properties]['Table']).to eq({ relation: [{ id: orders_model['id'] }] })
      end

      it 'stays idempotent across a second sync' do
        exporter.sync_all
        expect { exporter.sync_all }.not_to(change { registry.keys.sort })
      end

      context 'with a legacy bare-title column page from a pre-qualification sync' do
        before do
          seed_page('legacy-users-model', 'db-models-uuid',
                    'Table Name' => { title: [{ text: { content: 'users' } }] })
          # The corrupt survivor of the old keying: bare "id" title, relation
          # pointing at whichever model synced last (here: users), properties
          # overwritten by that model.
          seed_page('legacy-id-col', 'db-columns-uuid',
                    'Column Name' => { title: [{ text: { content: 'id' } }] },
                    'Data Type' => { select: { name: 'string' } },
                    'Table' => { relation: [{ id: 'legacy-users-model' }] })
        end

        it 'adopts the legacy page whose Table relation matches instead of duplicating it' do
          exporter.sync_all

          users_id = pages_titled('db-columns-uuid', 'users.id')
          expect(users_id.map { |page| page['id'] }).to eq(['legacy-id-col'])
        end

        it 'retitles and rewrites the adopted page' do
          exporter.sync_all

          adopted = registry.fetch('legacy-id-col')
          expect(page_title(adopted)).to eq('users.id')
          expect(adopted[:properties]['Data Type']).to eq({ select: { name: 'bigint' } })
        end

        it 'creates a fresh qualified page for the model the legacy relation does not match' do
          exporter.sync_all

          expect(pages_titled('db-columns-uuid', 'orders.id').size).to eq(1)
          expect(pages_titled('db-columns-uuid', 'id')).to be_empty
          expect(pages_in('db-columns-uuid').size).to eq(2)
        end

        it 'logs the adoption' do
          expect { exporter.sync_all }.to output(/adopting legacy page legacy-id-col/).to_stderr
        end
      end
    end

    context 'when STI models share a table name' do
      let(:sti_metadata) do
        {
          'table_name' => 'users',
          'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false }],
          'column_count' => 1, 'associations' => [], 'validations' => [], 'callbacks' => [], 'scopes' => []
        }
      end

      let(:model_units) do
        [
          {
            'identifier' => 'User', 'type' => 'model', 'file_path' => 'app/models/user.rb',
            'source_code' => "class User < ApplicationRecord\nend",
            'metadata' => sti_metadata, 'dependencies' => []
          },
          {
            'identifier' => 'Admin', 'type' => 'model', 'file_path' => 'app/models/admin.rb',
            'source_code' => "class Admin < User\nend",
            'metadata' => sti_metadata, 'dependencies' => []
          }
        ]
      end

      it 'keeps one Data Models page per model, qualified by class name' do
        exporter.sync_data_models

        titles = pages_in('db-models-uuid').map { |page| page_title(page) }
        expect(titles).to contain_exactly('users (User)', 'users (Admin)')
      end

      it 'records each model own name on its page' do
        exporter.sync_data_models

        user_page = pages_titled('db-models-uuid', 'users (User)').first
        admin_page = pages_titled('db-models-uuid', 'users (Admin)').first
        expect(user_page[:properties]['Model Name'][:rich_text].first[:text][:content]).to eq('User')
        expect(admin_page[:properties]['Model Name'][:rich_text].first[:text][:content]).to eq('Admin')
      end

      it 'still enriches qualified pages with migration dates keyed on the bare table name' do
        exporter.sync_data_models

        user_page = pages_titled('db-models-uuid', 'users (User)').first
        expect(user_page[:properties]['Last Schema Change']).to eq({ date: { start: '2026-01-01T12:00:00Z' } })
      end

      it 'collapses their identical physical columns onto one page' do
        exporter.sync_all

        expect(pages_in('db-columns-uuid').map { |page| page_title(page) }).to eq(['users.id'])
      end

      context 'with a legacy bare-title Data Models page' do
        before do
          seed_page('legacy-users-model', 'db-models-uuid',
                    'Table Name' => { title: [{ text: { content: 'users' } }] })
        end

        it 'adopts the single legacy page for the first model and creates the rest' do
          exporter.sync_data_models

          expect(pages_titled('db-models-uuid', 'users (User)').map { |page| page['id'] })
            .to eq(['legacy-users-model'])
          expect(pages_titled('db-models-uuid', 'users (Admin)').size).to eq(1)
          expect(pages_in('db-models-uuid').size).to eq(2)
        end
      end

      context 'with several ambiguous legacy pages and no relation to tell them apart' do
        before do
          seed_page('legacy-users-1', 'db-models-uuid',
                    'Table Name' => { title: [{ text: { content: 'users' } }] })
          seed_page('legacy-users-2', 'db-models-uuid',
                    'Table Name' => { title: [{ text: { content: 'users' } }] })
        end

        it 'creates fresh qualified pages rather than guessing, and warns' do
          expect { exporter.sync_data_models }.to output(/legacy title "users"/).to_stderr

          expect(pages_titled('db-models-uuid', 'users (User)').size).to eq(1)
          expect(pages_titled('db-models-uuid', 'users (Admin)').size).to eq(1)
          expect(pages_titled('db-models-uuid', 'users').size).to eq(2)
        end
      end
    end
  end
end
