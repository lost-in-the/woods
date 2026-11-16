# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/embedded_executor'

RSpec.describe 'console_sql SQLite parameter tokens' do
  let(:connection) { double('Connection', adapter_name: 'SQLite') }
  let(:executor) do
    Woods::Console::EmbeddedExecutor.new(
      model_validator: Woods::Console::ModelValidator.new(registry: { 'User' => %w[id name] }),
      safe_context: Woods::Console::SafeContext.new(connection: connection), connection: connection,
      read_tools_enabled: true
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
    allow(connection).to receive(:select_all)
      .and_return(double(columns: ['id'], rows: [[1]], column_types: { 'id' => double(type: :integer) }))
  end

  def request(sql)
    executor.send_request('tool' => 'sql', 'params' => { 'sql' => sql })
  end

  ['SELECT id FROM users WHERE id = ?', 'SELECT id FROM users WHERE id = ?1',
   'SELECT id FROM users WHERE id = ?12', 'SELECT id FROM users WHERE name = :name',
   'SELECT id FROM users WHERE name = @name', 'SELECT id FROM users WHERE name = #name',
   'SELECT id FROM users WHERE name = $name', 'SELECT id FROM users WHERE name = $a::b',
   'SELECT id FROM users WHERE name=:name', 'SELECT :name', 'SELECT id FROM users LIMIT ?',
   "SELECT id FROM users WHERE name = 'a' AND id = ?", 'SELECT id FROM users WHERE name = @::a',
   'SELECT id FROM users WHERE name = :1', 'SELECT id FROM users WHERE name = $a(b)',
   "SELECT id FROM users -- comment\nWHERE id = :id"].each do |sql|
    it "refuses #{sql.inspect} before any other check" do
      allow(Woods::Console::SqlValidator).to receive(:new).and_call_original
      result = request(sql)
      expect(result).to include('ok' => false, 'error_type' => 'validation')
      expect(result['error']).to start_with('Rejected: console_sql passes no bind values')
      expect(Woods::Console::SqlValidator).not_to have_received(:new)
      expect(connection).not_to have_received(:select_all)
    end
  end

  ["SELECT id FROM users WHERE name = ':name'", "SELECT id FROM users WHERE name = '@name #name $name ?'",
   "SELECT 'a:b' AS label FROM users", 'SELECT id FROM users -- :name @name #name ?',
   'SELECT id FROM users /* :name ? */', "SELECT id FROM users WHERE name = 'it''s :x'",
   'SELECT "name" FROM users', 'SELECT name$1 FROM users', "SELECT json_extract('{}', '$.a') FROM users",
   'SELECT id FROM users WHERE id = 1'].each do |sql|
    it "keeps #{sql.inspect} working" do
      result = request(sql)
      expect(result['error'].to_s).not_to include('bind values')
    end
  end

  it 'keeps the plain statements among those executable' do
    ["SELECT id FROM users WHERE name = ':name'", 'SELECT id FROM users -- :name @name #name ?',
     'SELECT id FROM users /* :name ? */', 'SELECT id FROM users WHERE id = 1'].each do |sql|
      expect(request(sql)['ok']).to be(true), sql
    end
  end

  context 'on other adapters' do
    it 'keeps PostgreSQL casts working' do
      allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
      expect(request('SELECT id::text FROM users')['ok']).to be(true)
    end

    it 'keeps MySQL user variables and hash comments behaving as before' do
      allow(connection).to receive(:adapter_name).and_return('Mysql2')
      expect(request('SELECT id FROM users # note :name ?')['ok']).to be(true)
      result = request('SELECT @fixture_variable AS value')
      expect(result['error'].to_s).not_to include('bind values')
    end
  end
end
