# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'codebase_index/extractors/migration_extractor'

RSpec.describe CodebaseIndex::Extractors::MigrationExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing db/migrate directory gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end

    it 'discovers db/migrate directory when present' do
      create_file('db/migrate/20240115123456_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.string :name
              t.timestamps
            end
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers all migration files in db/migrate/' do
      create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.string :name
              t.timestamps
            end
          end
        end
      RUBY

      create_file('db/migrate/20240102000000_add_email_to_users.rb', <<~RUBY)
        class AddEmailToUsers < ActiveRecord::Migration[7.1]
          def change
            add_column :users, :email, :string
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
      identifiers = units.map(&:identifier)
      expect(identifiers).to contain_exactly('CreateUsers', 'AddEmailToUsers')
    end

    it 'returns units with :migration type' do
      create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.timestamps
            end
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.first.type).to eq(:migration)
    end

    it 'returns units sorted by timestamp' do
      create_file('db/migrate/20240301000000_create_posts.rb', <<~RUBY)
        class CreatePosts < ActiveRecord::Migration[7.1]
          def change
            create_table :posts do |t|
              t.timestamps
            end
          end
        end
      RUBY

      create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.timestamps
            end
          end
        end
      RUBY

      units = described_class.new.extract_all
      expect(units.map(&:identifier)).to eq(%w[CreateUsers CreatePosts])
    end
  end

  # ── Filename Parsing ─────────────────────────────────────────────────

  describe 'filename parsing' do
    it 'extracts migration version (timestamp) from filename' do
      path = create_file('db/migrate/20240115123456_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:migration_version]).to eq('20240115123456')
    end

    it 'extracts class name as identifier' do
      path = create_file('db/migrate/20240115123456_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.identifier).to eq('CreateUsers')
    end

    it 'falls back to inferring class name from filename when source has no class declaration' do
      path = create_file('db/migrate/20240115123456_create_users.rb', <<~RUBY)
        # empty migration
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit).to be_nil
    end

    it 'handles files without timestamp prefix' do
      path = create_file('db/migrate/create_legacy_table.rb', <<~RUBY)
        class CreateLegacyTable < ActiveRecord::Migration
          def change
            create_table :legacy do |t|
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit).not_to be_nil
      expect(unit.identifier).to eq('CreateLegacyTable')
      expect(unit.metadata[:migration_version]).to be_nil
    end
  end

  # ── Rails Version Detection ──────────────────────────────────────────

  describe 'rails version detection' do
    it 'extracts Rails version from migration bracket notation' do
      path = create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:rails_version]).to eq('7.1')
    end

    it 'detects older migrations without version bracket' do
      path = create_file('db/migrate/20140101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration
          def change
            create_table :users do |t|
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:rails_version]).to be_nil
    end

    it 'handles different version formats (e.g., 6.0, 7.2)' do
      path = create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[6.0]
          def change
            create_table :users do |t|
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:rails_version]).to eq('6.0')
    end
  end

  # ── Reversibility Detection ──────────────────────────────────────────

  describe 'reversibility detection' do
    it 'detects change method as reversible' do
      path = create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.string :name
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:reversible]).to be true
      expect(unit.metadata[:direction]).to eq('change')
    end

    it 'detects up + down as reversible' do
      path = create_file('db/migrate/20240101000000_add_index.rb', <<~RUBY)
        class AddIndex < ActiveRecord::Migration[7.1]
          def up
            add_index :users, :email, unique: true
          end

          def down
            remove_index :users, :email
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:reversible]).to be true
      expect(unit.metadata[:direction]).to eq('up_down')
    end

    it 'detects up-only as not reversible' do
      path = create_file('db/migrate/20240101000000_data_migration.rb', <<~RUBY)
        class DataMigration < ActiveRecord::Migration[7.1]
          def up
            User.update_all(active: true)
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:reversible]).to be false
      expect(unit.metadata[:direction]).to eq('up_only')
    end

    it 'detects reversible block as reversible' do
      path = create_file('db/migrate/20240101000000_change_column.rb', <<~RUBY)
        class ChangeColumn < ActiveRecord::Migration[7.1]
          def change
            reversible do |dir|
              dir.up { change_column :users, :name, :text }
              dir.down { change_column :users, :name, :string }
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:reversible]).to be true
      expect(unit.metadata[:direction]).to eq('change')
    end

    it 'reports unknown direction for empty migration class' do
      path = create_file('db/migrate/20240101000000_empty_migration.rb', <<~RUBY)
        class EmptyMigration < ActiveRecord::Migration[7.1]
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:reversible]).to be false
      expect(unit.metadata[:direction]).to eq('unknown')
    end
  end

  # ── Table / Column / Index / Reference Extraction ────────────────────

  describe 'DDL extraction' do
    it 'extracts tables affected by create_table' do
      path = create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.string :name
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:tables_affected]).to include('users')
    end

    it 'extracts tables from add_column' do
      path = create_file('db/migrate/20240101000000_add_email.rb', <<~RUBY)
        class AddEmail < ActiveRecord::Migration[7.1]
          def change
            add_column :users, :email, :string
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:tables_affected]).to include('users')
    end

    it 'extracts tables from add_index' do
      path = create_file('db/migrate/20240101000000_add_index.rb', <<~RUBY)
        class AddIndex < ActiveRecord::Migration[7.1]
          def change
            add_index :orders, :user_id
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:tables_affected]).to include('orders')
    end

    it 'extracts tables from remove_column' do
      path = create_file('db/migrate/20240101000000_remove_col.rb', <<~RUBY)
        class RemoveCol < ActiveRecord::Migration[7.1]
          def change
            remove_column :users, :legacy_field
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:tables_affected]).to include('users')
    end

    it 'extracts tables from rename_table' do
      path = create_file('db/migrate/20240101000000_rename_table.rb', <<~RUBY)
        class RenameTable < ActiveRecord::Migration[7.1]
          def change
            rename_table :old_users, :users
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:tables_affected]).to contain_exactly('old_users', 'users')
    end

    it 'extracts tables from drop_table' do
      path = create_file('db/migrate/20240101000000_drop_table.rb', <<~RUBY)
        class DropTable < ActiveRecord::Migration[7.1]
          def change
            drop_table :legacy_users
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:tables_affected]).to include('legacy_users')
    end

    it 'extracts tables from add_reference' do
      path = create_file('db/migrate/20240101000000_add_ref.rb', <<~RUBY)
        class AddRef < ActiveRecord::Migration[7.1]
          def change
            add_reference :orders, :user, foreign_key: true
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:tables_affected]).to include('orders')
    end

    it 'deduplicates tables affected' do
      path = create_file('db/migrate/20240101000000_multi_op.rb', <<~RUBY)
        class MultiOp < ActiveRecord::Migration[7.1]
          def change
            add_column :users, :first_name, :string
            add_column :users, :last_name, :string
            add_index :users, [:first_name, :last_name]
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:tables_affected]).to eq(['users'])
    end

    it 'extracts columns added via add_column' do
      path = create_file('db/migrate/20240101000000_add_cols.rb', <<~RUBY)
        class AddCols < ActiveRecord::Migration[7.1]
          def change
            add_column :users, :email, :string
            add_column :users, :age, :integer
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:columns_added]).to contain_exactly(
        { table: 'users', column: 'email', type: 'string' },
        { table: 'users', column: 'age', type: 'integer' }
      )
    end

    it 'extracts columns added via t.type :name inside create_table blocks' do
      path = create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.string :name
              t.integer :age
              t.boolean :active, default: false
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:columns_added]).to include(
        { table: 'users', column: 'name', type: 'string' },
        { table: 'users', column: 'age', type: 'integer' },
        { table: 'users', column: 'active', type: 'boolean' }
      )
    end

    it 'extracts columns removed' do
      path = create_file('db/migrate/20240101000000_remove_cols.rb', <<~RUBY)
        class RemoveCols < ActiveRecord::Migration[7.1]
          def change
            remove_column :users, :legacy_field, :string
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:columns_removed]).to contain_exactly(
        { table: 'users', column: 'legacy_field', type: 'string' }
      )
    end

    it 'extracts indexes added' do
      path = create_file('db/migrate/20240101000000_add_indexes.rb', <<~RUBY)
        class AddIndexes < ActiveRecord::Migration[7.1]
          def change
            add_index :users, :email, unique: true
            add_index :orders, [:user_id, :created_at]
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:indexes_added]).to include(
        { table: 'users', column: 'email' },
        { table: 'orders', column: 'user_id,created_at' }
      )
    end

    it 'extracts indexes removed' do
      path = create_file('db/migrate/20240101000000_remove_indexes.rb', <<~RUBY)
        class RemoveIndexes < ActiveRecord::Migration[7.1]
          def change
            remove_index :users, :email
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:indexes_removed]).to contain_exactly(
        { table: 'users', column: 'email' }
      )
    end

    it 'extracts references added' do
      path = create_file('db/migrate/20240101000000_add_refs.rb', <<~RUBY)
        class AddRefs < ActiveRecord::Migration[7.1]
          def change
            add_reference :orders, :user, foreign_key: true
            add_reference :comments, :post, null: false
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:references_added]).to contain_exactly(
        { table: 'orders', reference: 'user' },
        { table: 'comments', reference: 'post' }
      )
    end

    it 'extracts references removed' do
      path = create_file('db/migrate/20240101000000_remove_refs.rb', <<~RUBY)
        class RemoveRefs < ActiveRecord::Migration[7.1]
          def change
            remove_reference :orders, :user
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:references_removed]).to contain_exactly(
        { table: 'orders', reference: 'user' }
      )
    end

    it 'extracts t.references inside create_table blocks' do
      path = create_file('db/migrate/20240101000000_create_orders.rb', <<~RUBY)
        class CreateOrders < ActiveRecord::Migration[7.1]
          def change
            create_table :orders do |t|
              t.references :user, foreign_key: true
              t.decimal :total
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:references_added]).to include(
        { table: 'orders', reference: 'user' }
      )
    end
  end

  # ── Operations Tracking ──────────────────────────────────────────────

  describe 'operations tracking' do
    it 'tracks operations with counts' do
      path = create_file('db/migrate/20240101000000_complex.rb', <<~RUBY)
        class Complex < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.timestamps
            end

            add_column :users, :email, :string
            add_column :users, :name, :string
            add_index :users, :email
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      ops = unit.metadata[:operations]
      expect(ops).to include({ operation: 'create_table', count: 1 })
      expect(ops).to include({ operation: 'add_column', count: 2 })
      expect(ops).to include({ operation: 'add_index', count: 1 })
    end

    it 'handles multiple create_tables in one migration' do
      path = create_file('db/migrate/20240101000000_create_multi.rb', <<~RUBY)
        class CreateMulti < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.timestamps
            end

            create_table :profiles do |t|
              t.references :user
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      ops = unit.metadata[:operations]
      ct_op = ops.find { |o| o[:operation] == 'create_table' }
      expect(ct_op[:count]).to eq(2)
      expect(unit.metadata[:tables_affected]).to contain_exactly('users', 'profiles')
    end
  end

  # ── Risk Indicators ──────────────────────────────────────────────────

  describe 'risk indicators' do
    it 'detects data migration via update_all' do
      path = create_file('db/migrate/20240101000000_data_migration.rb', <<~RUBY)
        class DataMigration < ActiveRecord::Migration[7.1]
          def up
            User.update_all(active: true)
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:has_data_migration]).to be true
    end

    it 'detects data migration via find_each' do
      path = create_file('db/migrate/20240101000000_data_migration.rb', <<~RUBY)
        class DataMigration < ActiveRecord::Migration[7.1]
          def up
            User.find_each do |user|
              user.update!(name: user.name.titleize)
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:has_data_migration]).to be true
    end

    it 'detects data migration via find_in_batches' do
      path = create_file('db/migrate/20240101000000_data_migration.rb', <<~RUBY)
        class DataMigration < ActiveRecord::Migration[7.1]
          def up
            User.find_in_batches do |batch|
              batch.each { |u| u.update!(active: true) }
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:has_data_migration]).to be true
    end

    it 'detects raw SQL via execute' do
      path = create_file('db/migrate/20240101000000_raw_sql.rb', <<~RUBY)
        class RawSql < ActiveRecord::Migration[7.1]
          def up
            execute "UPDATE users SET active = true"
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:has_execute_sql]).to be true
    end

    it 'does not flag normal migrations as data migration' do
      path = create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.string :name
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:has_data_migration]).to be false
      expect(unit.metadata[:has_execute_sql]).to be false
    end
  end

  # ── LOC Counting ─────────────────────────────────────────────────────

  describe 'LOC counting' do
    it 'counts non-blank, non-comment lines' do
      path = create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        # A comment
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            # Another comment
            create_table :users do |t|
              t.string :name

              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      # Lines: class, def change, create_table, t.string, t.timestamps, end, end, end = 8
      expect(unit.metadata[:loc]).to eq(8)
    end
  end

  # ── Source Annotation ────────────────────────────────────────────────

  describe 'source annotation' do
    it 'annotates source with migration header' do
      path = create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.string :name
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.source_code).to include('Migration: CreateUsers')
      expect(unit.source_code).to include('Version: 20240101000000')
      expect(unit.source_code).to include('create_table :users')
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependency extraction' do
    it_behaves_like 'all dependencies have :via key',
                    :extract_migration_file,
                    'db/migrate/20240101000000_create_orders.rb',
                    <<~RUBY
                      class CreateOrders < ActiveRecord::Migration[7.1]
                        def change
                          create_table :orders do |t|
                            t.references :user, foreign_key: true
                            t.timestamps
                          end
                        end
                      end
                    RUBY

    it 'links to model via table name using classify' do
      path = create_file('db/migrate/20240101000000_create_orders.rb', <<~RUBY)
        class CreateOrders < ActiveRecord::Migration[7.1]
          def change
            create_table :orders do |t|
              t.string :number
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      model_deps = unit.dependencies.select { |d| d[:type] == :model }
      expect(model_deps.map { |d| d[:target] }).to include('Order')
    end

    it 'filters out Rails internal tables' do
      path = create_file('db/migrate/20240101000000_create_internals.rb', <<~RUBY)
        class CreateInternals < ActiveRecord::Migration[7.1]
          def change
            create_table :schema_migrations do |t|
              t.string :version
            end
            create_table :ar_internal_metadata do |t|
              t.string :key
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      model_deps = unit.dependencies.select { |d| d[:type] == :model && d[:via] == :table_name }
      expect(model_deps).to be_empty
    end

    it 'links references to target models' do
      path = create_file('db/migrate/20240101000000_add_user_ref.rb', <<~RUBY)
        class AddUserRef < ActiveRecord::Migration[7.1]
          def change
            add_reference :orders, :user, foreign_key: true
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      model_deps = unit.dependencies.select { |d| d[:type] == :model }
      targets = model_deps.map { |d| d[:target] }
      expect(targets).to include('User')
    end

    it 'scans data migration code for common dependencies' do
      path = create_file('db/migrate/20240101000000_data_migration.rb', <<~RUBY)
        class DataMigration < ActiveRecord::Migration[7.1]
          def up
            NotificationJob.perform_later('migration_complete')
            MigrationService.call
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      job_deps = unit.dependencies.select { |d| d[:type] == :job }
      service_deps = unit.dependencies.select { |d| d[:type] == :service }
      expect(job_deps.map { |d| d[:target] }).to include('NotificationJob')
      expect(service_deps.map { |d| d[:target] }).to include('MigrationService')
    end

    it 'links add_column table to model' do
      path = create_file('db/migrate/20240101000000_add_email.rb', <<~RUBY)
        class AddEmail < ActiveRecord::Migration[7.1]
          def change
            add_column :users, :email, :string
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      model_deps = unit.dependencies.select { |d| d[:type] == :model && d[:via] == :table_name }
      expect(model_deps.map { |d| d[:target] }).to include('User')
    end
  end

  # ── Edge Cases ───────────────────────────────────────────────────────

  describe 'edge cases' do
    it 'handles empty change method' do
      path = create_file('db/migrate/20240101000000_empty_change.rb', <<~RUBY)
        class EmptyChange < ActiveRecord::Migration[7.1]
          def change
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit).not_to be_nil
      expect(unit.metadata[:tables_affected]).to eq([])
      expect(unit.metadata[:direction]).to eq('change')
    end

    it 'handles namespaced class names' do
      path = create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        module Legacy
          class CreateUsers < ActiveRecord::Migration[7.1]
            def change
              create_table :users do |t|
                t.timestamps
              end
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit).not_to be_nil
      expect(unit.identifier).to eq('Legacy::CreateUsers')
      expect(unit.namespace).to eq('Legacy')
    end

    it 'returns nil for non-migration Ruby files' do
      path = create_file('db/migrate/20240101000000_not_a_migration.rb', <<~RUBY)
        class NotAMigration
          def call
            puts "hello"
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit).to be_nil
    end

    it 'handles file read errors gracefully' do
      unit = described_class.new.extract_migration_file('/nonexistent/path.rb')
      expect(unit).to be_nil
    end

    it 'extracts columns from t.column :name, :type syntax' do
      path = create_file('db/migrate/20240101000000_create_users.rb', <<~RUBY)
        class CreateUsers < ActiveRecord::Migration[7.1]
          def change
            create_table :users do |t|
              t.column :name, :string
              t.column :age, :integer
              t.timestamps
            end
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:columns_added]).to include(
        { table: 'users', column: 'name', type: 'string' },
        { table: 'users', column: 'age', type: 'integer' }
      )
    end

    it 'handles change_column operations' do
      path = create_file('db/migrate/20240101000000_change_col.rb', <<~RUBY)
        class ChangeCol < ActiveRecord::Migration[7.1]
          def change
            change_column :users, :name, :text
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:tables_affected]).to include('users')
      ops = unit.metadata[:operations]
      expect(ops).to include({ operation: 'change_column', count: 1 })
    end

    it 'handles rename_column operations' do
      path = create_file('db/migrate/20240101000000_rename_col.rb', <<~RUBY)
        class RenameCol < ActiveRecord::Migration[7.1]
          def change
            rename_column :users, :name, :full_name
          end
        end
      RUBY

      unit = described_class.new.extract_migration_file(path)
      expect(unit.metadata[:tables_affected]).to include('users')
      ops = unit.metadata[:operations]
      expect(ops).to include({ operation: 'rename_column', count: 1 })
    end
  end
end
