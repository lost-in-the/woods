# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'woods'
require 'woods/console/embedded_executor'

RSpec.describe Woods::Console::EmbeddedExecutor do
  let(:registry) do
    {
      'User' => %w[id email name created_at updated_at],
      'Post' => %w[id title body user_id created_at]
    }
  end
  let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }
  let(:connection) { double('Connection') }
  let(:safe_context) { Woods::Console::SafeContext.new(connection: connection) }

  subject(:executor) do
    described_class.new(model_validator: validator, safe_context: safe_context, connection: connection)
  end

  before do
    # Simulate Rails transaction behavior: suppress ActiveRecord::Rollback
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(connection).to receive(:execute)
    allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
  end

  # Provide Arel.sql stub — the full arel gem may not be loaded in test context
  before do
    unless defined?(Arel)
      stub_const('Arel', Module.new.tap { |m| m.define_singleton_method(:sql) { |raw_sql| raw_sql } })
    end
    Arel.define_singleton_method(:sql) { |raw_sql| raw_sql } unless Arel.respond_to?(:sql)
  end

  describe '#send_request' do
    context 'unsupported tools' do
      it 'states that Tier 2+ tools are unavailable in supported modes' do
        response = executor.send_request({ 'tool' => 'diagnose_model', 'params' => { 'model' => 'User' } })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('unsupported')
        expect(response['error']).to include('diagnose_model')
        expect(response['error']).to include('not available in a supported Console MCP mode')
      end

      it 'returns an instructional eval_disabled payload instead of a bare unsupported error' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'User.count' } })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('eval_disabled')
      end

      it 'eval error explains that eval is unavailable and names the query alternatives' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'User.count' } })

        error = response['error']
        expect(error).to include('console_eval')
        expect(error).to include('not available')
        expect(error).to include('console_query')
        expect(error).to include('console_sql')
      end

      it 'eval error instructs the agent to surface its proposed snippet to the user before retrying' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'User.count' } })

        error = response['error']
        expect(error).to match(/surface|present|show/i)
        expect(error).to match(/first|manual/i)
      end

      it 'eval error states that the legacy unsafe-eval flag fails closed' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'User.count' } })

        expect(response['error']).to include('WOODS_CONSOLE_UNSAFE_EVAL')
        expect(response['error']).to include('fail closed')
      end
    end

    # ── Opt-in path: five-control console_eval wiring ─────────────────────
    #
    # When unsafe_eval_enabled is true, console_eval runs the full
    # guard → confirmation → SafeContext → timeout → audit contract.
    # See backlog B-053 and docs/CONSOLE_MCP_SETUP.md.
    context 'console_eval opt-in path' do
      let(:audit_path) { File.join(Dir.mktmpdir, 'audit.jsonl') }
      let(:audit_logger) { Woods::Console::AuditLogger.new(path: audit_path) }
      let(:eval_guard) { Woods::Console::EvalGuard.new }
      let(:confirmation) { Woods::Console::Confirmation.new(mode: :auto_approve) }

      subject(:executor) do
        described_class.new(
          model_validator: validator, safe_context: safe_context,
          connection: connection,
          eval_guard: eval_guard, confirmation: confirmation,
          audit_logger: audit_logger, unsafe_eval_enabled: true
        )
      end

      def audit_entries
        File.readlines(audit_path).map { |l| JSON.parse(l) }
      rescue Errno::ENOENT
        []
      end

      it 'executes a benign expression and records a confirmed audit entry' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => '1 + 1' } })

        expect(response['ok']).to be true
        expect(response['result']['result']).to eq('2')
        expect(audit_entries.size).to eq(1)
        expect(audit_entries.first['confirmed']).to be true
        expect(audit_entries.first['tool']).to eq('console_eval')
      end

      it 'refuses credential-reaching payloads via EvalGuard and audits the refusal' do
        response = executor.send_request({
                                           'tool' => 'eval',
                                           'params' => { 'code' => 'Rails.application.credentials.stripe' }
                                         })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('validation')
        expect(response['error']).to match(/EvalGuard|denied call chain/i)
        expect(audit_entries.size).to eq(1)
        expect(audit_entries.first['confirmed']).to be false
        expect(audit_entries.first['result_summary']).to match(/guard-refused/)
      end

      it 'refuses when confirmation denies and records a denied audit entry' do
        denied_exec = described_class.new(
          model_validator: validator, safe_context: safe_context, connection: connection,
          eval_guard: eval_guard,
          confirmation: Woods::Console::Confirmation.new(mode: :auto_deny),
          audit_logger: audit_logger, unsafe_eval_enabled: true
        )

        response = denied_exec.send_request({ 'tool' => 'eval', 'params' => { 'code' => '1 + 1' } })

        expect(response['ok']).to be false
        expect(response['error']).to match(/confirmation/i)
        expect(audit_entries.size).to eq(1)
        expect(audit_entries.first['confirmed']).to be false
        expect(audit_entries.first['result_summary']).to match(/denied/)
      end

      it 'times out long-running code and audits the execution error' do
        # Use a stubbed Timeout.timeout to avoid a real sleep in the suite.
        allow(Timeout).to receive(:timeout).and_raise(Timeout::Error, 'execution expired')

        response = executor.send_request({
                                           'tool' => 'eval',
                                           'params' => { 'code' => 'sleep 99', 'timeout' => 1 }
                                         })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('execution')
        expect(audit_entries.size).to eq(1)
        expect(audit_entries.first['confirmed']).to be true
        expect(audit_entries.first['result_summary']).to match(/error:Timeout::Error/)
      end

      it 'rejects an empty payload before reaching the guard' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => '' } })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('validation')
        expect(response['error']).to match(/Missing required parameter: code/)
        # No audit entry — nothing to record yet (we hadn't built audit_params).
        expect(audit_entries).to be_empty
      end

      # Review finding: a payload assigning to executor ivars used to be
      # able to silence the audit log for this run and every subsequent
      # run on the same executor. EvalGuard now refuses the syntactic
      # assignment, and eval_in_sandbox runs in a throwaway receiver so
      # even if the guard is bypassed, the write lands on the throwaway.
      it 'refuses @audit_logger = nil bypass payload at the guard' do
        response = executor.send_request({
                                           'tool' => 'eval',
                                           'params' => { 'code' => '@audit_logger = nil; 1' }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to match(/instance variable/)
        # Audit still writes the refusal — silencing failed.
        expect(audit_entries.size).to eq(1)
        expect(audit_entries.first['confirmed']).to be false

        # And the executor's own @audit_logger is unchanged.
        expect(executor.instance_variable_get(:@audit_logger)).to eq(audit_logger)
      end

      it 'isolates eval from executor instance variables even if the guard missed something' do
        # Bypass EvalGuard's ivar check by constructing the executor
        # without a guard — the sandbox isolation is what we're
        # asserting here, not the guard.
        ungated = described_class.new(
          model_validator: validator, safe_context: safe_context, connection: connection,
          eval_guard: instance_double(Woods::Console::EvalGuard, check!: nil),
          confirmation: confirmation, audit_logger: audit_logger, unsafe_eval_enabled: true
        )

        response = ungated.send_request({
                                          'tool' => 'eval',
                                          'params' => { 'code' => '@audit_logger = nil; 42' }
                                        })

        expect(response['ok']).to be true
        # Audit entry still written — @audit_logger on the throwaway, not the executor.
        expect(audit_entries.size).to eq(1)
        expect(audit_entries.first['confirmed']).to be true
        expect(ungated.instance_variable_get(:@audit_logger)).to eq(audit_logger)
      end

      it 'rejects non-integer timeout values instead of silently clamping to 1' do
        response = executor.send_request({
                                           'tool' => 'eval',
                                           'params' => { 'code' => '1 + 1', 'timeout' => 'forever' }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to eq('timeout must be an integer')
      end

      it 'rejects timeout: 0 instead of silently clamping to 1' do
        response = executor.send_request({
                                           'tool' => 'eval',
                                           'params' => { 'code' => '1 + 1', 'timeout' => 0 }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to eq('timeout must be between 1 and 30')
      end

      it 'rejects a well-formed numeric string for timeout, matching the public schema, ' \
         'instead of silently coercing it' do
        spec = Woods::Console::Server::TOOL_SPECS.find { |s| s.name == 'console_eval' }
        expect { spec.validate_arguments!({ 'code' => '1 + 1', 'timeout' => '15' }) }
          .to raise_error(Woods::Console::InputContract::ValidationError)

        response = executor.send_request({
                                           'tool' => 'eval',
                                           'params' => { 'code' => '1 + 1', 'timeout' => '15' }
                                         })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('validation')
        expect(response['error']).to eq('timeout must be an integer')
        expect(audit_entries).to be_empty
      end

      it 'reduces a complex return value to its class name in the audit summary' do
        # Something that looks like an AR relation — we don't actually
        # need ActiveRecord here, just an object whose #inspect would
        # normally trigger I/O. A class that raises on #inspect proves
        # we never call it.
        fake_relation_class = Class.new do
          def inspect
            raise 'inspect should not be called'
          end

          def self.name
            'FakeRelation'
          end
        end
        complex = fake_relation_class.new

        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => '1 + 1' } })

        # Control: a primitive keeps its inspect form.
        expect(response['result']['result']).to eq('2')

        # Reduction path: the complex object goes through #<ClassName>
        # without calling inspect.
        summary = executor.send(:audit_summary, complex)
        expect(summary).to eq('#<FakeRelation>')
      end

      it 'resolves top-level model constants from within the throwaway sandbox' do
        user_model = class_double('User', count: 42)
        stub_const('User', user_model)

        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'User.count' } })

        expect(response['ok']).to be true
        expect(response['result']['result']).to eq('42')
      end

      # SyntaxError is a ScriptError, not a StandardError — it would
      # otherwise skip every rescue in execute_and_audit / send_request
      # and crash the MCP dispatch loop. eval_in_sandbox translates it
      # to ValidationError.
      it 'turns a Ruby SyntaxError into a validation refusal instead of crashing' do
        # Bypass EvalGuard (whose Prism parser would otherwise catch it)
        # by handing in a guard that no-ops — we're asserting the
        # executor-level defense here.
        noguard = described_class.new(
          model_validator: validator, safe_context: safe_context, connection: connection,
          eval_guard: instance_double(Woods::Console::EvalGuard, check!: nil),
          confirmation: confirmation, audit_logger: audit_logger, unsafe_eval_enabled: true
        )

        # Unclosed string literal — Ruby's parser rejects this even though
        # Prism might handle it differently across versions.
        response = noguard.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'x = "unclosed' } })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('validation')
        expect(response['error']).to match(/could not be parsed by Ruby/)
      end

      it 'confirms with the full (bounded) code, not just the first line' do
        captured = nil
        callback_conf = Woods::Console::Confirmation.new(
          mode: :callback,
          callback: lambda { |req|
            captured = req
            true
          }
        )
        exec = described_class.new(
          model_validator: validator, safe_context: safe_context, connection: connection,
          eval_guard: eval_guard, confirmation: callback_conf,
          audit_logger: audit_logger, unsafe_eval_enabled: true
        )

        multi_line = <<~RUBY.strip
          x = 1
          y = 2
          x + y
        RUBY

        exec.send_request({ 'tool' => 'eval', 'params' => { 'code' => multi_line } })

        expect(captured[:description]).to include('x = 1')
        expect(captured[:description]).to include('y = 2')
        expect(captured[:description]).to include('x + y')
      end
    end

    context 'status tool' do
      it 'returns ok with model list and adapter' do
        response = executor.send_request({ 'tool' => 'status', 'params' => {} })

        expect(response['ok']).to be true
        expect(response['result']['status']).to eq('ok')
        expect(response['result']['models']).to eq(%w[Post User])
        expect(response['result']['adapter']).to eq('PostgreSQL')
        expect(response['timing_ms']).to be_a(Numeric)
      end
    end

    # Regression: ActiveRecord::Base.connection is deprecated in Rails 7.2 and
    # removed in 8.0. Under RackMiddleware, SafeContext leases a fresh
    # connection per request and publishes it via Thread.current — handlers
    # must pick that up rather than re-leasing or calling the deprecated
    # method.
    context 'connection resolution (no injected connection)' do
      let(:pool) { double('ActiveRecord::ConnectionPool') }
      let(:leased_conn) { double('LeasedConnection') }
      let(:ar_base) { class_double('ActiveRecord::Base').as_stubbed_const }
      let(:safe_context) { Woods::Console::SafeContext.new(pool: pool) }

      subject(:executor) do
        described_class.new(model_validator: validator, safe_context: safe_context)
      end

      before do
        allow(ar_base).to receive(:connection_pool).and_return(pool)
        allow(pool).to receive(:with_connection).and_yield(leased_conn)
        allow(leased_conn).to receive(:adapter_name).and_return('PostgreSQL')
        allow(leased_conn).to receive(:execute) # SET LOCAL statement_timeout
        allow(leased_conn).to receive(:transaction) do |&block|
          block.call
        rescue ActiveRecord::Rollback
          nil
        end
      end

      it 'reuses the connection leased by SafeContext for the request' do
        response = executor.send_request({ 'tool' => 'status', 'params' => {} })

        expect(response['ok']).to be true
        expect(response['result']['adapter']).to eq('PostgreSQL')
        expect(pool).to have_received(:with_connection).once
      end

      it 'never invokes the deprecated ActiveRecord::Base.connection' do
        expect(ar_base).not_to receive(:connection)
        executor.send_request({ 'tool' => 'status', 'params' => {} })
      end
    end

    context 'count tool' do
      let(:user_model) { class_double('User') }
      let(:relation) { double('ActiveRecord::Relation') }

      before do
        stub_const('User', user_model)
      end

      it 'returns count for a model without scope' do
        allow(user_model).to receive(:count).and_return(42)

        response = executor.send_request({ 'tool' => 'count', 'params' => { 'model' => 'User' } })

        expect(response['ok']).to be true
        expect(response['result']['count']).to eq(42)
      end

      it 'applies scope conditions' do
        allow(user_model).to receive(:where).with({ 'name' => 'Alice' }).and_return(relation)
        allow(relation).to receive(:count).and_return(3)

        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => { 'model' => 'User', 'scope' => { 'name' => 'Alice' } }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['count']).to eq(3)
      end

      it 'returns validation error for unknown model' do
        response = executor.send_request({ 'tool' => 'count', 'params' => { 'model' => 'Hacker' } })

        expect(response['ok']).to be false
        expect(response['error']).to match(/Unknown model: Hacker/)
        expect(response['error_type']).to eq('validation')
      end

      describe 'scope object contract' do
        array_scopes = [
          ['id IN (SELECT password_digest FROM users)'],
          ['1=1 UNION SELECT 1'],
          ['id = 1; DROP TABLE users'],
          ['pg_sleep(5)'],
          ['name = ?'],
          [{ name: 'x' }],
          ['name = ?', 'Alice'],
          ['id IS NULL'],
          ['id IN (/* hidden */ SELECT password FROM users)'],
          ['id = $$1$$ OR EXISTS (SELECT 1 FROM users)'],
          ["name = 'SELECT'"]
        ]

        array_scopes.each do |scope|
          it "rejects non-advertised array scope #{scope.inspect}" do
            response = executor.send_request({
                                               'tool' => 'count',
                                               'params' => { 'model' => 'User', 'scope' => scope }
                                             })

            expect(response).to include('ok' => false, 'error_type' => 'validation')
            expect(response['error']).to eq('Invalid arguments: value at `/scope` is not an object')
          end
        end
      end

      it 'returns validation error for missing model param' do
        response = executor.send_request({ 'tool' => 'count', 'params' => {} })

        expect(response['ok']).to be false
        expect(response['error']).to eq('Missing required arguments: model')
      end
    end

    context 'sample tool' do
      let(:user_model) { class_double('User') }
      let(:ordered) { double('ordered') }
      let(:limited) { double('limited') }
      let(:record) { double('User', attributes: { 'id' => 1, 'email' => 'a@b.com', 'name' => 'Alice' }) }

      before do
        stub_const('User', user_model)
        allow(user_model).to receive(:order).and_return(ordered)
        allow(ordered).to receive(:limit).and_return(limited)
        allow(limited).to receive(:map).and_yield(record).and_return([record.attributes])
      end

      it 'returns sample records' do
        response = executor.send_request({ 'tool' => 'sample', 'params' => { 'model' => 'User' } })

        expect(response['ok']).to be true
        expect(response['result']['records']).to eq([{ 'id' => 1, 'email' => 'a@b.com', 'name' => 'Alice' }])
      end

      it 'rejects limits above the schema maximum before querying' do
        response = executor.send_request({
                                           'tool' => 'sample',
                                           'params' => { 'model' => 'User', 'limit' => 100 }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to include('Invalid arguments:', 'number at `/limit` is greater than: 25')
        expect(ordered).not_to have_received(:limit)
      end

      it 'rejects malformed integer strings before querying' do
        response = executor.send_request({
                                           'tool' => 'sample',
                                           'params' => { 'model' => 'User', 'limit' => '12junk' }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to include('Invalid arguments:', 'value at `/limit` is not an integer')
        expect(ordered).not_to have_received(:limit)
      end

      it 'rejects columns that are not real model columns (SQL fragment injection)' do
        # relation.select treats string args as raw SQL — a crafted column
        # would smuggle a subquery into the SELECT list.
        response = executor.send_request({
                                           'tool' => 'sample',
                                           'params' => {
                                             'model' => 'User',
                                             'columns' => ['(SELECT secret FROM api_tokens LIMIT 1) AS email']
                                           }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to include('Invalid arguments:', 'string at `/columns/0` does not match pattern')
      end
    end

    context 'find tool' do
      let(:user_model) { class_double('User') }
      let(:record) { double('User', attributes: { 'id' => 1, 'email' => 'a@b.com' }) }

      before do
        stub_const('User', user_model)
      end

      it 'finds by primary key' do
        allow(user_model).to receive(:find_by).with(id: 1).and_return(record)

        response = executor.send_request({
                                           'tool' => 'find',
                                           'params' => { 'model' => 'User', 'id' => 1 }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['record']['id']).to eq(1)
      end

      it 'finds by unique column' do
        allow(user_model).to receive(:find_by).with({ 'email' => 'a@b.com' }).and_return(record)

        response = executor.send_request({
                                           'tool' => 'find',
                                           'params' => { 'model' => 'User', 'by' => { 'email' => 'a@b.com' } }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['record']['email']).to eq('a@b.com')
      end

      it 'returns nil record when not found' do
        allow(user_model).to receive(:find_by).and_return(nil)

        response = executor.send_request({
                                           'tool' => 'find',
                                           'params' => { 'model' => 'User', 'id' => 999 }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['record']).to be_nil
      end

      it 'rejects a request with neither id nor by without calling find_by' do
        # find_by is deliberately left unstubbed: a class_double raises if the
        # production code reaches it, which independently proves find_by was
        # never called.
        response = executor.send_request({
                                           'tool' => 'find',
                                           'params' => { 'model' => 'User' }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
      end

      it 'rejects an empty by hash without returning an arbitrary row' do
        response = executor.send_request({
                                           'tool' => 'find',
                                           'params' => { 'model' => 'User', 'by' => {} }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
      end
    end

    context 'pluck tool' do
      let(:user_model) { class_double('User') }
      let(:limited) { double('limited') }

      before do
        stub_const('User', user_model)
        allow(user_model).to receive(:limit).and_return(limited)
        allow(limited).to receive(:pluck).with(:email).and_return(%w[a@b.com c@d.com])
      end

      it 'plucks column values' do
        response = executor.send_request({
                                           'tool' => 'pluck',
                                           'params' => { 'model' => 'User', 'columns' => ['email'] }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['values']).to eq(%w[a@b.com c@d.com])
      end

      it 'supports distinct option' do
        distinct_rel = double('distinct')
        allow(user_model).to receive(:distinct).and_return(distinct_rel)
        allow(distinct_rel).to receive(:limit).and_return(limited)

        executor.send_request({
                                'tool' => 'pluck',
                                'params' => { 'model' => 'User', 'columns' => ['email'], 'distinct' => true }
                              })

        expect(user_model).to have_received(:distinct)
      end

      it 'validates columns exist' do
        response = executor.send_request({
                                           'tool' => 'pluck',
                                           'params' => { 'model' => 'User', 'columns' => ['bad_col'] }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to match(/Unknown column 'bad_col'/)
      end

      it 'rejects an empty columns list' do
        response = executor.send_request({
                                           'tool' => 'pluck',
                                           'params' => { 'model' => 'User', 'columns' => [] }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to include('Invalid arguments:', 'array size at `/columns` is less than: 1')
      end
    end

    context 'aggregate tool' do
      let(:user_model) { class_double('User') }

      before do
        stub_const('User', user_model)
      end

      it 'runs sum aggregate' do
        allow(user_model).to receive(:sum).with(:id).and_return(100)

        response = executor.send_request({
                                           'tool' => 'aggregate',
                                           'params' => { 'model' => 'User', 'function' => 'sum', 'column' => 'id' }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['value']).to eq(100)
      end

      it 'applies scope to aggregate' do
        scoped = double('ActiveRecord::Relation')
        allow(user_model).to receive(:where).with({ 'name' => 'Alice' }).and_return(scoped)
        allow(scoped).to receive(:average).with(:id).and_return(5.5)

        response = executor.send_request({
                                           'tool' => 'aggregate',
                                           'params' => { 'model' => 'User', 'function' => 'average', 'column' => 'id',
                                                         'scope' => { 'name' => 'Alice' } }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['value']).to eq(5.5)
      end

      it 'runs count aggregate without column' do
        allow(user_model).to receive(:count).with(no_args).and_return(99)

        response = executor.send_request({
                                           'tool' => 'aggregate',
                                           'params' => { 'model' => 'User', 'function' => 'count' }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['value']).to eq(99)
      end

      it 'runs count aggregate with column' do
        allow(user_model).to receive(:count).with(:email).and_return(40)

        response = executor.send_request({
                                           'tool' => 'aggregate',
                                           'params' => { 'model' => 'User', 'function' => 'count',
                                                         'column' => 'email' }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['value']).to eq(40)
      end

      it 'rejects invalid aggregate function' do
        response = executor.send_request({
                                           'tool' => 'aggregate',
                                           'params' => { 'model' => 'User', 'function' => 'delete_all',
                                                         'column' => 'id' }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to include('Invalid arguments:', 'value at `/function` is not one of:')
      end

      it 'rejects a non-count aggregate without a column' do
        response = executor.send_request({
                                           'tool' => 'aggregate',
                                           'params' => { 'model' => 'User', 'function' => 'sum' }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to include(
          'Invalid arguments:', 'object at root is missing required properties: column'
        )
      end

      it 'validates column exists' do
        response = executor.send_request({
                                           'tool' => 'aggregate',
                                           'params' => { 'model' => 'User', 'function' => 'sum',
                                                         'column' => 'nonexistent' }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to match(/Unknown column 'nonexistent'/)
      end
    end

    context 'association_count tool' do
      let(:user_model) { class_double('User') }
      let(:record) { double('User') }
      let(:assoc_relation) { double('ActiveRecord::Relation') }

      before do
        stub_const('User', user_model)
        allow(user_model).to receive(:find).with(1).and_return(record)
        allow(user_model).to receive(:reflect_on_association).with(:posts).and_return(double('reflection'))
        allow(record).to receive(:posts).and_return(assoc_relation)
        allow(assoc_relation).to receive(:count).and_return(5)
      end

      it 'counts associated records' do
        response = executor.send_request({
                                           'tool' => 'association_count',
                                           'params' => { 'model' => 'User', 'id' => 1, 'association' => 'posts' }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['count']).to eq(5)
      end

      it 'validates association exists' do
        allow(user_model).to receive(:reflect_on_association).with(:nonexistent).and_return(nil)

        response = executor.send_request({
                                           'tool' => 'association_count',
                                           'params' => { 'model' => 'User', 'id' => 1, 'association' => 'nonexistent' }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to match(/Unknown association/)
        expect(user_model).not_to have_received(:find)
      end

      it 'rejects an invalid scope column before looking up the parent record' do
        post_model = double('Post', name: 'Post')
        reflection = double('reflection', klass: post_model)
        allow(user_model).to receive(:reflect_on_association).with(:posts).and_return(reflection)

        response = executor.send_request({
                                           'tool' => 'association_count',
                                           'params' => {
                                             'model' => 'User', 'id' => 1, 'association' => 'posts',
                                             'scope' => { 'nonexistent_column' => 1 }
                                           }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to match(/Unknown column 'nonexistent_column'/)
        expect(user_model).not_to have_received(:find)
      end
    end

    context 'association_count tool with a TableGate (defense-in-depth on rendered SQL)' do
      # gate_association! only proves the association's OWN target table
      # isn't blocked. A through-association, default_scope, or custom
      # scope on the association can still render SQL that reaches a
      # blocked table via a less-obvious join — the same class of gap
      # handle_query's own gate_sql!(relation.to_sql) call closes.
      let(:user_model) { class_double('User') }
      let(:record) { double('User record') }
      let(:assoc_relation) { double('AssocRelation') }
      let(:table_gate) do
        Woods::Console::TableGate.new(
          blocked_tables: %w[secrets],
          model_tables: { 'User' => 'users', 'Post' => 'posts' },
          model_reflections: { 'User' => { 'posts' => 'posts' } }
        )
      end

      subject(:executor) do
        described_class.new(model_validator: validator, safe_context: safe_context, connection: connection,
                            table_gate: table_gate)
      end

      before do
        stub_const('User', user_model)
        allow(user_model).to receive(:reflect_on_association).with(:posts).and_return(double('reflection'))
        allow(user_model).to receive(:find).with(1).and_return(record)
        allow(record).to receive(:posts).and_return(assoc_relation)
      end

      it 'refuses when the rendered association SQL reaches a blocked table through a less-obvious join' do
        allow(assoc_relation).to receive(:to_sql)
          .and_return('SELECT posts.* FROM posts INNER JOIN secrets ON secrets.post_id = posts.id')

        response = executor.send_request({
                                           'tool' => 'association_count',
                                           'params' => { 'model' => 'User', 'id' => 1, 'association' => 'posts' }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to match(/secrets/)
      end

      it 'still counts when the rendered SQL only touches allowed tables' do
        allow(assoc_relation).to receive(:to_sql).and_return('SELECT posts.* FROM posts')
        allow(assoc_relation).to receive(:count).and_return(3)

        response = executor.send_request({
                                           'tool' => 'association_count',
                                           'params' => { 'model' => 'User', 'id' => 1, 'association' => 'posts' }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['count']).to eq(3)
      end
    end

    context 'schema tool' do
      let(:user_model) { class_double('User') }
      let(:id_col) { double('Column', type: :integer, null: false, default: nil) }
      let(:email_col) { double('Column', type: :string, null: false, default: nil) }

      before do
        stub_const('User', user_model)
        allow(user_model).to receive(:columns_hash).and_return('id' => id_col, 'email' => email_col)
        allow(user_model).to receive(:table_name).and_return('users')
        allow(user_model).to receive(:connection).and_return(connection)
        allow(connection).to receive(:indexes).with('users').and_return([])
      end

      it 'returns column information' do
        response = executor.send_request({
                                           'tool' => 'schema',
                                           'params' => { 'model' => 'User' }
                                         })

        expect(response['ok']).to be true
        columns = response['result']['columns']
        expect(columns['id']['type']).to eq('integer')
        expect(columns['email']['type']).to eq('string')
      end

      it 'includes indexes when requested' do
        index = double('Index', name: 'idx_email', columns: ['email'], unique: true)
        allow(connection).to receive(:indexes).with('users').and_return([index])

        response = executor.send_request({
                                           'tool' => 'schema',
                                           'params' => { 'model' => 'User', 'include_indexes' => true }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['indexes'].size).to eq(1)
        expect(response['result']['indexes'][0]['name']).to eq('idx_email')
        expect(response['result']['indexes'][0]['unique']).to be true
      end

      it 'validates model exists' do
        response = executor.send_request({
                                           'tool' => 'schema',
                                           'params' => { 'model' => 'Nonexistent' }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to match(/Unknown model/)
      end
    end

    context 'recent tool' do
      let(:post_model) { class_double('Post') }
      let(:ordered) { double('ordered') }
      let(:limited) { double('limited') }
      let(:record) { double('Post', attributes: { 'id' => 1, 'title' => 'Hello' }) }

      before do
        stub_const('Post', post_model)
        allow(post_model).to receive(:order).and_return(ordered)
        allow(ordered).to receive(:limit).and_return(limited)
        allow(limited).to receive(:map).and_yield(record).and_return([record.attributes])
      end

      it 'returns recent records' do
        response = executor.send_request({
                                           'tool' => 'recent',
                                           'params' => { 'model' => 'Post' }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['records']).to eq([{ 'id' => 1, 'title' => 'Hello' }])
      end

      it 'validates order_by column exists' do
        response = executor.send_request({
                                           'tool' => 'recent',
                                           'params' => { 'model' => 'Post', 'order_by' => 'nonexistent' }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to match(/Unknown column 'nonexistent'/)
      end

      it 'rejects an unsupported direction' do
        response = executor.send_request({
                                           'tool' => 'recent',
                                           'params' => { 'model' => 'Post', 'direction' => 'sideways' }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to include('Invalid arguments:', 'value at `/direction` is not one of:')
        expect(post_model).not_to have_received(:order)
      end

      it 'rejects columns that are not real model columns (SQL fragment injection)' do
        response = executor.send_request({
                                           'tool' => 'recent',
                                           'params' => {
                                             'model' => 'Post',
                                             'columns' => ['(SELECT secret FROM api_tokens LIMIT 1) AS title']
                                           }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to include('Invalid arguments:', 'string at `/columns/0` does not match pattern')
      end

      it 'rejects limits above the schema maximum before querying' do
        response = executor.send_request({
                                           'tool' => 'recent',
                                           'params' => { 'model' => 'Post', 'limit' => 200 }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to include('Invalid arguments:', 'number at `/limit` is greater than: 50')
        expect(ordered).not_to have_received(:limit)
      end
    end

    context 'predicate-suffix scope' do
      let(:user_model) { class_double('User') }
      let(:arel_table) { double('Arel::Table') }
      let(:arel_col)   { double('Arel::Attributes::Attribute') }
      let(:arel_node)  { double('Arel::Nodes::GreaterThan') }
      let(:scoped)     { double('ActiveRecord::Relation') }

      before do
        stub_const('User', user_model)
        allow(user_model).to receive(:arel_table).and_return(arel_table)
        allow(arel_table).to receive(:[]).with('id').and_return(arel_col)
        allow(arel_col).to receive(:gt).with(10).and_return(arel_node)
        allow(user_model).to receive(:where).with(arel_node).and_return(scoped)
        allow(scoped).to receive(:count).and_return(5)
      end

      it 'routes predicate-suffix keys through ScopePredicateParser' do
        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => { 'model' => 'User', 'scope' => { 'id_gt' => 10 } }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['count']).to eq(5)
        expect(arel_col).to have_received(:gt).with(10)
      end

      it 'rejects unknown column in predicate suffix' do
        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => { 'model' => 'User', 'scope' => { 'evil_col_gt' => 0 } }
                                         })

        expect(response['ok']).to be false
        expect(response['error']).to match(/Unknown column 'evil_col'/)
        expect(response['error_type']).to eq('validation')
      end
    end

    context 'non-object scope' do
      it 'rejects array-form scope for JSON column queries' do
        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => {
                                             'model' => 'User',
                                             'scope' => ["preferences->>'theme' = ?", 'dark']
                                           }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to eq('Invalid arguments: value at `/scope` is not an object')
      end

      it 'rejects empty array scope' do
        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => { 'model' => 'User', 'scope' => [] }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to eq('Invalid arguments: value at `/scope` is not an object')
      end

      it 'rejects non-hash non-array scope' do
        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => { 'model' => 'User', 'scope' => 'invalid' }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to eq('Invalid arguments: value at `/scope` is not an object')
      end
    end

    context 'error handling' do
      it 'wraps StandardError as execution errors with a sanitized message' do
        # Sanitization: adapter errors can embed column/table names or SQL
        # fragments (schema disclosure). The executor returns a generic
        # "execution failed" message with just the error class for routing
        # and logs the full detail server-side. Audit F-7.
        allow(connection).to receive(:transaction).and_raise(StandardError, 'DB gone')

        response = executor.send_request({ 'tool' => 'status', 'params' => {} })

        expect(response['ok']).to be false
        expect(response['error']).to include('StandardError')
        expect(response['error']).not_to include('DB gone')
        expect(response['error_type']).to eq('execution')
      end
    end

    # ── Read tools (sql/query) gated by read_tools_enabled ──────────

    context 'read tools disabled (default)' do
      it 'points sql at embedded_read_tools and the docs' do
        response = executor.send_request({ 'tool' => 'sql', 'params' => { 'sql' => 'SELECT 1' } })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('unsupported')
        expect(response['error']).to include("'sql'")
        expect(response['error']).to include('embedded_read_tools: true')
        expect(response['error']).to include('docs/CONSOLE_MCP_SETUP.md')
      end

      # RackMiddleware's constructor option and exe/woods-console's
      # (stdio server) config flag are two different names for enabling the
      # same tools — a message naming only one leaves a stdio-server
      # operator with no idea what to set.
      it 'names both the RackMiddleware option and the stdio server config flag' do
        response = executor.send_request({ 'tool' => 'sql', 'params' => { 'sql' => 'SELECT 1' } })

        expect(response['error']).to include('embedded_read_tools: true')
        expect(response['error']).to include('console_embedded_read_tools')
      end

      it 'points query at embedded_read_tools and the docs' do
        response = executor.send_request({
                                           'tool' => 'query',
                                           'params' => { 'model' => 'User', 'select' => ['id'] }
                                         })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('unsupported')
        expect(response['error']).to include("'query'")
        expect(response['error']).to include('embedded_read_tools: true')
      end
    end

    context 'read tools enabled' do
      subject(:executor_with_read) do
        described_class.new(
          model_validator: validator, safe_context: safe_context,
          connection: connection, read_tools_enabled: true
        )
      end

      context 'sql tool' do
        let(:select_result) do
          double('ActiveRecord::Result', columns: %w[id], rows: [[1], [2]], count: 2)
        end

        it 'executes valid SELECT statement' do
          allow(connection).to receive(:select_all).and_return(select_result)

          response = executor_with_read.send_request({
                                                       'tool' => 'sql',
                                                       'params' => { 'sql' => 'SELECT id FROM users' }
                                                     })

          expect(response['ok']).to be true
          expect(response['result']['columns']).to eq(%w[id])
          expect(response['result']['rows']).to eq([[1], [2]])
        end

        it 'rejects DML statements' do
          response = executor_with_read.send_request({
                                                       'tool' => 'sql',
                                                       'params' => { 'sql' => 'DELETE FROM users' }
                                                     })

          expect(response['ok']).to be false
          expect(response['error_type']).to eq('validation')
          expect(response['error']).to match(/DELETE/)
        end

        it 'applies limit when provided' do
          allow(connection).to receive(:select_all).and_return(select_result)

          executor_with_read.send_request({
                                            'tool' => 'sql',
                                            'params' => { 'sql' => 'SELECT id FROM users', 'limit' => 5 }
                                          })

          expect(connection).to have_received(:select_all).with(
            a_string_matching(/LIMIT 5/)
          )
        end

        it 'rejects limits above the schema maximum before querying' do
          allow(connection).to receive(:select_all)

          response = executor_with_read.send_request({
                                                       'tool' => 'sql',
                                                       'params' => {
                                                         'sql' => 'SELECT id FROM users',
                                                         'limit' => 99_999
                                                       }
                                                     })

          expect(response).to include('ok' => false, 'error_type' => 'validation')
          expect(response['error']).to include('Invalid arguments:', 'number at `/limit` is greater than: 10000')
          expect(connection).not_to have_received(:select_all)
        end

        it 'rejects EXPLAIN combined with limit as a typed validation error instead of a broken query' do
          allow(connection).to receive(:select_all)

          response = executor_with_read.send_request({
                                                       'tool' => 'sql',
                                                       'params' => {
                                                         'sql' => 'EXPLAIN SELECT id FROM users',
                                                         'limit' => 5
                                                       }
                                                     })

          expect(response).to include('ok' => false, 'error_type' => 'validation')
          expect(response['error']).to match(/EXPLAIN/)
          expect(connection).not_to have_received(:select_all)
        end

        it 'still executes EXPLAIN without a limit' do
          allow(connection).to receive(:select_all).and_return(select_result)

          response = executor_with_read.send_request({
                                                       'tool' => 'sql',
                                                       'params' => { 'sql' => 'EXPLAIN SELECT id FROM users' }
                                                     })

          expect(response['ok']).to be true
          expect(connection).to have_received(:select_all).with('EXPLAIN SELECT id FROM users')
        end
      end

      context 'query tool' do
        let(:user_model) { class_double('User') }
        let(:relation) { double('ActiveRecord::Relation') }
        let(:query_result) do
          double('ActiveRecord::Result', columns: %w[id email], rows: [[1, 'a@b.com']], count: 1)
        end

        before do
          stub_const('User', user_model)
          allow(user_model).to receive(:all).and_return(relation)
          allow(relation).to receive(:select).and_return(relation)
          allow(relation).to receive(:limit).and_return(relation)
          allow(relation).to receive(:to_sql).and_return('SELECT id, email FROM users LIMIT 10000')
          allow(connection).to receive(:select_all).and_return(query_result)
        end

        it 'builds and executes structured query' do
          response = executor_with_read.send_request({
                                                       'tool' => 'query',
                                                       'params' => { 'model' => 'User', 'select' => %w[id email] }
                                                     })

          expect(response['ok']).to be true
          expect(response['result']['columns']).to eq(%w[id email])
          expect(response['result']['rows']).to eq([[1, 'a@b.com']])
        end

        it 'rejects invalid model' do
          response = executor_with_read.send_request({
                                                       'tool' => 'query',
                                                       'params' => { 'model' => 'Hacker', 'select' => ['id'] }
                                                     })

          expect(response['ok']).to be false
          expect(response['error']).to match(/Unknown model/)
        end
      end
    end

    # SafeContext#redact scrubs a redacted column from serialized output, but
    # accepting the same column as an aggregate target, a scope/filter key, a
    # find locator, or an order_by column reads its plaintext value before
    # redaction ever runs — a comparison/ordering/aggregate oracle over a
    # column the operator explicitly configured as sensitive.
    context 'redacted column oracle guard' do
      let(:user_model) { class_double('User') }
      let(:safe_context) do
        Woods::Console::SafeContext.new(connection: connection, redacted_columns: %w[email])
      end

      subject(:executor) do
        described_class.new(model_validator: validator, safe_context: safe_context, connection: connection)
      end

      before do
        stub_const('User', user_model)
      end

      it 'refuses a redacted column as a console_aggregate column' do
        response = executor.send_request({
                                           'tool' => 'aggregate',
                                           'params' => { 'model' => 'User', 'function' => 'sum', 'column' => 'email' }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to match(/redacted/i)
      end

      it 'refuses a redacted column as a console_find locator key' do
        response = executor.send_request({
                                           'tool' => 'find',
                                           'params' => { 'model' => 'User', 'by' => { 'email' => 'a@b.com' } }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to match(/redacted/i)
      end

      it 'refuses a redacted column as a console_count scope key' do
        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => { 'model' => 'User', 'scope' => { 'email' => 'a@b.com' } }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to match(/redacted/i)
      end

      it 'refuses a redacted column carrying a predicate suffix (e.g. _matches/LIKE) as a scope key' do
        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => { 'model' => 'User', 'scope' => { 'email_matches' => '%a%' } }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to match(/redacted/i)
      end

      it 'refuses a redacted column as a console_sample scope key' do
        response = executor.send_request({
                                           'tool' => 'sample',
                                           'params' => { 'model' => 'User', 'scope' => { 'email' => 'a@b.com' } }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to match(/redacted/i)
      end

      it 'refuses a redacted column as a console_pluck scope key' do
        response = executor.send_request({
                                           'tool' => 'pluck',
                                           'params' => { 'model' => 'User', 'columns' => ['id'],
                                                         'scope' => { 'email' => 'a@b.com' } }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to match(/redacted/i)
      end

      it 'refuses a redacted column as console_recent order_by' do
        response = executor.send_request({
                                           'tool' => 'recent',
                                           'params' => { 'model' => 'User', 'order_by' => 'email' }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to match(/redacted/i)
      end

      it 'refuses a redacted column as a console_recent scope key' do
        response = executor.send_request({
                                           'tool' => 'recent',
                                           'params' => { 'model' => 'User', 'scope' => { 'email' => 'a@b.com' } }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to match(/redacted/i)
      end

      it 'refuses a redacted column as a console_association_count scope key' do
        reflection = double('reflection', klass: user_model)
        allow(user_model).to receive(:reflect_on_association).with(:invitees).and_return(reflection)
        allow(user_model).to receive(:find)

        response = executor.send_request({
                                           'tool' => 'association_count',
                                           'params' => {
                                             'model' => 'User', 'id' => 1, 'association' => 'invitees',
                                             'scope' => { 'email' => 'a@b.com' }
                                           }
                                         })

        expect(response).to include('ok' => false, 'error_type' => 'validation')
        expect(response['error']).to match(/redacted/i)
        expect(user_model).not_to have_received(:find)
      end

      it 'still allows an aggregate on a non-redacted column' do
        allow(user_model).to receive(:sum).with(:id).and_return(7)

        response = executor.send_request({
                                           'tool' => 'aggregate',
                                           'params' => { 'model' => 'User', 'function' => 'sum', 'column' => 'id' }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['value']).to eq(7)
      end
    end
  end
end
