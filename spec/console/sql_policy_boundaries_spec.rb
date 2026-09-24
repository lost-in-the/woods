# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/embedded_executor'

RSpec.describe 'Console SQL policy boundaries' do
  let(:connection) { double('Connection', adapter_name: 'PostgreSQL') }
  let(:context) do
    Woods::Console::SafeContext.new(
      connection: connection, redacted_columns: ['secret'],
      redacted_key_values: [{ key_column: 'name', value_column: 'value', sensitive_keys: ['private'] }]
    )
  end
  let(:executor) do
    Woods::Console::EmbeddedExecutor.new(
      model_validator: Woods::Console::ModelValidator.new(
        registry: { 'Preference' => %w[id name value], 'User' => %w[id name secret] },
        table_names: { 'Preference' => 'preferences', 'User' => 'users' }
      ), safe_context: context, connection: connection, read_tools_enabled: true,
      table_gate: Woods::Console::TableGate.new(blocked_tables: ['blocked'], model_tables: {})
    )
  end

  before do
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(connection).to receive(:execute)
    allow(connection).to receive(:select_value).and_return('')
    allow(connection).to receive(:select_all).and_return(
      double(columns: ['id'], rows: [[1]], column_types: { 'id' => double(type: :integer) })
    )
  end

  def request(sql, **params)
    executor.send_request('tool' => 'sql', 'params' => { 'sql' => sql, **params.transform_keys(&:to_s) })
  end

  it 'refuses an incomplete statement before a limit wrapper can complete it' do
    result = request('SELECT 1 FROM users) AS x, blocked --', limit: 5)
    expect(result).to include('ok' => false, 'error_type' => 'validation')
    expect(connection).not_to have_received(:select_all)
  end

  it 'validates the exact limited statement before execution' do
    validator = instance_spy(Woods::Console::SqlValidator)
    allow(Woods::Console::SqlValidator).to receive(:new).and_return(validator)
    expect(request('SELECT id FROM users', limit: 5)['ok']).to be true
    expect(connection).to have_received(:select_all) do |sql|
      expect(validator).to have_received(:validate!).with(sql)
    end
  end

  it 'keeps trailing line comments inside the limited subquery' do
    expect(request('SELECT id FROM users -- note', limit: 5)['ok']).to be true
    expect(connection).to have_received(:select_all).with(/-- note\n\) AS _limited LIMIT 5\z/)
  end

  it 'keeps directly selected protected columns available with a limit' do
    expect(request('SELECT secret FROM users', limit: 5)['ok']).to be true
  end

  it 'sees tables after nested PostgreSQL comments containing quotes' do
    sql = "SELECT 1 /* outer /* inner */ ' */ FROM blocked WHERE 'a'='a' -- '"
    expect(Woods::Console::SqlTableScanner.identifiers_in(sql, dialect: :postgres)).to include('blocked')
    expect(request(sql)).to include('ok' => false, 'error_type' => 'validation')
    expect(connection).not_to have_received(:select_all)
  end

  it 'keeps nested PostgreSQL comments and parentheses inside quoted identifiers harmless' do
    expect(request('SELECT id AS "(" /* outer /* inner */ end */ FROM users')['ok']).to be true
  end

  it 'checks protected columns conservatively for an unknown adapter' do
    allow(connection).to receive(:adapter_name).and_return('OtherAdapter')
    sql = %q(SELECT 'a\'b' AS note, secret AS visible FROM users WHERE name = 'z')
    expect { executor.send(:validate_protected_sql_usage!, sql) }
      .to raise_error(Woods::Console::ValidationError, /protected column/)
  end

  it 'requires structured EAV projections to use a key from the value source' do
    expect do
      executor.send(:validated_select, %w[users.name preferences.value], 'Preference')
    end.to raise_error(Woods::Console::ValidationError, /EAV/)
  end

  it 'keeps a qualified structured EAV pair supported' do
    expect(executor.send(:validated_select, %w[preferences.name preferences.value], 'Preference'))
      .to eq(%w[preferences.name preferences.value])
  end

  [
    'SELECT users.name, preferences.value FROM preferences JOIN users ON users.id = preferences.id',
    'SELECT users.name, preferences.value FROM preferences STRAIGHT_JOIN users ON users.id = preferences.id',
    'SELECT a.name, b.value FROM preferences a JOIN preferences b ON a.id = b.id',
    'SELECT * FROM preferences JOIN users ON users.id = preferences.id'
  ].each do |sql|
    it "refuses ambiguous SQL EAV provenance: #{sql}" do
      expect(request(sql)).to include('ok' => false, 'error_type' => 'validation')
      expect(connection).not_to have_received(:select_all)
    end
  end

  it 'keeps a simple SQL EAV pair supported' do
    expect(request('SELECT name, value FROM preferences')['ok']).to be true
  end

  ['SELECT users FROM users', 'SELECT u FROM users AS u',
   'SELECT (u) AS visible FROM users u', 'SELECT ARRAY[u] AS visible FROM users u',
   'SELECT (SELECT u FROM users u) AS visible', 'SELECT derived FROM (SELECT * FROM users) AS derived',
   'SELECT u$ FROM users AS u$', 'SELECT "ü" FROM users AS "ü"',
   'WITH x AS (SELECT users FROM users) SELECT * FROM x',
   'SELECT array_agg(u.*) FROM users u', 'SELECT u FROM users* u',
   'SELECT "u" FROM users"u"'].each do |sql|
    it "refuses composite projections without field provenance: #{sql}" do
      expect(request(sql)).to include('ok' => false, 'error_type' => 'validation')
      expect(connection).not_to have_received(:select_all)
    end
  end

  it 'keeps scalar qualified projections available' do
    expect(request('SELECT u.id FROM users AS u')['ok']).to be true
    expect(request('SELECT u.* FROM users AS u')['ok']).to be true
    expect(request('SELECT array_agg(u.id) FROM users AS u')['ok']).to be true
  end

  it 'refuses unrecognized PostgreSQL result types before returning their values' do
    allow(connection).to receive(:select_all).and_return(
      double(columns: ['opaque'], rows: [['synthetic opaque']], column_types: { 'opaque' => double(type: nil) })
    )
    expect(request("SELECT '0/1'::pg_lsn AS opaque")).to include('ok' => false, 'error_type' => 'validation')
  end

  it 'refuses missing PostgreSQL result metadata when a protection policy is active' do
    allow(connection).to receive(:select_all).and_return(double(columns: ['opaque'], rows: [['synthetic opaque']]))
    expect(request('SELECT 1 AS opaque')).to include('ok' => false, 'error_type' => 'validation')
  end

  it 'refuses quoted executable-comment fragments without swallowing following SQL' do
    allow(connection).to receive(:adapter_name).and_return('Mysql2')
    sql = "SELECT * /*!99999 ' */ FROM blocked WHERE 'a'='a' -- '"
    expect(Woods::Console::SqlTableScanner.identifiers_in(sql, dialect: :mysql)).to include('blocked')
    expect(request(sql)).to include('ok' => false, 'error_type' => 'validation')
    expect(connection).not_to have_received(:select_all)
  end

  it 'recognizes MariaDB executable-comment table references conservatively' do
    sql = 'SELECT * /*M! FROM blocked */'
    expect(Woods::Console::SqlTableScanner.identifiers_in(sql, dialect: :mysql)).to include('blocked')
  end

  it 'keeps simple executable-comment expressions and comment markers in literals supported' do
    allow(connection).to receive(:adapter_name).and_return('Mysql2')
    expect(request('SELECT /*! 1 + */ 1 AS total')['ok']).to be true
    expect(request("SELECT '/*!99999 quoted */' AS note")['ok']).to be true
  end

  it 'refuses recent ordering on an EAV value before a relation is fetched' do
    model = class_double('Preference')
    stub_const('Preference', model)
    expect(model).not_to receive(:order)
    response = executor.send_request('tool' => 'recent', 'params' => { 'model' => 'Preference', 'order_by' => 'value' })
    expect(response).to include('ok' => false, 'error_type' => 'validation')
    expect(response['error']).to include('EAV value column')
  end

  context 'with Trilogy' do
    before { allow(connection).to receive(:adapter_name).and_return('Trilogy') }

    it 'uses MySQL literal rules for protected projections' do
      sql = %q(SELECT 'a\'b' AS note, secret AS visible FROM users WHERE name = 'z')
      expect { executor.send(:validate_protected_sql_usage!, sql) }
        .to raise_error(Woods::Console::ValidationError, /protected column/)
    end

    it 'sets and restores the MySQL timeout' do
      allow(connection).to receive(:select_value).with('SELECT @@SESSION.max_execution_time').and_return(123)
      context.execute { nil }
      expect(connection).to have_received(:execute).with('SET max_execution_time = 5000').ordered
      expect(connection).to have_received(:execute).with('SET max_execution_time = 123').ordered
    end

    it 'uses MySQL random ordering' do
      stub_const('Arel', Module.new.tap { |mod| mod.define_singleton_method(:sql) { |sql| sql } })
      expect(executor.send(:random_function)).to eq('RAND()')
    end
  end
end
