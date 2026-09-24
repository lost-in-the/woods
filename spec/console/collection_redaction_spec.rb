# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'

RSpec.describe 'Console collection-valued pluck redaction', :booted_app do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:host) { File.join(root, 'spec/console/support/booted_console_app.rb') }

  def collection_probe
    <<~RUBY
      require 'woods/console/server'
      ActiveRecord::Schema.define do
        create_table :collection_records do |table|
          table.json :backup_codes
          table.json :tags
        end
      end
      class CollectionRecord < ActiveRecord::Base; end
      CollectionRecord.create!(backup_codes: %w[CODE_A CODE_B CODE_C], tags: %w[public visible])
      CollectionRecord.create!(backup_codes: {'nested' => ['CODE_D']}, tags: {'label' => 'public'})
      CollectionRecord.create!(backup_codes: [], tags: [])
      CollectionRecord.create!(backup_codes: nil, tags: nil)
      registry = {'CollectionRecord' => CollectionRecord.column_names}
      tables = {'CollectionRecord' => CollectionRecord.table_name}
      responses = %i[json markdown].to_h do |format|
        Woods.configuration.context_format = format
        server = Woods::Console::Server.build_embedded(
          model_validator: Woods::Console::ModelValidator.new(registry: registry),
          safe_context: Woods::Console::SafeContext.new(pool: ActiveRecord::Base.connection_pool),
          redacted_columns: Woods.configuration.console_redacted_columns,
          model_tables: tables
        )
        results = [%w[backup_codes], %w[tags], %w[id backup_codes]].map do |columns|
          request = {jsonrpc: '2.0', id: 1, method: 'tools/call', params: {
            name: 'console_pluck', arguments: {model: 'CollectionRecord', columns: columns}
          }}
          JSON.parse(server.handle_json(JSON.generate(request)))
        end
        [format, results]
      end
      puts JSON.generate(raw: CollectionRecord.pluck(:backup_codes), responses: responses)
    RUBY
  end

  it 'masks entire protected JSON cells through real dispatch in JSON and Markdown' do
    Dir.mktmpdir('woods-console-collections') do |directory|
      env = {
        'RAILS_ENV' => 'test', 'WOODS_DUMMY_DB' => File.join(directory, 'console.sqlite3'),
        'WOODS_TEST_CONSOLE_HTTP' => '0', 'WOODS_TEST_CONSOLE_MANUAL_MOUNT' => '0',
        'WOODS_CONSOLE_READ_TOOLS' => '0'
      }
      out, err, status = Open3.capture3(env, RbConfig.ruby, '-Ilib', '-r', host, '-e', collection_probe, chdir: root)

      expect(status).to be_success, err
      result = JSON.parse(out)
      expect(result['raw']).to eq([%w[CODE_A CODE_B CODE_C], { 'nested' => ['CODE_D'] }, [], nil])
      result.fetch('responses').each_value do |responses|
        expect(responses.map { |response| response.dig('result', 'isError') }).to all(be(false))
        expect(responses.to_json).not_to match(/CODE_[A-D]/)
        expect(responses[0].dig('result', 'content', 0, 'text').scan('[REDACTED]').length).to eq(4)
        expect(responses[1].dig('result', 'content', 0, 'text')).to include('public', 'visible')
      end
      json_responses = result.dig('responses', 'json')
      expect(JSON.parse(json_responses[0].dig('result', 'content', 0, 'text'))['values'])
        .to eq(Array.new(4, '[REDACTED]'))
      expect(JSON.parse(json_responses[1].dig('result', 'content', 0, 'text'))['values'])
        .to eq([%w[public visible], { 'label' => 'public' }, [], nil])
      expect(JSON.parse(json_responses[2].dig('result', 'content', 0, 'text'))['values'])
        .to eq((1..4).map { |id| [id, '[REDACTED]'] })
    end
  end
end
