# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/embedded_executor'

RSpec.describe Woods::Console::EmbeddedExecutor do
  let(:registry) do
    {
      'User' => %w[id email name created_at updated_at],
      'Post' => %w[id title body user_id created_at]
    }
  end
  let(:validator) { Woods::Console::ModelValidator.new(registry: registry) }
  let(:connection) { instance_double('Connection') }
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
      it 'points Tier 2+ tools at the bridge architecture' do
        response = executor.send_request({ 'tool' => 'diagnose_model', 'params' => { 'model' => 'User' } })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('unsupported')
        expect(response['error']).to include('diagnose_model')
        expect(response['error']).to include('bridge architecture')
        expect(response['error']).to include('docs/CONSOLE_MCP_SETUP.md')
      end

      it 'returns an instructional eval_disabled payload instead of a bare unsupported error' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'User.count' } })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('eval_disabled')
      end

      it 'eval error explains why eval is disabled and names the query alternatives' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'User.count' } })

        error = response['error']
        expect(error).to include('console_eval')
        expect(error).to include('disabled')
        expect(error).to include('console_query')
        expect(error).to include('console_sql')
      end

      it 'eval error instructs the agent to surface its proposed snippet to the user before retrying' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'User.count' } })

        error = response['error']
        expect(error).to match(/surface|present|show/i)
        expect(error).to match(/first|manual/i)
      end

      it 'eval error points operators at the WOODS_CONSOLE_UNSAFE_EVAL opt-in flag' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'User.count' } })

        expect(response['error']).to include('WOODS_CONSOLE_UNSAFE_EVAL')
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
      let(:pool) { instance_double('ActiveRecord::ConnectionPool') }
      let(:leased_conn) { instance_double('LeasedConnection') }
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
      let(:relation) { instance_double('ActiveRecord::Relation') }

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

      # ── Scope SQL-injection regression tests ──────────────────────
      #
      # Prior to round-5 the array-form scope was splatted directly into
      # AR's `where(*scope)`, which is the `where(raw_sql_string)` arity
      # — turning every Tier-1 scope-accepting tool (count, pluck,
      # aggregate, sample, find, recent) into a boolean exfiltration
      # oracle. These specs lock in the rejection of the known bypass
      # patterns. See `EmbeddedExecutor#validate_scope_array!`.
      describe 'scope array-form SQL injection (R5-F1)' do
        it 'rejects a scope template that contains a SELECT subquery' do
          response = executor.send_request({
                                             'tool' => 'count',
                                             'params' => {
                                               'model' => 'User',
                                               'scope' => ['id IN (SELECT password_digest FROM users)']
                                             }
                                           })

          expect(response['ok']).to be false
          expect(response['error_type']).to eq('validation')
          expect(response['error']).to match(/forbidden SQL keywords/i)
        end

        it 'rejects a scope template that uses UNION' do
          response = executor.send_request({
                                             'tool' => 'count',
                                             'params' => {
                                               'model' => 'User',
                                               'scope' => ['1=1 UNION SELECT 1']
                                             }
                                           })

          expect(response['ok']).to be false
          expect(response['error_type']).to eq('validation')
        end

        it 'rejects a scope template containing `;` (statement chaining)' do
          response = executor.send_request({
                                             'tool' => 'count',
                                             'params' => {
                                               'model' => 'User',
                                               'scope' => ['id = 1; DROP TABLE users']
                                             }
                                           })

          expect(response['ok']).to be false
          expect(response['error_type']).to eq('validation')
          expect(response['error']).to match(/`;`/)
        end

        it 'rejects a scope template containing pg_sleep or BENCHMARK (timing oracles)' do
          response = executor.send_request({
                                             'tool' => 'count',
                                             'params' => {
                                               'model' => 'User',
                                               'scope' => ['pg_sleep(5)']
                                             }
                                           })

          expect(response['ok']).to be false
          expect(response['error_type']).to eq('validation')
        end

        it 'rejects a scope template with mismatched bind count' do
          response = executor.send_request({
                                             'tool' => 'count',
                                             'params' => {
                                               'model' => 'User',
                                               'scope' => ['name = ?'] # zero binds, one placeholder
                                             }
                                           })

          expect(response['ok']).to be false
          expect(response['error_type']).to eq('validation')
          expect(response['error']).to match(/expects 1 bind/)
        end

        it 'rejects a scope where[0] is not a String' do
          response = executor.send_request({
                                             'tool' => 'count',
                                             'params' => {
                                               'model' => 'User',
                                               'scope' => [{ name: 'x' }]
                                             }
                                           })

          expect(response['ok']).to be false
          expect(response['error_type']).to eq('validation')
        end

        it 'allows a parameterised scope template with matching binds' do
          allow(user_model).to receive(:where).with('name = ?', 'Alice').and_return(relation)
          allow(relation).to receive(:count).and_return(2)

          response = executor.send_request({
                                             'tool' => 'count',
                                             'params' => {
                                               'model' => 'User',
                                               'scope' => ['name = ?', 'Alice']
                                             }
                                           })

          expect(response['ok']).to be true
          expect(response['result']['count']).to eq(2)
        end

        it 'allows a no-bind scope template with no forbidden keywords' do
          allow(user_model).to receive(:where).with('id IS NULL').and_return(relation)
          allow(relation).to receive(:count).and_return(0)

          response = executor.send_request({
                                             'tool' => 'count',
                                             'params' => {
                                               'model' => 'User',
                                               'scope' => ['id IS NULL']
                                             }
                                           })

          expect(response['ok']).to be true
        end

        it 'does NOT reject a forbidden keyword that appears only inside a string literal bind' do
          # The template must be scanned with literals stripped — otherwise
          # legitimate searches like name = "SELECT ..." would false-reject.
          allow(user_model).to receive(:where).with("name = 'SELECT'").and_return(relation)
          allow(relation).to receive(:count).and_return(0)

          response = executor.send_request({
                                             'tool' => 'count',
                                             'params' => {
                                               'model' => 'User',
                                               'scope' => ["name = 'SELECT'"]
                                             }
                                           })

          expect(response['ok']).to be true
        end
      end

      it 'returns validation error for missing model param' do
        response = executor.send_request({ 'tool' => 'count', 'params' => {} })

        expect(response['ok']).to be false
        expect(response['error']).to match(/Missing required parameter: model/)
      end
    end

    context 'sample tool' do
      let(:user_model) { class_double('User') }
      let(:ordered) { instance_double('ActiveRecord::Relation', 'ordered') }
      let(:limited) { instance_double('ActiveRecord::Relation', 'limited') }
      let(:record) { instance_double('User', attributes: { 'id' => 1, 'email' => 'a@b.com', 'name' => 'Alice' }) }

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

      it 'caps limit at 25' do
        executor.send_request({
                                'tool' => 'sample',
                                'params' => { 'model' => 'User', 'limit' => 100 }
                              })

        expect(ordered).to have_received(:limit).with(25)
      end
    end

    context 'find tool' do
      let(:user_model) { class_double('User') }
      let(:record) { instance_double('User', attributes: { 'id' => 1, 'email' => 'a@b.com' }) }

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
    end

    context 'pluck tool' do
      let(:user_model) { class_double('User') }
      let(:limited) { instance_double('ActiveRecord::Relation', 'limited') }

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
        distinct_rel = instance_double('ActiveRecord::Relation', 'distinct')
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
        scoped = instance_double('ActiveRecord::Relation')
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
        expect(response['error']).to match(/Invalid aggregate function/)
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
      let(:record) { instance_double('User') }
      let(:assoc_relation) { instance_double('ActiveRecord::Relation') }

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
      end
    end

    context 'schema tool' do
      let(:user_model) { class_double('User') }
      let(:id_col) { instance_double('Column', type: :integer, null: false, default: nil) }
      let(:email_col) { instance_double('Column', type: :string, null: false, default: nil) }

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
        index = instance_double('Index', name: 'idx_email', columns: ['email'], unique: true)
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
      let(:ordered) { instance_double('ActiveRecord::Relation', 'ordered') }
      let(:limited) { instance_double('ActiveRecord::Relation', 'limited') }
      let(:record) { instance_double('Post', attributes: { 'id' => 1, 'title' => 'Hello' }) }

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

      it 'caps limit at 50' do
        executor.send_request({
                                'tool' => 'recent',
                                'params' => { 'model' => 'Post', 'limit' => 200 }
                              })

        expect(ordered).to have_received(:limit).with(50)
      end
    end

    context 'predicate-suffix scope' do
      let(:user_model) { class_double('User') }
      let(:arel_table) { instance_double('Arel::Table') }
      let(:arel_col)   { instance_double('Arel::Attributes::Attribute') }
      let(:arel_node)  { instance_double('Arel::Nodes::GreaterThan') }
      let(:scoped)     { instance_double('ActiveRecord::Relation') }

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

    context 'array-form scope' do
      let(:user_model) { class_double('User') }
      let(:scoped) { instance_double('ActiveRecord::Relation') }

      before do
        stub_const('User', user_model)
      end

      it 'applies array-form scope for JSON column queries' do
        allow(user_model).to receive(:where).with("preferences->>'theme' = ?", 'dark').and_return(scoped)
        allow(scoped).to receive(:count).and_return(7)

        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => {
                                             'model' => 'User',
                                             'scope' => ["preferences->>'theme' = ?", 'dark']
                                           }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['count']).to eq(7)
      end

      it 'ignores empty array scope' do
        allow(user_model).to receive(:count).and_return(42)

        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => { 'model' => 'User', 'scope' => [] }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['count']).to eq(42)
      end

      it 'ignores non-hash non-array scope' do
        allow(user_model).to receive(:count).and_return(42)

        response = executor.send_request({
                                           'tool' => 'count',
                                           'params' => { 'model' => 'User', 'scope' => 'invalid' }
                                         })

        expect(response['ok']).to be true
        expect(response['result']['count']).to eq(42)
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
          instance_double('ActiveRecord::Result', columns: %w[id], rows: [[1], [2]], count: 2)
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

        it 'caps limit at 10000' do
          allow(connection).to receive(:select_all).and_return(select_result)

          executor_with_read.send_request({
                                            'tool' => 'sql',
                                            'params' => { 'sql' => 'SELECT id FROM users', 'limit' => 99_999 }
                                          })

          expect(connection).to have_received(:select_all).with(
            a_string_matching(/LIMIT 10000/)
          )
        end
      end

      context 'query tool' do
        let(:user_model) { class_double('User') }
        let(:relation) { instance_double('ActiveRecord::Relation') }
        let(:query_result) do
          instance_double('ActiveRecord::Result', columns: %w[id email], rows: [[1, 'a@b.com']], count: 1)
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
  end
end
