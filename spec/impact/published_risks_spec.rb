# frozen_string_literal: true

require 'spec_helper'
require 'woods/impact/published_risks'

RSpec.describe Woods::Impact::PublishedRisks do
  let(:units) { { %w[Example model] => {}, %w[Other service] => {} } }
  let(:analysis) do
    { 'hubs' => [{ 'identifier' => 'Example', 'type' => 'model', 'dependent_count' => 3 }],
      'bridges' => [], 'cycles' => [%w[Example Other Example]], 'stats' => {},
      'cross_database_edges' => [{ 'from' => 'Example', 'to' => 'Other', 'from_db' => 'one', 'to_db' => 'two' }] }
  end

  it 'adapts retained structural facts with evidence rather than recomputing them' do
    result = described_class.new(analysis, units).call(%w[Example model])
    expect(result['risks'].map { |risk| risk['kind'] }).to eq(%w[hub cycle cross_database])
    expect(result['risks']).to all(include('evidence' => include('artifact' => 'graph_analysis.json')))
  end

  it 'retains a producer-shaped through crossing when both endpoint databases are the same' do
    crossing = { 'from' => 'Example', 'to' => 'Other', 'via' => 'has_many', 'from_db' => 'primary',
                 'to_db' => 'primary', 'through' => 'example_links', 'through_db' => 'secondary',
                 'disable_joins' => false, 'kind' => 'join_through_across_databases' }
    analysis['cross_database_edges'] = [crossing]
    units[%w[Other model]] = units.delete(%w[Other service])
    result = described_class.new(analysis, units).call(%w[Example model])
    expect(result['risks']).to include(include('kind' => 'cross_database',
                                               'evidence' => include('fact' => crossing)))
    expect(result['unknowns']).not_to include(include('kind' => 'cross_database_binding_unavailable'))
  end

  it 'retains a contradictory published type as unknown instead of flagging another actual type' do
    analysis['hubs'].first['type'] = 'service'
    result = described_class.new(analysis, units).call(%w[Example model])
    expect(result['risks']).not_to include(include('kind' => 'hub'))
    expect(result['unknowns']).to include(include('kind' => 'contradictory_analysis_type',
                                                  'published_type' => 'service'))
  end

  it 'does not attribute bare-identifier analysis to one of several actual types' do
    units[%w[Example service]] = {}
    result = described_class.new(analysis, units).call(%w[Example model])
    expect(result['risks']).to eq([])
    expect(result['unknowns']).to include(include('kind' => 'ambiguous_analysis_identity'))
  end

  it 'keeps cycles with colliding intermediate identities unknown instead of claiming a typed cycle' do
    units[%w[Other model]] = {}
    result = described_class.new(analysis, units).call(%w[Example model])
    expect(result['risks']).not_to include(include('kind' => 'cycle'))
    expect(result['unknowns']).to include(include('kind' => 'ambiguous_cycle_binding'))
  end

  it 'retains earlier risk evidence when its shared record budget is exhausted' do
    budget = Woods::Impact::RiskBudget.new(1)
    result = described_class.new(analysis, units, budget: budget).call(%w[Example model])
    expect(result['risks']).to include(include('kind' => 'hub'))
    expect(result['unknowns']).to include(include('kind' => 'risk_record_budget'))
  end
end
