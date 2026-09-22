# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'yaml'

RSpec.describe 'Console serialized credential policy', :booted_app do
  before do
    require 'active_record'
    require 'woods'
    require 'woods/console/server'
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    @connection = ActiveRecord::Base.connection
    @connection.create_table(:audit_serialized_records) { |table| table.text :settings }
    stub_const('AuditSerializedRecord', Class.new(ActiveRecord::Base))
    coder = Class.new do
      def self.dump(value)
        YAML.dump(value)
      end

      def self.load(value)
        value ? YAML.safe_load(value, permitted_classes: [Symbol], aliases: true) : {}
      end
    end
    if Gem::Version.new(ActiveRecord::VERSION::STRING) >= Gem::Version.new('7.1')
      AuditSerializedRecord.serialize(:settings, coder: coder)
    else
      AuditSerializedRecord.serialize(:settings, coder)
    end
    @secret = "ghp_#{'a' * 36}"
    AuditSerializedRecord.create!(settings: { 'string' => @secret, 'symbol' => @secret.to_sym, 'safe' => :ready })
    Woods.configuration = Woods::Configuration.new
  end

  after { ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base) }

  %i[json markdown].each do |format|
    it "redacts YAML Symbol credentials through the default tools in #{format}" do
      Woods.configuration.context_format = format
      model = AuditSerializedRecord
      server = Woods::Console::Server.build_embedded(
        model_validator: Woods::Console::ModelValidator.new(registry: { model.name => model.column_names }),
        safe_context: Woods::Console::SafeContext.new(connection: @connection), connection: @connection,
        model_tables: { model.name => model.table_name }
      )
      %w[console_sample console_pluck].each do |tool|
        args = { model: model.name }
        args[:columns] = ['settings'] if tool == 'console_pluck'
        request = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: tool, arguments: args } }
        result = JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
        expect(result.fetch('isError')).to be(false)
        expect(result.to_json).not_to include(@secret)
        expect(result.to_json).to include('[REDACTED]', 'ready')
      end
    end
  end
end
