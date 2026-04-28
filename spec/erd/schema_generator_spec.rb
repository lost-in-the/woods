# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'
require 'woods'
require 'woods/erd/schema_generator'

RSpec.describe Woods::Erd::SchemaGenerator do
  let(:output_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(output_dir) }

  def write_model_unit(identifier, metadata)
    models_dir = File.join(output_dir, 'models')
    FileUtils.mkdir_p(models_dir)

    unit = {
      'type' => 'model',
      'identifier' => identifier,
      'metadata' => metadata
    }

    digest = Digest::SHA256.hexdigest(identifier)[0, 8]
    filename = "#{identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}_#{digest}.json"
    File.write(File.join(models_dir, filename), JSON.generate(unit))

    # Write _index.json
    index_path = File.join(models_dir, '_index.json')
    existing = File.exist?(index_path) ? JSON.parse(File.read(index_path)) : []
    existing << { 'identifier' => identifier, 'file' => filename }
    File.write(index_path, JSON.generate(existing))
  end

  def write_unit(type, identifier, metadata: {}, dependencies: [])
    type_dir = File.join(output_dir, "#{type}s")
    FileUtils.mkdir_p(type_dir)

    unit = {
      'type' => type.to_s,
      'identifier' => identifier,
      'metadata' => metadata,
      'dependencies' => dependencies
    }

    digest = Digest::SHA256.hexdigest(identifier)[0, 8]
    filename = "#{identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}_#{digest}.json"
    File.write(File.join(type_dir, filename), JSON.generate(unit))
  end

  describe '#generate' do
    it 'generates a table with columns' do
      write_model_unit('Post', {
                         'table_name' => 'posts',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'columns' => [
                           { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil },
                           { 'name' => 'title', 'type' => 'varchar(255)', 'null' => false, 'default' => nil },
                           { 'name' => 'body', 'type' => 'text', 'null' => true, 'default' => nil }
                         ],
                         'associations' => [],
                         'indexes' => [],
                         'foreign_keys' => [],
                         'enums' => {}
                       })

      schema = described_class.new(output_dir).generate

      expect(schema['tables']).to have_key('posts')
      table = schema['tables']['posts']
      expect(table['name']).to eq('posts')
      expect(table['columns']['id']['notNull']).to eq(true)
      expect(table['columns']['title']['type']).to eq('varchar(255)')
      expect(table['columns']['body']['notNull']).to eq(false)
    end

    it 'generates primary key constraints' do
      write_model_unit('Post', {
                         'table_name' => 'posts',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'columns' => [
                           { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }
                         ],
                         'associations' => [],
                         'indexes' => [],
                         'foreign_keys' => [],
                         'enums' => {}
                       })

      schema = described_class.new(output_dir).generate
      constraints = schema['tables']['posts']['constraints']

      expect(constraints).to have_key('posts_pkey')
      pk = constraints['posts_pkey']
      expect(pk['type']).to eq('PRIMARY KEY')
      expect(pk['columnNames']).to eq(['id'])
    end

    it 'generates foreign key constraints from foreign_keys metadata' do
      write_model_unit('Post', {
                         'table_name' => 'posts',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'columns' => [
                           { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil },
                           { 'name' => 'user_id', 'type' => 'bigint', 'null' => false, 'default' => nil }
                         ],
                         'associations' => [
                           { 'name' => 'user', 'type' => 'belongs_to', 'target' => 'User', 'foreign_key' => 'user_id',
                             'polymorphic' => false }
                         ],
                         'foreign_keys' => [
                           { 'from_table' => 'posts', 'to_table' => 'users', 'column' => 'user_id',
                             'primary_key' => 'id', 'name' => 'fk_rails_user',
                             'on_delete' => nil, 'on_update' => nil }
                         ],
                         'indexes' => [],
                         'enums' => {}
                       })

      schema = described_class.new(output_dir).generate
      constraints = schema['tables']['posts']['constraints']

      expect(constraints).to have_key('fk_rails_user')
      fk = constraints['fk_rails_user']
      expect(fk['type']).to eq('FOREIGN KEY')
      expect(fk['columnNames']).to eq(['user_id'])
      expect(fk['targetTableName']).to eq('users')
      expect(fk['targetColumnNames']).to eq(['id'])
    end

    it 'falls back to association-derived FKs when foreign_keys metadata absent' do
      write_model_unit('User', {
                         'table_name' => 'users',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
                         'associations' => [],
                         'indexes' => [],
                         'foreign_keys' => [],
                         'enums' => {}
                       })

      write_model_unit('Post', {
                         'table_name' => 'posts',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'columns' => [
                           { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil },
                           { 'name' => 'user_id', 'type' => 'bigint', 'null' => false, 'default' => nil }
                         ],
                         'associations' => [
                           { 'name' => 'user', 'type' => 'belongs_to', 'target' => 'User', 'foreign_key' => 'user_id',
                             'polymorphic' => false }
                         ],
                         'indexes' => [],
                         'enums' => {}
                       })

      schema = described_class.new(output_dir).generate
      constraints = schema['tables']['posts']['constraints']

      fk_key = 'fk_posts_user_id'
      expect(constraints).to have_key(fk_key)
      expect(constraints[fk_key]['targetTableName']).to eq('users')
    end

    it 'skips polymorphic associations in FK generation' do
      write_model_unit('Comment', {
                         'table_name' => 'comments',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'columns' => [
                           { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil },
                           { 'name' => 'commentable_id', 'type' => 'bigint', 'null' => false, 'default' => nil },
                           { 'name' => 'commentable_type', 'type' => 'varchar(255)', 'null' => false, 'default' => nil }
                         ],
                         'associations' => [
                           { 'name' => 'commentable', 'type' => 'belongs_to', 'target' => 'Comment',
                             'foreign_key' => 'commentable_id', 'polymorphic' => true }
                         ],
                         'foreign_keys' => [],
                         'indexes' => [],
                         'enums' => {}
                       })

      schema = described_class.new(output_dir).generate
      constraints = schema['tables']['comments']['constraints']

      fk_constraints = constraints.values.select { |c| c['type'] == 'FOREIGN KEY' }
      expect(fk_constraints).to be_empty
    end

    it 'generates indexes' do
      write_model_unit('Post', {
                         'table_name' => 'posts',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'columns' => [
                           { 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil },
                           { 'name' => 'slug', 'type' => 'varchar(255)', 'null' => false, 'default' => nil }
                         ],
                         'associations' => [],
                         'indexes' => [
                           { 'name' => 'index_posts_on_slug', 'unique' => true, 'columns' => ['slug'] }
                         ],
                         'foreign_keys' => [],
                         'enums' => {}
                       })

      schema = described_class.new(output_dir).generate
      indexes = schema['tables']['posts']['indexes']

      expect(indexes).to have_key('index_posts_on_slug')
      expect(indexes['index_posts_on_slug']['unique']).to eq(true)
      expect(indexes['index_posts_on_slug']['columns']).to eq(['slug'])
    end

    it 'deduplicates STI models sharing a table' do
      write_model_unit('Vehicle', {
                         'table_name' => 'vehicles',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'is_sti_base' => true,
                         'is_sti_child' => false,
                         'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
                         'associations' => [],
                         'indexes' => [],
                         'foreign_keys' => [],
                         'enums' => {}
                       })

      write_model_unit('Car', {
                         'table_name' => 'vehicles',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'is_sti_base' => false,
                         'is_sti_child' => true,
                         'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
                         'associations' => [],
                         'indexes' => [],
                         'foreign_keys' => [],
                         'enums' => {}
                       })

      schema = described_class.new(output_dir).generate

      expect(schema['tables'].keys).to eq(['vehicles'])
    end

    it 'skips models where table_exists is false' do
      write_model_unit('Ghost', {
                         'table_name' => 'ghosts',
                         'table_exists' => false,
                         'primary_key' => 'id',
                         'columns' => [],
                         'associations' => [],
                         'indexes' => [],
                         'foreign_keys' => [],
                         'enums' => {}
                       })

      schema = described_class.new(output_dir).generate

      expect(schema['tables']).to be_empty
    end

    it 'returns valid schema structure with enums and extensions' do
      write_model_unit('Post', {
                         'table_name' => 'posts',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
                         'associations' => [],
                         'indexes' => [],
                         'foreign_keys' => [],
                         'enums' => { 'status' => { 'draft' => 0, 'published' => 1 } }
                       })

      schema = described_class.new(output_dir).generate

      expect(schema).to have_key('tables')
      expect(schema).to have_key('enums')
      expect(schema).to have_key('extensions')

      expect(schema['enums']).to have_key('Post.status')
      expect(schema['enums']['Post.status']['values']).to eq(%w[draft published])
      expect(schema['enums']['Post.status']['name']).to eq('Post.status')
    end

    it 'raises an error when output directory has no models dir' do
      expect do
        described_class.new(output_dir).generate
      end.to raise_error(Woods::Error, /no extracted model data/i)
    end
  end

  describe '#generate with nodes' do
    before do
      write_model_unit('Order', {
                         'table_name' => 'orders',
                         'table_exists' => true,
                         'primary_key' => 'id',
                         'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false, 'default' => nil }],
                         'associations' => [],
                         'indexes' => [],
                         'foreign_keys' => [],
                         'enums' => {}
                       })
    end

    it 'generates controller nodes with actions as members' do
      write_unit(:controller, 'OrdersController',
                 metadata: {
                   'actions' => %w[index show create],
                   'action_count' => 3,
                   'filters' => [],
                   'routes' => {}
                 },
                 dependencies: [
                   { 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' }
                 ])

      schema = described_class.new(output_dir, layers: %i[models controllers]).generate

      expect(schema).to have_key('nodes')
      expect(schema['nodes']).to have_key('OrdersController')

      node = schema['nodes']['OrdersController']
      expect(node['name']).to eq('OrdersController')
      expect(node['type']).to eq('controller')
      expect(node['members']).to eq([
                                      { 'name' => 'index' },
                                      { 'name' => 'show' },
                                      { 'name' => 'create' }
                                    ])
      expect(node['meta']).to eq({ 'action_count' => 3 })
      expect(node['dependencies']).to include(
        hash_including('target' => 'orders', 'target_type' => 'table', 'via' => 'code_reference')
      )
    end

    it 'excludes nodes when layer is not active' do
      write_unit(:controller, 'OrdersController',
                 metadata: { 'actions' => %w[index], 'action_count' => 1 },
                 dependencies: [])

      schema = described_class.new(output_dir, layers: [:models]).generate

      expect(schema).not_to have_key('nodes')
    end

    it 'generates job nodes with perform params as members' do
      write_unit(:job, 'OrderSyncJob',
                 metadata: {
                   'perform_params' => %w[order_id force],
                   'queue' => 'critical',
                   'job_type' => 'sidekiq'
                 },
                 dependencies: [
                   { 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' }
                 ])

      schema = described_class.new(output_dir, layers: %i[models jobs]).generate

      expect(schema['nodes']).to have_key('OrderSyncJob')
      node = schema['nodes']['OrderSyncJob']
      expect(node['type']).to eq('job')
      expect(node['members']).to eq([{ 'name' => 'order_id' }, { 'name' => 'force' }])
      expect(node['meta']).to eq({ 'queue' => 'critical', 'job_type' => 'sidekiq' })
    end

    it 'extracts name strings from hash-style perform params' do
      write_unit(:job, 'SyncWorker',
                 metadata: {
                   'perform_params' => [
                     { 'name' => 'account_id', 'splat' => nil, 'has_default' => false },
                     { 'name' => 'force', 'splat' => nil, 'has_default' => true }
                   ],
                   'queue' => 'default'
                 },
                 dependencies: [])

      schema = described_class.new(output_dir, layers: %i[models jobs]).generate

      node = schema['nodes']['SyncWorker']
      expect(node['members']).to eq([{ 'name' => 'account_id' }, { 'name' => 'force' }])
    end

    it 'generates service nodes with public methods as members' do
      write_unit(:service, 'OrderCreator',
                 metadata: {
                   'public_methods' => %w[call validate],
                   'is_callable' => true
                 },
                 dependencies: [
                   { 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' }
                 ])

      schema = described_class.new(output_dir, layers: %i[models services]).generate

      expect(schema['nodes']).to have_key('OrderCreator')
      node = schema['nodes']['OrderCreator']
      expect(node['type']).to eq('service')
      expect(node['members']).to eq([{ 'name' => 'call' }, { 'name' => 'validate' }])
      expect(node['meta']).to eq({ 'callable' => true })
    end

    it 'generates mailer nodes with mail actions as members' do
      write_unit(:mailer, 'OrderMailer',
                 metadata: {
                   'actions' => %w[confirmation receipt],
                   'action_count' => 2,
                   'delivery_method' => 'smtp'
                 },
                 dependencies: [
                   { 'type' => 'model', 'target' => 'Order', 'via' => 'code_reference' }
                 ])

      schema = described_class.new(output_dir, layers: %i[models mailers]).generate

      expect(schema['nodes']).to have_key('OrderMailer')
      node = schema['nodes']['OrderMailer']
      expect(node['type']).to eq('mailer')
      expect(node['members']).to eq([{ 'name' => 'confirmation' }, { 'name' => 'receipt' }])
      expect(node['meta']).to include('delivery_method' => 'smtp', 'action_count' => 2)
    end

    it 'generates nodes for all active layers' do
      write_unit(:controller, 'OrdersController',
                 metadata: { 'actions' => %w[index], 'action_count' => 1 },
                 dependencies: [])
      write_unit(:job, 'OrderSyncJob',
                 metadata: { 'perform_params' => %w[order_id], 'queue' => 'default' },
                 dependencies: [])

      schema = described_class.new(output_dir, layers: %i[models controllers jobs]).generate

      expect(schema['nodes']).to have_key('OrdersController')
      expect(schema['nodes']).to have_key('OrderSyncJob')
    end

    it 'skips layers with no extraction directory' do
      schema = described_class.new(output_dir, layers: %i[models controllers jobs]).generate

      expect(schema).not_to have_key('nodes')
    end

    it 'generates nodes with empty dependencies array' do
      write_unit(:service, 'Standalone',
                 metadata: { 'public_methods' => %w[run], 'is_callable' => false },
                 dependencies: [])

      schema = described_class.new(output_dir, layers: %i[models services]).generate

      expect(schema['nodes']['Standalone']['dependencies']).to eq([])
    end
  end

  describe '#generate with entry points' do
    it 'includes entryPoints when routes directory is present' do
      FileUtils.mkdir_p(File.join(output_dir, 'routes'))
      FileUtils.mkdir_p(File.join(output_dir, 'controllers'))
      FileUtils.mkdir_p(File.join(output_dir, 'models'))

      route_unit = {
        'type' => 'route',
        'identifier' => 'r1',
        'metadata' => { 'http_method' => 'GET', 'path' => '/checkout', 'action' => 'new' },
        'dependencies' => [{ 'type' => 'controller', 'target' => 'CheckoutController', 'via' => 'route_dispatch' }]
      }
      File.write(File.join(output_dir, 'routes', 'r1.json'), JSON.generate(route_unit))

      controller_unit = {
        'type' => 'controller',
        'identifier' => 'CheckoutController',
        'metadata' => {}
      }
      File.write(File.join(output_dir, 'controllers', 'checkout.json'), JSON.generate(controller_unit))
      write_model_unit('Dummy', { 'table_name' => 'dummies', 'table_exists' => true, 'columns' => [] })

      schema = described_class.new(output_dir).generate

      expect(schema['entryPoints']).to eq([
                                            { 'identifier' => 'CheckoutController', 'verb' => 'GET',
                                              'path' => '/checkout', 'action' => 'new' }
                                          ])
    end

    it 'omits entryPoints when routes directory is missing' do
      write_model_unit('Dummy', { 'table_name' => 'dummies', 'table_exists' => true, 'columns' => [] })

      schema = described_class.new(output_dir).generate

      expect(schema).not_to have_key('entryPoints')
    end
  end
end
