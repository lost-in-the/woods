# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require 'tmpdir'
require 'json'
require 'woods/notion/exporter'

RSpec.describe Woods::Notion::Exporter do
  subject(:exporter) { described_class.new(index_dir: index_dir, config: config, client: client, reader: reader) }

  # The sync manifest (#207) persists under index_dir — keep it per-example
  # so one example's warm manifest can never leak skips into another.
  around do |example|
    Dir.mktmpdir do |dir|
      @index_dir = dir
      example.run
    end
  end

  let(:index_dir) { @index_dir }
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

  # An in-memory page registry standing in for the two Notion databases, so
  # title collisions actually collide and page lookups find whatever an
  # earlier upsert stored — exactly like the real databases do. Introduced
  # for the #149 examples; the incremental-sync examples (#207) reuse it and
  # add per-method API call counters, plus real-API 404 behavior on
  # update_page for unknown page ids (what a deleted/archived page answers).
  shared_context 'with an in-memory Notion page registry' do
    let(:registry) { {} }
    let(:api_calls) { Hash.new(0) }

    before do
      allow(client).to receive(:create_page) do |database_id:, properties:|
        api_calls[:create_page] += 1
        id = "page-#{registry.size + 1}"
        registry[id] = { 'id' => id, db: database_id, properties: properties }
        { 'id' => id }
      end
      allow(client).to receive(:update_page) do |page_id:, properties:|
        api_calls[:update_page] += 1
        page = registry[page_id]
        raise Woods::Error, "Notion API error 404: Could not find page with ID: #{page_id}." unless page

        page[:properties] = page[:properties].merge(properties)
        { 'id' => page_id }
      end
      allow(client).to receive(:find_page_by_title) do |database_id:, title:|
        api_calls[:find_page_by_title] += 1
        pages_titled(database_id, title).first
      end
      allow(client).to receive(:query_database) do |database_id:, filter:|
        api_calls[:query_database] += 1
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

    it 'reports nothing skipped on a cold manifest' do
      stats = exporter.sync_all
      expect(stats[:skipped]).to eq(0)
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

    # EXP-11. A columns-only configuration used to return all-zero stats with
    # no message — indistinguishable from breakage, and contradicting the
    # documented "the other sync is skipped" contract.
    context 'when only the columns database is configured' do
      let(:columns_only_config) do
        double(
          'Configuration',
          notion_api_token: 'secret_test',
          notion_database_ids: { columns: 'db-columns-uuid' }
        )
      end

      subject(:columns_only_exporter) do
        described_class.new(index_dir: index_dir, config: columns_only_config, client: client, reader: reader)
      end

      it 'still syncs the columns, without a Table relation' do
        created = []
        allow(client).to receive(:create_page) do |args|
          created << args[:properties]
          { 'id' => "page-#{SecureRandom.hex(4)}" }
        end

        stats = columns_only_exporter.sync_all

        expect(stats[:columns]).to eq(3)
        expect(created.map(&:keys).flatten.uniq).not_to include('Table')
      end

      it 'says why the Table relation is missing' do
        expect { columns_only_exporter.sync_all }.to output(/without a Table relation/).to_stderr
      end
    end
  end

  # EXP-5. Every public IndexReader accessor self-refreshes when the published
  # generation moves, and the reader assigns pinning responsibility to direct
  # callers — so an extraction publishing mid-export used to produce an export
  # assembled from two generations.
  describe 'generation pinning' do
    it 'performs every index read inside one pinned generation' do
      pinned = false
      reads = []

      allow(reader).to receive(:with_pinned_generation) do |&block|
        pinned = true
        begin
          block.call
        ensure
          pinned = false
        end
      end
      allow(reader).to receive(:list_units) do |type:|
        reads << pinned
        (type == 'model' ? model_units : migration_units).map { |u| { 'identifier' => u['identifier'] } }
      end
      allow(reader).to receive(:find_unit) do |identifier|
        reads << pinned
        (model_units + migration_units).find { |u| u['identifier'] == identifier }
      end

      exporter.sync_all

      expect(reads).not_to be_empty
      expect(reads).to all(be(true))
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

    # #217 / B-104. An authentication failure is not a per-unit problem: a bad
    # or unshared token dooms every remaining call. Collecting it per unit meant
    # a wrong token spent the entire cold sync at Notion's 3 req/sec before
    # reporting failure for everything.
    it 'aborts the run on an authentication failure instead of collecting it per unit' do
      allow(client).to receive(:find_page_by_title)
        .and_raise(Woods::Notion::AuthenticationError, 'Notion API error 401: API token is invalid.')

      expect { exporter.sync_data_models }.to raise_error(Woods::Notion::AuthenticationError, /401/)
    end

    it 'stops after the first unit rather than trying the rest' do
      allow(client).to receive(:find_page_by_title)
        .and_raise(Woods::Notion::AuthenticationError, 'Notion API error 401: API token is invalid.')

      expect { exporter.sync_data_models }.to raise_error(Woods::Notion::AuthenticationError)
      expect(client).to have_received(:find_page_by_title).once
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
    include_context 'with an in-memory Notion page registry'

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

      # EXP-1. Column pages are qualified by *table*, so both models emitted
      # the title "users.id" with a different Table relation and a different
      # content hash. Each run, each model saw the other's hash and PATCHed
      # the page back — two API calls per shared column, forever, with the
      # relation pointing at whichever model synced last.
      it 'issues zero API calls on an unchanged second sync' do
        exporter.sync_all
        cold_calls = api_calls.dup

        stats = described_class.new(index_dir: index_dir, config: config, client: client, reader: reader).sync_all

        expect(api_calls).to eq(cold_calls)
        expect(stats[:columns]).to eq(0)
        expect(stats[:errors]).to be_empty
      end

      it 'points the shared column at every owning model, in a stable order' do
        exporter.sync_all
        relation_after_first = pages_titled('db-columns-uuid', 'users.id').first[:properties]['Table']

        described_class.new(index_dir: index_dir, config: config, client: client, reader: reader).sync_all
        relation_after_second = pages_titled('db-columns-uuid', 'users.id').first[:properties]['Table']

        model_page_ids = %w[Admin User].map { |name| pages_titled('db-models-uuid', "users (#{name})").first['id'] }
        expect(relation_after_first).to eq({ relation: model_page_ids.map { |id| { id: id } } })
        expect(relation_after_second).to eq(relation_after_first)
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

  describe 'incremental sync via the manifest (#207 / B-095)' do
    include_context 'with an in-memory Notion page registry'

    def build_exporter(**overrides)
      described_class.new(index_dir: index_dir, config: config, client: client, reader: reader, **overrides)
    end

    it 'issues zero API calls on an unchanged second sync' do
      exporter.sync_all
      cold_calls = api_calls.dup

      stats = build_exporter.sync_all

      expect(api_calls).to eq(cold_calls)
      expect(stats).to include(data_models: 0, columns: 0, skipped: 5)
      expect(stats[:errors]).to be_empty
    end

    it 'keeps the cold-manifest call pattern identical to the pre-manifest #149 path' do
      # 2 models: title lookup + create each (unique tables, no legacy query).
      # 3 columns: title lookup + legacy query + create each.
      exporter.sync_all

      expect(api_calls).to eq(find_page_by_title: 5, query_database: 3, create_page: 5)
    end

    it 'PATCHes a changed page by cached id with no title query' do
      exporter.sync_all
      user_page_id = pages_titled('db-models-uuid', 'users').first['id']
      cold_calls = api_calls.dup

      model_units[0]['metadata']['column_count'] = 5
      build_exporter.sync_all

      expect(api_calls).to eq(cold_calls.merge(update_page: cold_calls[:update_page] + 1))
      expect(registry.fetch(user_page_id)[:properties]['Column Count']).to eq({ number: 5 })
    end

    it 'keeps column Table relations stable when the parent model page is skipped' do
      exporter.sync_all
      user_page_id = pages_titled('db-models-uuid', 'users').first['id']

      model_units[0]['metadata']['columns'][1]['type'] = 'citext'
      stats = build_exporter.sync_all

      email_page = pages_titled('db-columns-uuid', 'users.email').first
      expect(email_page[:properties]['Table']).to eq({ relation: [{ id: user_page_id }] })
      expect(email_page[:properties]['Data Type']).to eq({ select: { name: 'citext' } })
      expect(stats).to include(data_models: 0, columns: 1, skipped: 4)
    end

    it 'self-heals when a cached page was deleted in Notion behind the manifest' do
      exporter.sync_all
      doomed_id = pages_titled('db-models-uuid', 'users').first['id']
      registry.delete(doomed_id)

      model_units[0]['metadata']['column_count'] = 9
      stats = nil
      expect { stats = build_exporter.sync_all }
        .to output(/cached page #{doomed_id}.*is gone.*recreating/m).to_stderr

      recreated = pages_titled('db-models-uuid', 'users')
      expect(recreated.size).to eq(1)
      expect(recreated.first['id']).not_to eq(doomed_id)
      expect(stats[:errors]).to be_empty
    end

    it 'settles back to zero API calls on the run after a self-heal' do
      exporter.sync_all
      registry.delete(pages_titled('db-models-uuid', 'users').first['id'])
      model_units[0]['metadata']['column_count'] = 9
      expect { build_exporter.sync_all }.to output(/is gone/m).to_stderr

      calls_after_heal = api_calls.dup
      stats = build_exporter.sync_all

      expect(api_calls).to eq(calls_after_heal)
      expect(stats[:skipped]).to eq(5)
    end

    it 'does not self-heal on unrelated API failures' do
      exporter.sync_all
      model_units[0]['metadata']['column_count'] = 9
      allow(client).to receive(:update_page)
        .and_raise(Woods::Error, 'Notion API error 500: Internal server error')

      stats = build_exporter.sync_all

      expect(stats[:errors]).to include(a_string_matching(/User: Notion API error 500/))
      expect(api_calls[:create_page]).to eq(5) # no duplicate page created
    end

    it 'prunes manifest entries whose key vanished, leaving the Notion page alone' do
      exporter.sync_all
      post_page_id = pages_titled('db-models-uuid', 'posts').first['id']
      cold_calls = api_calls.dup

      allow(reader).to receive(:list_units).with(type: 'model').and_return([{ 'identifier' => 'User' }])
      build_exporter.sync_all

      expect(api_calls).to eq(cold_calls) # nothing re-checked, nothing deleted
      expect(registry).to have_key(post_page_id)
      manifest_data = JSON.parse(Woods::AtomicFile.read(File.join(index_dir, 'notion_sync_manifest.json')))
      expect(manifest_data.dig('pages', 'data_models').keys).to contain_exactly('users')
      expect(manifest_data.dig('pages', 'columns').keys).to contain_exactly('users.id', 'users.email')
    end

    it 'falls back to a full resync when the manifest file is corrupt, without crashing' do
      exporter.sync_all
      cold_calls = api_calls.dup

      File.binwrite(File.join(index_dir, 'notion_sync_manifest.json'), "{ \xE2\x80\x94 not json".b)
      second = nil
      expect { second = build_exporter }.to output(/discarding notion sync manifest/i).to_stderr
      stats = second.sync_all

      # Every page re-checked by title (pages exist now, so updates not creates).
      expect(api_calls[:find_page_by_title]).to eq(cold_calls[:find_page_by_title] * 2)
      expect(api_calls[:update_page]).to eq(5)
      expect(api_calls[:create_page]).to eq(cold_calls[:create_page])
      expect(stats[:errors]).to be_empty
    end

    it 'ignores the manifest for one run when WOODS_NOTION_FORCE is set' do
      exporter.sync_all
      cold_calls = api_calls.dup

      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('WOODS_NOTION_FORCE', '').and_return('1')
      stats = build_exporter.sync_all

      expect(api_calls[:find_page_by_title]).to eq(cold_calls[:find_page_by_title] * 2)
      expect(api_calls[:update_page]).to eq(5)
      expect(stats[:skipped]).to eq(0)
    end

    it 'does not treat WOODS_NOTION_FORCE=0 as force' do
      exporter.sync_all
      cold_calls = api_calls.dup

      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('WOODS_NOTION_FORCE', '').and_return('0')
      build_exporter.sync_all

      expect(api_calls).to eq(cold_calls)
    end

    it 'accepts force_full: true as the programmatic escape hatch' do
      exporter.sync_all
      cold_calls = api_calls.dup

      build_exporter(force_full: true).sync_all

      expect(api_calls[:find_page_by_title]).to eq(cold_calls[:find_page_by_title] * 2)
      expect(api_calls[:update_page]).to eq(5)
    end

    it 'still syncs (and warns) when the manifest cannot be persisted' do
      manifest = Woods::Notion::SyncManifest.new(
        path: File.join(index_dir, 'notion_sync_manifest.json'),
        database_ids: config.notion_database_ids
      )
      allow(manifest).to receive(:save).and_raise(Errno::EACCES, 'disk says no')

      stats = nil
      expect { stats = build_exporter(manifest: manifest).sync_all }
        .to output(/manifest not persisted/i).to_stderr
      expect(stats[:data_models]).to eq(2)
      expect(stats[:errors]).to be_empty
    end
  end
end
