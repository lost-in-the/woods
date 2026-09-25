# frozen_string_literal: true

require 'spec_helper'
require 'json'

# The Rails 6 matrix has enums but not Active Record attribute encryption.
# Register encrypted-attribute examples only where that API exists.
if ENV['WOODS_RUN_BOOTED_APP']
  require 'logger'
  require 'active_record'
end

RSpec.describe 'Console typed EAV policy', :booted_app do
  before do
    require 'active_record'
    require 'woods'
    require 'woods/console/server'
    ActiveRecord::Base.establish_connection(ENV.fetch('WOODS_EAV_URL', 'sqlite3::memory:'))
    @connection = ActiveRecord::Base.connection
    @connection.create_table(:typed_preferences, force: true) do |table|
      table.integer :key
      table.string :value
      table.string :target_type
      table.integer :target_id
    end
    @connection.create_table(:other_preferences, force: true) do |table|
      table.string :name
      table.string :value
    end
    stub_const('TypedPreference', Class.new(ActiveRecord::Base) do
      self.table_name = 'typed_preferences'
      if ActiveRecord::VERSION::MAJOR < 7
        enum key: { api_token: 0, visible: 1 }
      else
        enum :key, { api_token: 0, visible: 1 }
      end
      belongs_to :target, polymorphic: true, optional: true
    end)
    stub_const('OtherPreference', Class.new(ActiveRecord::Base) { self.table_name = 'other_preferences' })
    TypedPreference.create!(key: :api_token, value: 'synthetic-private-cell')
    TypedPreference.create!(key: :visible, value: 'ordinary-cell')
    OtherPreference.create!(name: 'private', value: 'synthetic-private-cell')
    @previous = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    Woods.configuration.context_format = :json
  end

  after do
    Woods.configuration = @previous if @previous
    %i[typed_preferences other_preferences encrypted_preferences].each do |table|
      @connection&.drop_table(table, if_exists: true)
    end
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
  end

  def build_server(sensitive, stacked: false)
    models = [TypedPreference, OtherPreference]
    models << EncryptedPreference if defined?(EncryptedPreference)
    tables = models.to_h { |model| [model.name, model.table_name] }
    patterns = [{ key_column: 'key', value_column: 'value', sensitive_keys: [sensitive] }]
    patterns << { key_column: 'name', value_column: 'value', sensitive_keys: ['private'] } if stacked
    Woods::Console::Server.build_embedded(
      connection: @connection, safe_context: Woods::Console::SafeContext.new(connection: @connection),
      model_validator: Woods::Console::ModelValidator.new(
        registry: models.to_h { |model| [model.name, model.column_names] }, table_names: tables
      ), model_tables: tables, read_tools_enabled: true,
      redacted_key_values: patterns
    )
  end

  def request(server, tool, arguments)
    JSON.parse(server.handle_json(JSON.generate(
                                    jsonrpc: '2.0', id: 1, method: 'tools/call',
                                    params: { name: "console_#{tool}", arguments: arguments }
                                  ))).fetch('result')
  end

  %w[api_token 0].each do |spelling|
    context "with #{spelling == '0' ? 'raw' : 'cast'} key configuration" do
      let(:server) { build_server(spelling) }

      %w[find sample recent pluck query sql].each do |tool|
        it "protects typed keys through #{tool}" do
          params = { model: 'TypedPreference', columns: %w[key value] }
          params[:id] = 1 if tool == 'find'
          params[:order_by] = 'id' if tool == 'recent'
          params = { model: 'TypedPreference', select: %w[key value] } if tool == 'query'
          if tool == 'sql'
            columns = %w[key value].map { |column| @connection.quote_column_name(column) }.join(', ')
            params = { sql: "SELECT #{columns} FROM typed_preferences" }
          end
          result = request(server, tool, params)
          expect(result.fetch('isError')).to be(false), result.inspect
          expect(result.to_json).to include('[REDACTED]')
          expect(result.to_json).not_to include('synthetic-private-cell')
        end
      end

      it 'protects typed keys through a schema-qualified source' do
        schema = @connection.adapter_name == 'SQLite' ? 'main' : @connection.current_database
        schema = 'public' if @connection.adapter_name == 'PostgreSQL'
        table = [schema, 'typed_preferences'].map { |name| @connection.quote_table_name(name) }.join('.')
        columns = %w[key value].map { |column| @connection.quote_column_name(column) }.join(', ')
        result = request(server, 'sql', sql: "SELECT #{columns} FROM #{table}")
        expect(result.fetch('isError')).to be(false), result.inspect
        expect(result.to_json).to include('[REDACTED]')
        expect(result.to_json).not_to include('synthetic-private-cell')
      end

      ['TYPED_PREFERENCES', 'Typed_Preferences', 'TYPED_PREFERENCES AS selected'].each do |source|
        it "protects typed keys through case-variant SQL source #{source}" do
          columns = %w[key value].map { |column| @connection.quote_column_name(column) }.join(', ')
          result = request(server, 'sql', sql: "SELECT #{columns} FROM #{source}")
          expect(result.fetch('isError')).to be(false), result.inspect
          expect(result.to_json).to include('[REDACTED]', 'ordinary-cell')
          expect(result.to_json).not_to include('synthetic-private-cell')
        end
      end

      it 'protects typed keys through an unquoted qualified case-variant source' do
        schema = @connection.adapter_name == 'SQLite' ? 'MAIN' : @connection.current_database
        schema = 'PUBLIC' if @connection.adapter_name == 'PostgreSQL'
        columns = %w[key value].map { |column| @connection.quote_column_name(column) }.join(', ')
        result = request(server, 'sql', sql: "SELECT #{columns} FROM #{schema}.TYPED_PREFERENCES")
        expect(result.fetch('isError')).to be(false), result.inspect
        expect(result.to_json).to include('[REDACTED]', 'ordinary-cell')
        expect(result.to_json).not_to include('synthetic-private-cell')
      end

      it 'keeps stacked table-specific patterns independent' do
        result = request(build_server(spelling, stacked: true), 'query', model: 'OtherPreference',
                                                                         select: %w[name value])
        expect(result.fetch('isError')).to be(false), result.inspect
        expect(result.to_json).to include('[REDACTED]')
      end

      it 'continues refusing protected value predicates and ordering' do
        [['find', { by: { value: 'synthetic-private-cell' } }],
         ['count', { scope: { value: 'synthetic-private-cell' } }],
         ['recent', { order_by: 'value' }],
         ['query', { select: %w[key value], group_by: ['value'] }]].each do |tool, params|
          result = request(server, tool, { model: 'TypedPreference', **params })
          expect(result.fetch('isError')).to be(true)
          expect(result.to_json).to include('Rejected:')
        end
      end
    end
  end

  if defined?(ActiveRecord::Encryption)
    context 'with an encrypted key attribute' do
      around do |example|
        require 'active_record'
        config = ActiveRecord::Encryption.config
        attributes = %i[primary_key deterministic_key key_derivation_salt]
        previous = attributes.to_h { |name| [name, config.instance_variable_get("@#{name}")] }
        attributes.each { |name| config.public_send("#{name}=", 'synthetic-encryption-fixture-key') }
        example.run
      ensure
        previous&.each { |name, value| config.public_send("#{name}=", value) }
      end

      before do
        @connection.create_table(:encrypted_preferences, force: true) do |table|
          table.string :key
          table.string :value
        end
        stub_const('EncryptedPreference', Class.new(ActiveRecord::Base) do
          self.table_name = 'encrypted_preferences'
          encrypts :key
        end)
        EncryptedPreference.create!(key: 'api_token', value: 'synthetic-private-cell')
        EncryptedPreference.create!(key: 'visible', value: 'ordinary-cell')
      end

      %w[find sample recent pluck query sql].each do |tool|
        it "protects the encrypted key representation through #{tool}" do
          params = { model: 'EncryptedPreference', columns: %w[key value] }
          params[:id] = 1 if tool == 'find'
          params[:order_by] = 'id' if tool == 'recent'
          params = { model: 'EncryptedPreference', select: %w[key value] } if tool == 'query'
          if tool == 'sql'
            columns = %w[key value].map { |column| @connection.quote_column_name(column) }.join(', ')
            params = { sql: "SELECT #{columns} FROM encrypted_preferences" }
          end
          result = request(build_server('api_token'), tool, params)
          expect(result.fetch('isError')).to be(false), result.inspect
          expect(result.to_json).to include('[REDACTED]')
          expect(result.to_json).not_to include('synthetic-private-cell')
          expect(result.to_json).to include('ordinary-cell') unless tool == 'find'
        end
      end
    end
  end

  it 'counts a missing polymorphic target as zero' do
    result = request(build_server('api_token'), 'association_count', model: 'TypedPreference', id: 1,
                                                                     association: 'target')
    expect(result.fetch('isError')).to be(false), result.inspect
    expect(JSON.parse(result.fetch('content').first.fetch('text'))).to eq('count' => 0)
  end

  it 'refuses a scoped polymorphic count before resolving its target' do
    result = request(build_server('api_token'), 'association_count', model: 'TypedPreference', id: 1,
                                                                     association: 'target', scope: { id: 1 })
    expect(result.fetch('isError')).to be(true)
    expect(result.to_json).to include('polymorphic')
  end
end
