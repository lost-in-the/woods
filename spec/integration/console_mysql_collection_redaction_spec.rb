# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'Console pluck against MySQL JSON columns', :live_backends do
  it 'protects complete JSON cells in both output formats' do
    require 'active_record'
    require 'woods'
    require 'woods/console/server'
    ActiveRecord::Base.establish_connection(ENV.fetch('WOODS_MYSQL_URL'))
    connection = ActiveRecord::Base.connection
    connection.create_table(:woods_json_policy, force: true) do |table|
      table.json :backup_codes
      table.json :tags
    end
    stub_const('ConsoleJsonRecord', Class.new(ActiveRecord::Base) { self.table_name = 'woods_json_policy' })
    ConsoleJsonRecord.create!(backup_codes: ['synthetic-private-cell'], tags: ['ordinary-cell'])
    ConsoleJsonRecord.create!(backup_codes: { nested: 'synthetic-private-cell' }, tags: { visible: 'ordinary-cell' })
    ConsoleJsonRecord.create!(backup_codes: nil, tags: nil)
    previous = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    %i[json markdown].each do |format|
      Woods.configuration.context_format = format
      server = Woods::Console::Server.build_embedded(
        connection: connection, safe_context: Woods::Console::SafeContext.new(connection: connection),
        model_validator: Woods::Console::ModelValidator.new(
          registry: { 'ConsoleJsonRecord' => %w[id backup_codes tags] }
        ),
        redacted_columns: ['backup_codes']
      )
      %w[backup_codes tags].each do |column|
        result = JSON.parse(server.handle_json(JSON.generate(
                                                 jsonrpc: '2.0', id: 1, method: 'tools/call', params: {
                                                   name: 'console_pluck',
                                                   arguments: { model: 'ConsoleJsonRecord', columns: [column] }
                                                 }
                                               ))).fetch('result')
        expect(result.fetch('isError')).to be(false), result.inspect
        text = result.to_json
        expect(text).not_to include('synthetic-private-cell')
        expect(text.scan('[REDACTED]').size).to eq(3) if column == 'backup_codes'
        expect(text).to include('ordinary-cell') if column == 'tags'
      end
    end
  ensure
    Woods.configuration = previous if previous
    connection&.drop_table(:woods_json_policy, if_exists: true)
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
  end
end
