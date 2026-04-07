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
    end

    it 'raises an error when output directory has no models dir' do
      expect do
        described_class.new(output_dir).generate
      end.to raise_error(Woods::Error, /no extracted model data/i)
    end
  end
end
