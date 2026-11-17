# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/embedded_executor'

RSpec.describe 'Console SQL output identity' do
  let(:connection) { double('Connection') }
  let(:redacted_columns) { ['secret'] }
  let(:redacted_key_values) { [{ key_column: 'name', value_column: 'value', sensitive_keys: ['private'] }] }
  let(:context) do
    Woods::Console::SafeContext.new(connection: connection, redacted_columns: redacted_columns,
                                    redacted_key_values: redacted_key_values)
  end
  let(:executor) do
    Woods::Console::EmbeddedExecutor.new(
      model_validator: Woods::Console::ModelValidator.new(
        registry: { 'Preference' => %w[id name value], 'User' => %w[id name secret status] },
        table_names: { 'Preference' => 'preferences', 'User' => 'users' }
      ), safe_context: context, connection: connection, read_tools_enabled: true
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
    returning(['id'])
  end

  def returning(columns)
    types = columns.to_h { |column| [column, double(type: :string)] }
    allow(connection).to receive(:select_all)
      .and_return(double(columns: columns, rows: [Array.new(columns.size, 'fixture')], column_types: types))
  end

  def request(sql, **params)
    executor.send_request('tool' => 'sql', 'params' => { 'sql' => sql, **params.transform_keys(&:to_s) })
  end

  def expect_refused(result, message)
    expect(result).to include('ok' => false, 'error_type' => 'validation')
    expect(result['error']).to start_with('Rejected:').and include(message)
  end

  %w[PostgreSQL SQLite Mysql2].each do |adapter|
    context "on #{adapter}" do
      before { allow(connection).to receive(:adapter_name).and_return(adapter) }

      describe 'repeated protected result headers' do
        [%w[id secret secret], %w[secret SECRET], %w[name value name value]].each do |headers|
          it "refuses headers #{headers.join(', ')} after execution and before any row is returned" do
            returning(headers)
            expect_refused(request('SELECT * FROM users'), 'protected column more than once')
          end
        end

        it 'keeps one protected header and repeated ordinary headers available' do
          returning(%w[id secret id status status])
          expect(request('SELECT * FROM users')['ok']).to be(true)
        end

        it 'checks the uncapped EXPLAIN path too' do
          returning(%w[secret secret])
          expect_refused(request('EXPLAIN SELECT id FROM users'), 'protected column more than once')
        end

        context 'without a redaction policy' do
          let(:redacted_columns) { [] }
          let(:redacted_key_values) { [] }

          it 'leaves repeated headers alone' do
            returning(%w[secret secret])
            expect(request('SELECT * FROM users')['ok']).to be(true)
          end
        end
      end

      describe 'positional ordinals beside a wildcard projection' do
        quoted = adapter == 'Mysql2' ? 'SELECT `u`.* FROM users `u`' : 'SELECT "u".* FROM users "u"'
        ['SELECT * FROM users', 'SELECT u.* FROM users u', 'SELECT id, * FROM users', quoted,
         'SELECT id, u.* FROM users u'].each do |projection|
          %w[ORDER GROUP].each do |clause|
            it "refuses #{clause} BY ordinals in #{projection}" do
              ['1', '3', '(4)', 'id, 2'].each do |ordinal|
                expect_refused(request("#{projection} #{clause} BY #{ordinal}"), 'wildcard projection')
              end
              expect(connection).not_to have_received(:select_all)
            end
          end
        end

        ['SELECT DISTINCT * FROM users', 'SELECT ALL * FROM users', 'SELECT DISTINCT id, * FROM users',
         'SELECT DISTINCT ON (id) * FROM users', 'SELECT SQL_NO_CACHE * FROM users'].each do |projection|
          it "refuses ordinals after the select modifier in #{projection}" do
            expect_refused(request("#{projection} ORDER BY 3"), 'wildcard projection')
            expect(connection).not_to have_received(:select_all)
          end
        end

        it 'keeps an ordinal over an explicit ordinary column working' do
          expect(request('SELECT id, status FROM users ORDER BY 2')['ok']).to be(true)
          expect(request('SELECT status, count(*) FROM users GROUP BY 1')['ok']).to be(true)
        end

        it 'keeps named ordering beside a wildcard working' do
          expect(request('SELECT * FROM users ORDER BY id')['ok']).to be(true)
        end

        it 'reads a wildcard inside a subquery as that subquery projection only' do
          expect(request('SELECT id FROM (SELECT * FROM users) AS u ORDER BY 1')['ok']).to be(true)
        end

        context 'without a redaction policy' do
          let(:redacted_columns) { [] }
          let(:redacted_key_values) { [] }

          it 'leaves ordinals after an explicit column beside a wildcard alone' do
            expect(request('SELECT id, * FROM users ORDER BY 1')['ok']).to be(true)
          end
        end
      end

      describe 'unterminated block comments' do
        ['SELECT id FROM users /*', 'SELECT id FROM users /* open', 'SELECT id FROM users /* LIMIT 2',
         'SELECT id FROM users LIMIT 2 /* open', 'SELECT id FROM users ORDER BY id DESC /* open',
         'SELECT id FROM users /* closed */ /* open', "SELECT id FROM users /* open\nLIMIT 2"].each do |sql|
          it "refuses #{sql.inspect} before the row cap is appended" do
            [{}, { limit: 5 }].each do |params|
              expect_refused(request(sql, **params), 'unterminated block comment')
            end
            expect(connection).not_to have_received(:select_all)
          end
        end

        it 'keeps closed, line and quoted comment markers working' do
          ['SELECT id FROM users /* closed */', 'SELECT id FROM users -- trailing /*',
           "SELECT '/*' AS marker FROM users"].each do |sql|
            expect(request(sql)['ok']).to be(true), sql
          end
        end
      end
    end
  end

  context 'on SQLite, which renames a repeated derived-table column name:N' do
    before { allow(connection).to receive(:adapter_name).and_return('SQLite') }

    [%w[secret secret:1], %w[id secret:1], %w[SECRET:2], %w[secret:1:2],
     %w[name value name:1 value:1]].each do |headers|
      it "refuses renamed protected headers #{headers.join(', ')}" do
        returning(headers)
        expect_refused(request('SELECT * FROM users'), 'protected column more than once')
      end
    end

    it 'keeps renamed ordinary headers available' do
      returning(%w[id id:1 status:1 secret])
      expect(request('SELECT * FROM users')['ok']).to be(true)
    end
  end

  it 'reads a header with a colon suffix as written on other adapters' do
    allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
    returning(%w[secret secret:1])
    expect(request('SELECT * FROM users')['ok']).to be(true)
  end

  it 'refuses an open comment inside a PostgreSQL nested comment' do
    allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
    expect_refused(request('SELECT id FROM users /* nested /* */'), 'unterminated block comment')
  end

  it 'keeps a closed MySQL executable comment and a quoted marker working' do
    allow(connection).to receive(:adapter_name).and_return('Mysql2')
    expect(request('SELECT /*! 1 + */ 1 AS total')['ok']).to be(true)
    expect(request('SELECT `a/*` FROM users')['ok']).to be(true)
  end

  it 'keeps a double-quoted marker working where double quotes delimit identifiers' do
    allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
    expect(request('SELECT "a/*" FROM users')['ok']).to be(true)
  end
end
