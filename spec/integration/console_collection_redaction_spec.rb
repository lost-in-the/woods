# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods'

RSpec.describe 'Console pluck against PostgreSQL array columns', :live_backends do
  before do
    require 'active_record'
    require 'woods/console/server'
    ActiveRecord::Base.establish_connection(ENV.fetch('WOODS_PG_URL'))
    @connection = ActiveRecord::Base.connection
    @connection.create_table(:audit_redaction_arrays, force: true) do |table|
      table.string :backup_codes, array: true
      table.string :tags, array: true
    end
    stub_const('ConsoleArrayRecord', Class.new(ActiveRecord::Base))
    ConsoleArrayRecord.table_name = 'audit_redaction_arrays'
    ConsoleArrayRecord.create!(backup_codes: %w[CODE_A CODE_B CODE_C], tags: %w[public visible])
    ConsoleArrayRecord.create!(backup_codes: [], tags: [])
    ConsoleArrayRecord.create!(backup_codes: nil, tags: nil)
    @original_configuration = Woods.configuration
    Woods.configuration = Woods::Configuration.new
  end

  after do
    Woods.configuration = @original_configuration if @original_configuration
    @connection&.drop_table(:audit_redaction_arrays, if_exists: true)
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
  end

  def build_server(format)
    Woods.configuration.context_format = format
    tables = { 'ConsoleArrayRecord' => 'audit_redaction_arrays' }
    Woods::Console::Server.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(
        registry: { 'ConsoleArrayRecord' => ConsoleArrayRecord.column_names }, table_names: tables
      ),
      safe_context: Woods::Console::SafeContext.new(pool: ActiveRecord::Base.connection_pool),
      redacted_columns: Woods.configuration.console_redacted_columns,
      model_tables: tables
    )
  end

  def pluck(server, columns)
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: {
      name: 'console_pluck', arguments: { model: 'ConsoleArrayRecord', columns: columns }
    } }
    response = JSON.parse(server.handle_json(JSON.generate(request)))
    expect(response.dig('result', 'isError')).to be(false)
    response.dig('result', 'content', 0, 'text')
  end

  %i[json markdown].each do |format|
    it "redacts complete PostgreSQL array cells through #{format} dispatch" do
      expect(ConsoleArrayRecord.pluck(:backup_codes)).to eq([%w[CODE_A CODE_B CODE_C], [], nil])
      server = build_server(format)

      protected_text = pluck(server, ['backup_codes'])
      expect(protected_text.scan('[REDACTED]').length).to eq(3)
      expect(protected_text).not_to match(/CODE_[A-C]/)
      expect(pluck(server, ['tags'])).to include('public', 'visible')
      if format == :json
        expect(JSON.parse(protected_text)['values']).to eq(Array.new(3, '[REDACTED]'))
        expect(JSON.parse(pluck(server, %w[id backup_codes]))['values'])
          .to eq((1..3).map { |id| [id, '[REDACTED]'] })
      end
    end
  end
end
