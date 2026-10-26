# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/embedded_executor'

RSpec.describe Woods::Console::EmbeddedExecutor, 'console_sql row cap' do
  let(:validator) { Woods::Console::ModelValidator.new(registry: { 'User' => %w[id email] }) }
  let(:connection) { double('Connection') }
  let(:safe_context) { Woods::Console::SafeContext.new(connection: connection) }
  let(:options) { {} }
  let(:executor) do
    described_class.new(model_validator: validator, safe_context: safe_context, connection: connection,
                        read_tools_enabled: true, **options)
  end

  before do
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(connection).to receive(:execute)
    allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
  end

  def result_with(row_count)
    double('ActiveRecord::Result', columns: %w[id], rows: Array.new(row_count) { |i| [i] })
  end

  def run_sql(params)
    executor.send_request({ 'tool' => 'sql', 'params' => { 'sql' => 'SELECT id FROM users' }.merge(params) })
  end

  context 'without a limit' do
    it 'wraps the statement with the default cap plus one lookahead row' do
      allow(connection).to receive(:select_all).and_return(result_with(3))

      response = run_sql({})

      expect(connection).to have_received(:select_all).with(a_string_matching(/\) AS _limited LIMIT 101\z/))
      expect(response['result']['count']).to eq(3)
      expect(response['result']['completeness']).to include('status' => 'complete', 'has_more' => false)
    end

    it 'returns exactly the default cap and reports more rows when the lookahead row arrives' do
      allow(connection).to receive(:select_all).and_return(result_with(101))

      result = run_sql({})['result']

      expect(result['rows'].size).to eq(100)
      expect(result['count']).to eq(100)
      expect(result['completeness']).to include('status' => 'partial', 'reason' => 'result_limit',
                                                'has_more' => true)
    end

    it 'does not report truncation when exactly the cap rows exist' do
      allow(connection).to receive(:select_all).and_return(result_with(100))

      result = run_sql({})['result']

      expect(result['rows'].size).to eq(100)
      expect(result['completeness']).to include('status' => 'complete', 'has_more' => false)
    end
  end

  context 'with an explicit limit' do
    it 'honours a limit below the maximum' do
      allow(connection).to receive(:select_all).and_return(result_with(6))

      result = run_sql({ 'limit' => 5 })['result']

      expect(connection).to have_received(:select_all).with(a_string_matching(/LIMIT 6\z/))
      expect(result['rows'].size).to eq(5)
      expect(result['completeness']['has_more']).to be true
    end

    it 'clamps a limit above the maximum to the maximum' do
      allow(connection).to receive(:select_all).and_return(result_with(1001))

      result = run_sql({ 'limit' => 5_000 })['result']

      expect(connection).to have_received(:select_all).with(a_string_matching(/LIMIT 1001\z/))
      expect(result['rows'].size).to eq(1000)
      expect(result['completeness']['has_more']).to be true
    end
  end

  context 'when the host raises both values' do
    let(:options) { { sql_default_limit: 250, sql_max_limit: 2_000 } }

    it 'applies the raised default' do
      allow(connection).to receive(:select_all).and_return(result_with(251))

      result = run_sql({})['result']

      expect(result['rows'].size).to eq(250)
      expect(result['completeness']['has_more']).to be true
    end

    it 'applies the raised maximum' do
      allow(connection).to receive(:select_all).and_return(result_with(1))

      run_sql({ 'limit' => 2_000 })

      expect(connection).to have_received(:select_all).with(a_string_matching(/LIMIT 2001\z/))
    end
  end

  context 'with EXPLAIN' do
    it 'still rejects an explicit limit' do
      allow(connection).to receive(:select_all)

      response = run_sql({ 'sql' => 'EXPLAIN SELECT id FROM users', 'limit' => 5 })

      expect(response).to include('ok' => false, 'error_type' => 'validation')
      expect(connection).not_to have_received(:select_all)
    end

    it 'runs unwrapped without a cap or completeness report' do
      allow(connection).to receive(:select_all).and_return(result_with(2))

      result = run_sql({ 'sql' => 'EXPLAIN SELECT id FROM users' })['result']

      expect(connection).to have_received(:select_all).with('EXPLAIN SELECT id FROM users')
      expect(result).not_to have_key('completeness')
    end
  end
end

RSpec.describe Woods::Configuration, 'console_sql row cap' do
  subject(:config) { described_class.new }

  it 'defaults to 100 rows with a 1000 row maximum' do
    expect(config.console_sql_default_limit).to eq(100)
    expect(config.console_sql_max_limit).to eq(1_000)
  end
end
