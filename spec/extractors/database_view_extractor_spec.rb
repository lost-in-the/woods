# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'active_support/core_ext/string/inflections'
require 'codebase_index/model_name_cache'
require 'codebase_index/extractors/database_view_extractor'

RSpec.describe CodebaseIndex::Extractors::DatabaseViewExtractor do
  include_context 'extractor setup'

  # ── Initialization ───────────────────────────────────────────────────

  describe '#initialize' do
    it 'handles missing db/views/ directory gracefully' do
      extractor = described_class.new
      expect(extractor.extract_all).to eq([])
    end
  end

  # ── extract_all ──────────────────────────────────────────────────────

  describe '#extract_all' do
    it 'discovers sql files in db/views/' do
      create_file('db/views/active_users_v01.sql', 'SELECT id FROM users WHERE active = true')

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.type).to eq(:database_view)
    end

    it 'returns only the latest version of each view' do
      create_file('db/views/active_users_v01.sql', 'SELECT id FROM users WHERE active = true')
      create_file('db/views/active_users_v02.sql', 'SELECT id, email FROM users WHERE active = true')

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.metadata[:version]).to eq(2)
    end

    it 'returns one unit per distinct view name' do
      create_file('db/views/active_users_v01.sql', 'SELECT id FROM users WHERE active = true')
      create_file('db/views/recent_orders_v01.sql', 'SELECT id FROM orders WHERE created_at > NOW()')

      units = described_class.new.extract_all
      expect(units.size).to eq(2)
      identifiers = units.map(&:identifier)
      expect(identifiers).to contain_exactly('active_users', 'recent_orders')
    end

    it 'ignores non-versioned sql files' do
      create_file('db/views/active_users_v01.sql', 'SELECT id FROM users')
      create_file('db/views/notes.sql', 'SELECT id FROM notes')

      units = described_class.new.extract_all
      expect(units.size).to eq(1)
      expect(units.first.identifier).to eq('active_users')
    end

    it 'handles multiple views with multiple versions each' do
      create_file('db/views/active_users_v01.sql', 'SELECT id FROM users WHERE active = true')
      create_file('db/views/active_users_v03.sql', 'SELECT id, email FROM users WHERE active = true')
      create_file('db/views/recent_orders_v01.sql', 'SELECT id FROM orders')
      create_file('db/views/recent_orders_v02.sql', 'SELECT id, total FROM orders')

      units = described_class.new.extract_all
      expect(units.size).to eq(2)

      active_users = units.find { |u| u.identifier == 'active_users' }
      recent_orders = units.find { |u| u.identifier == 'recent_orders' }

      expect(active_users.metadata[:version]).to eq(3)
      expect(recent_orders.metadata[:version]).to eq(2)
    end
  end

  # ── extract_view_file ────────────────────────────────────────────────

  describe '#extract_view_file' do
    it 'extracts a basic view' do
      path = create_file('db/views/active_users_v01.sql',
                         'SELECT id, email FROM users WHERE active = true')

      unit = described_class.new.extract_view_file(path)
      expect(unit).not_to be_nil
      expect(unit.type).to eq(:database_view)
      expect(unit.identifier).to eq('active_users')
      expect(unit.file_path).to eq(path)
    end

    it 'sets namespace to nil' do
      path = create_file('db/views/active_users_v01.sql', 'SELECT id FROM users')
      unit = described_class.new.extract_view_file(path)
      expect(unit.namespace).to be_nil
    end

    it 'sets source_code with annotation header' do
      path = create_file('db/views/active_users_v01.sql', 'SELECT id FROM users WHERE active = true')
      unit = described_class.new.extract_view_file(path)
      expect(unit.source_code).to include('-- ║ Database View: active_users')
      expect(unit.source_code).to include('SELECT id FROM users')
    end

    it 'returns nil for non-existent files' do
      unit = described_class.new.extract_view_file('/nonexistent/path_v01.sql')
      expect(unit).to be_nil
    end

    it 'includes all dependencies with :via key' do
      path = create_file('db/views/active_users_v01.sql',
                         'SELECT u.id FROM users u JOIN orders o ON u.id = o.user_id')

      unit = described_class.new.extract_view_file(path)
      unit.dependencies.each do |dep|
        expect(dep).to have_key(:via), "Dependency #{dep.inspect} missing :via key"
      end
    end
  end

  # ── Metadata ─────────────────────────────────────────────────────────

  describe 'metadata' do
    it 'sets view_name' do
      path = create_file('db/views/active_users_v01.sql', 'SELECT id FROM users')
      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:view_name]).to eq('active_users')
    end

    it 'sets version as integer' do
      path = create_file('db/views/active_users_v01.sql', 'SELECT id FROM users')
      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:version]).to eq(1)
    end

    it 'parses two-digit version numbers' do
      path = create_file('db/views/active_users_v12.sql', 'SELECT id FROM users')
      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:version]).to eq(12)
    end

    it 'detects non-materialized view' do
      path = create_file('db/views/active_users_v01.sql', 'SELECT id FROM users WHERE active = true')
      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:is_materialized]).to be false
    end

    it 'detects materialized view' do
      path = create_file('db/views/user_stats_v01.sql', <<~SQL)
        CREATE MATERIALIZED VIEW user_stats AS
        SELECT user_id, COUNT(*) as order_count
        FROM orders
        GROUP BY user_id
      SQL

      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:is_materialized]).to be true
    end

    it 'extracts tables_referenced from FROM clause' do
      path = create_file('db/views/active_users_v01.sql',
                         'SELECT id FROM users WHERE active = true')

      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:tables_referenced]).to include('users')
    end

    it 'extracts tables_referenced from JOIN clauses' do
      path = create_file('db/views/user_orders_v01.sql',
                         'SELECT u.id, o.total FROM users u JOIN orders o ON u.id = o.user_id')

      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:tables_referenced]).to include('users', 'orders')
    end

    it 'extracts tables_referenced from LEFT JOIN' do
      path = create_file('db/views/user_profiles_v01.sql',
                         'SELECT u.id FROM users u LEFT JOIN profiles p ON u.id = p.user_id')

      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:tables_referenced]).to include('users', 'profiles')
    end

    it 'returns deduplicated tables_referenced' do
      path = create_file('db/views/complex_v01.sql', <<~SQL)
        SELECT a.id, b.name
        FROM users a
        JOIN users b ON a.manager_id = b.id
      SQL

      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:tables_referenced].count('users')).to eq(1)
    end

    it 'extracts columns_selected from SELECT clause' do
      path = create_file('db/views/active_users_v01.sql',
                         'SELECT id, email, created_at FROM users WHERE active = true')

      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:columns_selected]).to include('id', 'email', 'created_at')
    end

    it 'returns ["*"] for SELECT *' do
      path = create_file('db/views/active_users_v01.sql', 'SELECT * FROM users WHERE active = true')
      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:columns_selected]).to eq(['*'])
    end

    it 'handles table.column notation in SELECT' do
      path = create_file('db/views/user_orders_v01.sql',
                         'SELECT u.id, o.total FROM users u JOIN orders o ON u.id = o.user_id')

      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:columns_selected]).to include('id', 'total')
    end

    it 'includes loc count' do
      path = create_file('db/views/active_users_v01.sql', <<~SQL)
        SELECT
          id,
          email
        FROM users
        WHERE active = true
      SQL

      unit = described_class.new.extract_view_file(path)
      expect(unit.metadata[:loc]).to be_a(Integer)
      expect(unit.metadata[:loc]).to be > 0
    end

    it 'includes all expected metadata keys' do
      path = create_file('db/views/active_users_v01.sql', 'SELECT id FROM users')
      unit = described_class.new.extract_view_file(path)
      meta = unit.metadata

      expect(meta).to have_key(:view_name)
      expect(meta).to have_key(:version)
      expect(meta).to have_key(:is_materialized)
      expect(meta).to have_key(:tables_referenced)
      expect(meta).to have_key(:columns_selected)
      expect(meta).to have_key(:loc)
    end
  end

  # ── Dependencies ─────────────────────────────────────────────────────

  describe 'dependencies' do
    it 'creates model dependencies from referenced tables via classify' do
      path = create_file('db/views/active_users_v01.sql',
                         'SELECT id FROM users WHERE active = true')

      unit = described_class.new.extract_view_file(path)
      user_dep = unit.dependencies.find { |d| d[:target] == 'User' }
      expect(user_dep).not_to be_nil
      expect(user_dep[:type]).to eq(:model)
      expect(user_dep[:via]).to eq(:table_name)
    end

    it 'creates model dependencies for all JOIN tables' do
      path = create_file('db/views/user_orders_v01.sql',
                         'SELECT u.id FROM users u JOIN orders o ON u.id = o.user_id')

      unit = described_class.new.extract_view_file(path)
      targets = unit.dependencies.map { |d| d[:target] }
      expect(targets).to include('User', 'Order')
    end

    it 'excludes internal Rails tables from dependencies' do
      path = create_file('db/views/schema_check_v01.sql',
                         'SELECT * FROM schema_migrations WHERE version > 0')

      unit = described_class.new.extract_view_file(path)
      targets = unit.dependencies.map { |d| d[:target] }
      expect(targets).not_to include('SchemaMigration')
    end

    it 'returns empty dependencies when no tables referenced' do
      path = create_file('db/views/computed_v01.sql', 'SELECT 1 + 1 AS result')
      unit = described_class.new.extract_view_file(path)
      expect(unit.dependencies).to eq([])
    end
  end

  # ── Serialization round-trip ─────────────────────────────────────────

  describe 'serialization' do
    it 'to_h round-trips correctly' do
      path = create_file('db/views/active_users_v02.sql',
                         'SELECT id, email FROM users WHERE active = true')

      unit = described_class.new.extract_view_file(path)
      hash = unit.to_h

      expect(hash[:type]).to eq(:database_view)
      expect(hash[:identifier]).to eq('active_users')
      expect(hash[:source_code]).to include('active_users')
      expect(hash[:source_hash]).to be_a(String)
      expect(hash[:extracted_at]).to be_a(String)

      json = JSON.generate(hash)
      parsed = JSON.parse(json)
      expect(parsed['type']).to eq('database_view')
      expect(parsed['identifier']).to eq('active_users')
    end
  end
end
