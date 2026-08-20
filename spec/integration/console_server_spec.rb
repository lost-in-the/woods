# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require 'woods/console/server'
require 'woods/console/embedded_executor'

RSpec.describe 'Console MCP Server Safety Stack', :integration do
  let(:config) { { 'mode' => 'direct', 'command' => 'echo test' } }

  describe 'tool registration in embedded mode' do
    let(:registry) { { 'User' => %w[id email name] } }
    let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }
    let(:safe_context) { Woods::Console::SafeContext.new(connection: nil) }

    it 'registers exactly EXECUTABLE_MODES[:embedded] by default' do
      server = Woods::Console::Server.build_embedded(model_validator: validator, safe_context: safe_context)
      tools = server.instance_variable_get(:@tools)

      expect(tools.keys).to contain_exactly(*Woods::Console::Server::EXECUTABLE_MODES[:embedded])
    end

    it 'registers exactly EXECUTABLE_MODES[:embedded_read] when read tools are enabled' do
      server = Woods::Console::Server.build_embedded(
        model_validator: validator, safe_context: safe_context, read_tools_enabled: true
      )
      tools = server.instance_variable_get(:@tools)

      expect(tools.keys).to contain_exactly(*Woods::Console::Server::EXECUTABLE_MODES[:embedded_read])
    end

    it 'prefixes every registered tool name with console_' do
      server = Woods::Console::Server.build_embedded(
        model_validator: validator, safe_context: safe_context, read_tools_enabled: true
      )
      tools = server.instance_variable_get(:@tools)

      tools.each_key { |name| expect(name).to start_with('console_') }
    end

    it 'never advertises inventory-only Tier 2, Tier 3, or console_eval tools' do
      server = Woods::Console::Server.build_embedded(
        model_validator: validator, safe_context: safe_context, read_tools_enabled: true
      )
      tools = server.instance_variable_get(:@tools)

      inventory_only = (
        Woods::Console::Server::TIER2_TOOLS + Woods::Console::Server::TIER3_TOOLS + %w[eval]
      ).map { |name| "console_#{name}" }

      expect(tools.keys & inventory_only).to be_empty
    end

    it 'refuses the legacy JSON-lines bridge with a typed ConfigurationError' do
      expect do
        Woods::Console::Server.build(config: config)
      end.to raise_error(Woods::ConfigurationError, /JSON-lines Console bridge is not supported/)
    end

    it 'raises the typed ConfigurationError even when only woods/console/server is required' do
      gemfile = File.expand_path('../../Gemfile', __dir__)
      script = <<~RUBY
        require 'bundler/setup'
        require 'woods/console/server'
        begin
          Woods::Console::Server.build(config: {})
          puts 'NO_ERROR'
        rescue Woods::ConfigurationError => e
          puts "ConfigurationError:\#{e.message}"
        end
      RUBY
      stdout, stderr, status = Open3.capture3(
        { 'BUNDLE_GEMFILE' => gemfile }, RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e', script
      )

      expect(status).to be_success, stderr
      expect(stdout).to start_with('ConfigurationError:')
      expect(stdout).to include('JSON-lines Console bridge is not supported')
    end
  end

  describe 'SqlValidator → Tier4 sql tool pipeline' do
    let(:validator) { Woods::Console::SqlValidator.new }

    it 'allows SELECT queries through the sql tool' do
      result = Woods::Console::Tools::Tier4.console_sql(
        sql: 'SELECT * FROM users WHERE active = true',
        validator: validator
      )

      expect(result[:tool]).to eq('sql')
      expect(result[:params][:sql]).to include('SELECT')
    end

    it 'allows WITH...SELECT (CTE) queries through the sql tool' do
      sql = <<~SQL.strip
        WITH active_users AS (SELECT * FROM users WHERE active = true)
        SELECT * FROM active_users
      SQL

      result = Woods::Console::Tools::Tier4.console_sql(
        sql: sql, validator: validator
      )

      expect(result[:tool]).to eq('sql')
    end

    it 'rejects DELETE statements before reaching the bridge' do
      expect do
        Woods::Console::Tools::Tier4.console_sql(
          sql: 'DELETE FROM users WHERE id = 1',
          validator: validator
        )
      end.to raise_error(Woods::Console::SqlValidationError, /DELETE/)
    end

    it 'rejects INSERT statements before reaching the bridge' do
      expect do
        Woods::Console::Tools::Tier4.console_sql(
          sql: "INSERT INTO users (name) VALUES ('test')",
          validator: validator
        )
      end.to raise_error(Woods::Console::SqlValidationError, /INSERT/)
    end

    it 'rejects DROP TABLE before reaching the bridge' do
      expect do
        Woods::Console::Tools::Tier4.console_sql(
          sql: 'DROP TABLE users',
          validator: validator
        )
      end.to raise_error(Woods::Console::SqlValidationError, /DROP/)
    end

    it 'rejects multiple statements separated by semicolons' do
      expect do
        Woods::Console::Tools::Tier4.console_sql(
          sql: 'SELECT 1; DROP TABLE users',
          validator: validator
        )
      end.to raise_error(Woods::Console::SqlValidationError)
    end

    it 'rejects dangerous functions like pg_sleep' do
      expect do
        Woods::Console::Tools::Tier4.console_sql(
          sql: 'SELECT pg_sleep(100)',
          validator: validator
        )
      end.to raise_error(Woods::Console::SqlValidationError, /pg_sleep/)
    end

    it 'enforces row limit on SQL queries' do
      result = Woods::Console::Tools::Tier4.console_sql(
        sql: 'SELECT * FROM users', validator: validator, limit: 50
      )

      expect(result[:params][:limit]).to eq(50)
    end

    it 'preserves a limit above MAX_SQL_LIMIT for the executor to reject' do
      result = Woods::Console::Tools::Tier4.console_sql(
        sql: 'SELECT * FROM users', validator: validator, limit: 999_999
      )

      expect(result[:params][:limit]).to eq(999_999)
    end
  end

  describe 'AuditLogger recording' do
    let(:log_dir) { Dir.mktmpdir('audit_test') }
    let(:log_path) { File.join(log_dir, 'console_audit.jsonl') }
    let(:audit_logger) { Woods::Console::AuditLogger.new(path: log_path) }

    after { FileUtils.remove_entry(log_dir) }

    it 'logs a tool invocation and reads it back' do
      audit_logger.log(
        tool: 'console_eval',
        params: { code: '1 + 1' },
        confirmed: true,
        result_summary: '2'
      )

      entries = audit_logger.entries
      expect(entries.size).to eq(1)
      expect(entries.first['tool']).to eq('console_eval')
      expect(entries.first['confirmed']).to be true
      expect(entries.first['timestamp']).to match(/\d{4}-\d{2}-\d{2}/)
    end

    it 'accumulates multiple entries in order' do
      3.times do |i|
        audit_logger.log(
          tool: "console_sql_#{i}",
          params: { sql: "SELECT #{i}" },
          confirmed: true,
          result_summary: i.to_s
        )
      end

      entries = audit_logger.entries
      expect(entries.size).to eq(3)
      expect(entries.map { |e| e['tool'] }).to eq(%w[console_sql_0 console_sql_1 console_sql_2])
    end

    it 'records denied confirmations' do
      audit_logger.log(
        tool: 'console_eval',
        params: { code: 'system("rm -rf /")' },
        confirmed: false,
        result_summary: 'Denied'
      )

      entries = audit_logger.entries
      expect(entries.first['confirmed']).to be false
    end
  end

  describe 'Confirmation flow' do
    it 'auto_approve mode always grants confirmation' do
      confirmation = Woods::Console::Confirmation.new(mode: :auto_approve)

      expect do
        confirmation.request_confirmation(
          tool: 'console_eval', description: 'Execute code', params: { code: '1+1' }
        )
      end.not_to raise_error

      expect(confirmation.history.size).to eq(1)
      expect(confirmation.history.first[:approved]).to be true
    end

    it 'auto_deny mode always raises ConfirmationDeniedError' do
      confirmation = Woods::Console::Confirmation.new(mode: :auto_deny)

      expect do
        confirmation.request_confirmation(
          tool: 'console_eval', description: 'Execute code', params: { code: '1+1' }
        )
      end.to raise_error(Woods::Console::ConfirmationDeniedError)

      expect(confirmation.history.size).to eq(1)
      expect(confirmation.history.first[:approved]).to be false
    end

    it 'callback mode delegates to the callback proc' do
      # Allow sql but deny eval
      callback = ->(req) { req[:tool] != 'console_eval' }
      confirmation = Woods::Console::Confirmation.new(mode: :callback, callback: callback)

      expect do
        confirmation.request_confirmation(
          tool: 'console_sql', description: 'SELECT query', params: {}
        )
      end.not_to raise_error

      expect do
        confirmation.request_confirmation(
          tool: 'console_eval', description: 'Arbitrary code', params: {}
        )
      end.to raise_error(Woods::Console::ConfirmationDeniedError)

      expect(confirmation.history.size).to eq(2)
    end

    it 'raises ArgumentError for invalid mode' do
      expect do
        Woods::Console::Confirmation.new(mode: :invalid)
      end.to raise_error(ArgumentError, /Invalid mode/)
    end

    it 'raises ArgumentError for callback mode without callback' do
      expect do
        Woods::Console::Confirmation.new(mode: :callback)
      end.to raise_error(ArgumentError, /Callback required/)
    end
  end

  describe 'SafeContext column redaction' do
    let(:safe_ctx) do
      Woods::Console::SafeContext.new(
        connection: nil,
        redacted_columns: %w[ssn password_digest api_key]
      )
    end

    it 'redacts specified columns in a single record' do
      record = {
        'id' => 1,
        'name' => 'Alice',
        'ssn' => '123-45-6789',
        'password_digest' => '$2a$12$abc',
        'email' => 'alice@example.com'
      }

      redacted = safe_ctx.redact(record)

      expect(redacted['id']).to eq(1)
      expect(redacted['name']).to eq('Alice')
      expect(redacted['email']).to eq('alice@example.com')
      expect(redacted['ssn']).to eq('[REDACTED]')
      expect(redacted['password_digest']).to eq('[REDACTED]')
    end

    it 'redacts across an array of records via Server.apply_redaction' do
      records = [
        { 'id' => 1, 'api_key' => 'sk_live_abc', 'name' => 'Alice' },
        { 'id' => 2, 'api_key' => 'sk_live_xyz', 'name' => 'Bob' }
      ]

      redacted = Woods::Console::Server.send(:apply_redaction, records, safe_ctx)

      expect(redacted.map { |r| r['api_key'] }).to all(eq('[REDACTED]'))
      expect(redacted.map { |r| r['name'] }).to eq(%w[Alice Bob])
    end

    it 'passes through non-Hash values unchanged' do
      expect(Woods::Console::Server.send(:apply_redaction, 42, safe_ctx)).to eq(42)
      expect(Woods::Console::Server.send(:apply_redaction, 'hello', safe_ctx)).to eq('hello')
    end

    it 'handles empty redacted_columns list (no redaction)' do
      no_redact = Woods::Console::SafeContext.new(connection: nil, redacted_columns: [])
      record = { 'ssn' => '123-45-6789' }

      expect(no_redact.redact(record)).to eq(record)
    end
  end

  describe 'Confirmation → AuditLogger → SqlValidator composed safety stack' do
    let(:log_dir) { Dir.mktmpdir('safety_stack_test') }
    let(:log_path) { File.join(log_dir, 'audit.jsonl') }
    let(:audit_logger) { Woods::Console::AuditLogger.new(path: log_path) }
    let(:validator) { Woods::Console::SqlValidator.new }
    let(:confirmation) { Woods::Console::Confirmation.new(mode: :auto_approve) }

    after { FileUtils.remove_entry(log_dir) }

    it 'allows a valid SQL through the full safety stack' do
      sql = 'SELECT count(*) FROM orders WHERE status = \'active\''

      # Step 1: Confirmation
      expect do
        confirmation.request_confirmation(
          tool: 'console_sql', description: sql, params: { sql: sql }
        )
      end.not_to raise_error

      # Step 2: SQL Validation
      expect(validator.valid?(sql)).to be true

      # Step 3: Build bridge request
      request = Woods::Console::Tools::Tier4.console_sql(
        sql: sql, validator: validator
      )
      expect(request[:tool]).to eq('sql')

      # Step 4: Audit log
      audit_logger.log(
        tool: 'console_sql',
        params: { sql: sql },
        confirmed: true,
        result_summary: 'count: 42'
      )

      entries = audit_logger.entries
      expect(entries.size).to eq(1)
      expect(entries.first['confirmed']).to be true
    end

    it 'blocks a dangerous SQL and logs the denial' do
      sql = 'DROP TABLE users'

      # Step 1: Confirmation (passes — it's the validator that catches this)
      expect do
        confirmation.request_confirmation(
          tool: 'console_sql', description: sql, params: { sql: sql }
        )
      end.not_to raise_error

      # Step 2: SQL Validation blocks it
      expect(validator.valid?(sql)).to be false
      expect do
        Woods::Console::Tools::Tier4.console_sql(sql: sql, validator: validator)
      end.to raise_error(Woods::Console::SqlValidationError)

      # Step 3: Log the denial
      audit_logger.log(
        tool: 'console_sql',
        params: { sql: sql },
        confirmed: true,
        result_summary: 'BLOCKED: SqlValidationError'
      )

      entries = audit_logger.entries
      expect(entries.first['result_summary']).to include('BLOCKED')
    end

    it 'blocks eval when confirmation is denied and logs it' do
      deny_confirmation = Woods::Console::Confirmation.new(mode: :auto_deny)

      expect do
        deny_confirmation.request_confirmation(
          tool: 'console_eval',
          description: 'system("rm -rf /")',
          params: { code: 'system("rm -rf /")' }
        )
      end.to raise_error(Woods::Console::ConfirmationDeniedError)

      audit_logger.log(
        tool: 'console_eval',
        params: { code: 'system("rm -rf /")' },
        confirmed: false,
        result_summary: 'DENIED: ConfirmationDeniedError'
      )

      entries = audit_logger.entries
      expect(entries.first['confirmed']).to be false
      expect(entries.first['result_summary']).to include('DENIED')
    end
  end

  describe 'Server tool dispatch through the embedded executor' do
    let(:registry) { { 'User' => %w[id email name secret_field] } }
    let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }
    let(:connection) { double('Connection') }
    let(:safe_context) { Woods::Console::SafeContext.new(connection: connection) }
    let(:user_model) { class_double('User') }

    before do
      allow(connection).to receive(:transaction) do |&block|
        block.call
      rescue ActiveRecord::Rollback
        nil
      end
      allow(connection).to receive(:execute)
      allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
      stub_const('User', user_model)
    end

    def tools_call(server, name, arguments)
      request = JSON.generate(
        jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: name, arguments: arguments }
      )
      JSON.parse(server.handle_json(request))
    end

    def tool_text(response)
      response.fetch('result').dig('content', 0, 'text')
    end

    def tool_error?(response)
      response.fetch('result').fetch('isError')
    end

    it 'dispatches console_count end to end and renders a concrete count' do
      allow(user_model).to receive(:count).and_return(42)
      server = Woods::Console::Server.build_embedded(
        model_validator: validator, safe_context: safe_context, connection: connection
      )

      response = tools_call(server, 'console_count', { model: 'User' })

      expect(tool_error?(response)).to be false
      expect(tool_text(response)).to eq('**count:** 42')
    end

    it 'redacts a configured column in a dispatched Tier 1 read' do
      record = double('User', attributes: { 'id' => 1, 'secret_field' => 'hidden_value' })
      allow(user_model).to receive(:find_by).with(id: 1).and_return(record)
      server = Woods::Console::Server.build_embedded(
        model_validator: validator, safe_context: safe_context, connection: connection,
        redacted_columns: %w[secret_field]
      )

      response = tools_call(server, 'console_find', { model: 'User', id: 1 })
      text = tool_text(response)

      expect(tool_error?(response)).to be false
      expect(text).to include('[REDACTED]')
      expect(text).not_to include('hidden_value')
    end

    it 'surfaces an unknown-model validation failure as a validation-prefixed error' do
      server = Woods::Console::Server.build_embedded(
        model_validator: validator, safe_context: safe_context, connection: connection
      )

      response = tools_call(server, 'console_count', { model: 'Missing' })

      expect(tool_error?(response)).to be true
      expect(tool_text(response)).to start_with('validation: ')
    end

    it 'sanitizes an execution error to a generic class-and-reason message' do
      allow(user_model).to receive(:count).and_raise(StandardError, 'password_digest leaked here')
      server = Woods::Console::Server.build_embedded(
        model_validator: validator, safe_context: safe_context, connection: connection
      )

      response = tools_call(server, 'console_count', { model: 'User' })
      text = tool_text(response)

      expect(tool_error?(response)).to be true
      expect(text).to eq('execution: StandardError: execution failed (details logged server-side)')
      expect(text).not_to include('password_digest leaked here')
    end
  end

  describe 'declared limit bounds are enforced by dispatch/executor, not by clamping' do
    let(:registry) { { 'User' => %w[id email name] } }
    let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }
    let(:connection) { double('Connection') }
    let(:safe_context) { Woods::Console::SafeContext.new(connection: connection) }

    it 'rejects an out-of-bounds console_sample limit at dispatch with a bounds message' do
      server = Woods::Console::Server.build_embedded(model_validator: validator, safe_context: safe_context)
      tools = server.instance_variable_get(:@tools)

      response = tools.fetch('console_sample').call(model: 'User', limit: 100, server_context: {})

      expect(response.error?).to be true
      expect(response.content.first[:text]).to eq('limit must be between 1 and 25')
    end

    it 'rejects an out-of-bounds console_sql limit at the executor with a validation error' do
      executor = Woods::Console::EmbeddedExecutor.new(
        model_validator: validator, safe_context: safe_context, connection: connection, read_tools_enabled: true
      )

      response = executor.send_request('tool' => 'sql', 'params' => { 'sql' => 'SELECT 1', 'limit' => 50_000 })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to include('10000')
    end

    it 'rejects an out-of-bounds console_query limit at the executor with a validation error' do
      executor = Woods::Console::EmbeddedExecutor.new(
        model_validator: validator, safe_context: safe_context, connection: connection, read_tools_enabled: true
      )

      response = executor.send_request(
        'tool' => 'query', 'params' => { 'model' => 'User', 'select' => ['id'], 'limit' => 50_000 }
      )

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(response['error']).to include('10000')
    end
  end

  describe 'Tier tool request building' do
    it 'Tier1 count builds correct bridge request' do
      request = Woods::Console::Tools::Tier1.console_count(model: 'User', scope: { active: true })

      expect(request).to eq({ tool: 'count', params: { model: 'User', scope: { active: true } } })
    end

    it 'Tier1 sample preserves a limit above 25 for the executor to reject' do
      request = Woods::Console::Tools::Tier1.console_sample(model: 'User', limit: 100)

      expect(request[:params][:limit]).to eq(100)
    end

    it 'Tier4 eval clamps timeout within bounds' do
      result_low = Woods::Console::Tools::Tier4.console_eval(code: 'x', timeout: -5)
      expect(result_low[:params][:timeout]).to eq(1)

      result_high = Woods::Console::Tools::Tier4.console_eval(code: 'x', timeout: 999)
      expect(result_high[:params][:timeout]).to eq(30)
    end

    it 'Tier4 query preserves a limit above MAX_QUERY_LIMIT for the executor to reject' do
      result = Woods::Console::Tools::Tier4.console_query(
        model: 'User', select: %w[id name], limit: 999_999
      )

      expect(result[:params][:limit]).to eq(999_999)
    end
  end
end
