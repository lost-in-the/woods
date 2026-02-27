# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/embedded_executor'

RSpec.describe CodebaseIndex::Console::EmbeddedExecutor do
  let(:registry) do
    {
      'User' => %w[id email name created_at updated_at],
      'Post' => %w[id title body user_id created_at]
    }
  end
  let(:validator) { CodebaseIndex::Console::ModelValidator.new(registry: registry) }
  let(:connection) { instance_double('Connection') }
  let(:safe_context) { CodebaseIndex::Console::SafeContext.new(connection: connection) }

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
      it 'returns unsupported error for Tier 2+ tools' do
        response = executor.send_request({ 'tool' => 'diagnose_model', 'params' => { 'model' => 'User' } })

        expect(response['ok']).to be false
        expect(response['error']).to match(/Not yet implemented in embedded mode/)
        expect(response['error_type']).to eq('unsupported')
      end

      it 'returns unsupported error for eval tool' do
        response = executor.send_request({ 'tool' => 'eval', 'params' => { 'code' => 'puts 1' } })

        expect(response['ok']).to be false
        expect(response['error_type']).to eq('unsupported')
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

    context 'error handling' do
      it 'wraps StandardError as execution errors' do
        allow(connection).to receive(:transaction).and_raise(StandardError, 'DB gone')

        response = executor.send_request({ 'tool' => 'status', 'params' => {} })

        expect(response['ok']).to be false
        expect(response['error']).to eq('DB gone')
        expect(response['error_type']).to eq('execution')
      end
    end
  end
end
