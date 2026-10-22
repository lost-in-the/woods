# frozen_string_literal: true

require 'spec_helper'
require 'woods/impact/metadata_risks'

RSpec.describe Woods::Impact::MetadataRisks do
  def evaluate(before, after, type = 'model')
    described_class.new(type).call(before, after)
  end

  it 'flags captured filter-chain and callback side-effect changes with metadata evidence' do
    before = { 'filters' => [{ 'filter' => 'old' }],
               'callbacks' => [{ 'filter' => 'notify', 'type' => 'after_save', 'kind' => 'after', 'conditions' => {},
                                 'side_effects' => { 'jobs_enqueued' => ['ExampleJob'] } }] }
    after = { 'filters' => [{ 'filter' => 'new' }], 'callbacks' => [] }
    result = evaluate(before, after)
    expect(result['risks'].map { |item| item['kind'] }).to contain_exactly('filter_chain_change',
                                                                           'callback_side_effect_change')
    expect(result['risks']).to all(include('evidence' => include('metadata_key')))
  end

  it 'preserves callback identity when side effects move between same-kind callbacks' do
    first = { 'filter' => 'first', 'type' => 'after_save', 'kind' => 'after', 'conditions' => {},
              'side_effects' => { 'jobs_enqueued' => ['OneJob'] } }
    second = first.merge('filter' => 'second', 'side_effects' => { 'jobs_enqueued' => ['TwoJob'] })
    before = { 'callbacks' => [first, second] }
    after = { 'callbacks' => [first.merge('side_effects' => second['side_effects']),
                              second.merge('side_effects' => first['side_effects'])] }
    expect(evaluate(before, after)['risks']).to include(include('kind' => 'callback_side_effect_change'))
  end

  it 'keeps missing applicable evidence unknown even if both endpoints omit it' do
    expect(evaluate({}, {}, 'model')['unknowns']).to include(include('kind' => 'callback_side_effects_unavailable'))
    expect(evaluate({}, {}, 'controller')['unknowns']).to include(include('kind' => 'filters_unavailable'))
    expect(evaluate({}, {}, 'database_table')['unknowns'])
      .to include(include('kind' => 'foreign_key_evidence_unavailable'))
  end

  it 'only flags no-retry jobs when the published policy explicitly disables retries' do
    expect(evaluate(nil, { 'retry_on' => [] }, 'job')['risks']).to eq([])
    expect(evaluate(nil, { 'retry_on' => [] }, 'job')['unknowns'])
      .to include(include('kind' => 'job_retry_policy_unavailable'))
    result = evaluate(nil, { 'job_type' => 'sidekiq', 'retry_config' => { 'sidekiq_retries' => 'false' } }, 'job')
    expect(result['risks']).to include(include('kind' => 'job_without_retry_touched'))
  end

  it 'retains known flags if later evidence exceeds its budget' do
    budget = Woods::Impact::RiskBudget.new(2)
    before = { 'filters' => ['old'], 'callbacks' => [{ 'side_effects' => {} }] }
    after = { 'filters' => ['new'], 'callbacks' => [] }
    result = described_class.new('controller', budget: budget).call(before, after)
    expect(result['risks']).to include(include('kind' => 'filter_chain_change'))
    expect(result['unknowns']).to include(include('kind' => 'risk_record_budget'))
  end

  it 'does not mistake a known enabled retry policy for a no-retry job' do
    metadata = { 'job_type' => 'sidekiq', 'retry_on' => ['ExampleError'],
                 'retry_config' => { 'sidekiq_retries' => false } }
    expect(evaluate(nil, metadata, 'job')['risks']).to eq([])
  end

  it 'compares complete foreign-key arrays, without interpreting missing metadata as a drop' do
    key = { 'column' => 'example_id', 'to_table' => 'examples' }
    result = evaluate({ 'foreign_keys' => [key] }, { 'foreign_keys' => [] }, 'database_table')
    expect(result['risks']).to include(include('kind' => 'dropped_foreign_key',
                                               'evidence' => include('removed' => [key])))
    expect(evaluate({ 'foreign_keys' => [key] }, {}, 'database_table')['risks']).to eq([])
  end
end
