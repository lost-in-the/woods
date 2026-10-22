# frozen_string_literal: true

require 'spec_helper'
require 'woods/impact/related'
require 'woods/impact/propagation'

RSpec.describe Woods::Impact::Related do
  def unit(identifier, type, dependencies: [], metadata: {})
    { 'identifier' => identifier, 'type' => type, 'dependencies' => dependencies, 'metadata' => metadata }
  end

  def inventory(*units)
    units.to_h { |data| [data.values_at('identifier', 'type'), data] }
  end

  def dependency(target, type, via)
    { 'target' => target, 'type' => type, 'via' => via }
  end

  def compute(units, roots, endpoint: 'to', generation: 4, affected: [], budget: nil, **parameters)
    options = Woods::Impact::Options.new(**parameters)
    budget ||= Woods::Impact::GraphBudget.new(options)
    described_class.new(units, endpoint: endpoint, generation: generation, options: options, budget: budget)
                   .call(roots, affected: affected)
  end

  it 'preserves exact qualified table identities and directed published evidence' do
    first = unit('table:primary.widgets', 'database_table',
                 metadata: { 'table_name' => 'widgets', 'database' => 'primary' })
    second = unit('table:archive.widgets', 'database_table',
                  metadata: { 'table_name' => 'widgets', 'database' => 'archive' })
    model = unit('Widget', 'model', dependencies: [dependency(first['identifier'], 'database_table', 'table'),
                                                   dependency(second['identifier'], 'database_table', 'reads_table')])
    data = compute(inventory(first, second, model), [%w[Widget model]])
    expect(data['tables'].map { |item| item.values_at('identifier', 'database', 'endpoint', 'generation') })
      .to eq([['table:archive.widgets', 'archive', 'to', 4], ['table:primary.widgets', 'primary', 'to', 4]])
    evidence = { 'kind' => 'published_relationship', 'source' => model.slice('identifier', 'type'),
                 'target' => first.slice('identifier', 'type'), 'via' => 'table' }
    expect(data['tables'].last['evidence']).to eq([evidence])
  end

  it 'records direct renders but refuses the legacy view hint and malformed false hint' do
    template = unit('view:widgets/show', 'view_template',
                    dependencies: [dependency('view:widgets/_row', 'view_template', 'render')])
    partial = unit('view:widgets/_row', 'view_template')
    references = [dependency(template['identifier'], 'view', 'render'),
                  dependency(partial['identifier'], false, 'render')]
    controller = unit('WidgetsController', 'controller', dependencies: references)
    data = compute(inventory(template, partial, controller),
                   [%w[WidgetsController controller], ['view:widgets/show', 'view_template']])
    expect(data['templates'].map { |item| item['identifier'] }).to eq(%w[view:widgets/_row view:widgets/show])
    expect(data['templates'].first['evidence'].first.dig('source', 'identifier')).to eq(template['identifier'])
    expect(data['unknowns'].count { |item| item['kind'] == 'conflicting_target_type' }).to eq(2)
    expect(data['unknowns']).to include(include('edge' => include('type' => false)))
  end

  it 'keeps test suggestions typed and does not override producer-inferred target hints' do
    model = unit('Widget', 'model')
    matching = unit('spec:widget_spec', 'test_mapping', dependencies: [dependency('Widget', 'model', 'test_coverage')])
    conflicting = unit('spec:widget_service_spec', 'test_mapping',
                       dependencies: [dependency('Widget', 'service', 'test_coverage')])
    data = compute(inventory(model, matching, conflicting),
                   [matching.values_at('identifier', 'type'), conflicting.values_at('identifier', 'type')])
    expect(data['tests'].map { |item| item['identifier'] }).to eq(%w[spec:widget_service_spec spec:widget_spec])
    expect(data['tests'].find { |item| item['identifier'] == matching['identifier'] }['evidence'])
      .to include(include('kind' => 'published_relationship', 'via' => 'test_coverage'))
    expect(data['tests'].first['evidence']).to eq([{ 'kind' => 'selected_unit' }])
    expect(data['unknowns']).to include(include('kind' => 'conflicting_target_type'))
  end

  it 'reports missing and ambiguous targets without conflating typed collisions' do
    model = unit('Widget', 'model',
                 dependencies: [dependency('Shared', nil, 'table'), dependency('Missing', nil, 'table')])
    data = compute(inventory(model, unit('Shared', 'model'), unit('Shared', 'database_table')), [%w[Widget model]])
    expect(data['tables']).to eq([])
    expect(data['unknowns']).to include(include('kind' => 'ambiguous_target'),
                                        include('kind' => 'related_target_unavailable'))
  end

  it 'retains unavailable table metadata as null instead of deriving database or name from identifiers' do
    table = unit('table:primary.widgets', 'database_table')
    data = compute(inventory(table), [table.values_at('identifier', 'type')])
    expect(data['tables'].first).to include('table_name' => nil, 'database' => nil)
    expect(data['unknowns']).to include(include('kind' => 'related_table_metadata_unavailable',
                                                'metadata_keys' => %w[table_name database]))
  end

  it 'applies type and relationship filters to direct related candidates' do
    table = unit('table:widgets', 'database_table')
    model = unit('Widget', 'model', dependencies: [dependency(table['identifier'], 'database_table', 'table')])
    units = inventory(table, model)
    expect(compute(units, [%w[Widget model]], types: ['view_template'])['tables']).to eq([])
    expect(compute(units, [%w[Widget model]], via: ['render'])['tables']).to eq([])
    expect(compute(units, [%w[Widget model]], via: ['table'])['tables'].size).to eq(1)
  end

  it 'shares consumed graph budgets and reuses known witness evidence after exhaustion' do
    target = unit('Widget', 'model')
    test = unit('spec:widget_spec', 'test_mapping', dependencies: [dependency('Widget', 'model', 'test_coverage')])
    units = inventory(target, test)
    options = Woods::Impact::Options.new(max_nodes: 2)
    budget = Woods::Impact::GraphBudget.new(options)
    graph = { 'reverse_via' => { 'Widget' => [{ 'source' => test['identifier'], 'source_type' => 'test_mapping',
                                                'type' => 'model', 'via' => 'test_coverage' }] }, 'pagerank' => {} }
    propagation = Woods::Impact::Propagation.new(graph, units, generation: 4, endpoint: 'to', options: options,
                                                               budget: budget)
                                            .call([%w[Widget model]])
    data = compute(units, [%w[Widget model]], affected: propagation['affected'], budget: budget)
    expect(data['tests'].first).to include('identifier' => test['identifier'], 'endpoint' => 'to', 'generation' => 4)
    expect(data['tests'].first['evidence']).to include(include('kind' => 'published_relationship',
                                                               'via' => 'test_coverage'))
    expect(data['unknowns']).to include(include('kind' => 'node_budget', 'feature' => 'related'))
  end

  it 'reuses template owner witnesses only in their recorded generation' do
    controller = unit('WidgetsController', 'controller')
    template = unit('view:widgets/show', 'view_template')
    context = { 'endpoint' => 'to', 'generation' => 4 }
    edge = { 'source' => template.slice('identifier', 'type'), 'target' => controller.slice('identifier', 'type'),
             'via' => 'view_render' }
    witness = template.slice('identifier', 'type').merge(context).merge(
      'paths' => [context.merge('root' => controller.slice('identifier', 'type'), 'edges' => [edge])]
    )
    units = inventory(controller, template)
    data = compute(units, [], affected: [witness])
    expect(data['templates'].first['evidence']).to eq([edge.merge('kind' => 'published_relationship')])
    witness['paths'].first['generation'] = 3
    data = compute(units, [], affected: [witness])
    expect(data['templates']).to eq([])
    expect(data['unknowns']).to include(include('kind' => 'related_witness_context_unavailable'))
  end

  it 'charges dependency examination before filtering and preserves earlier facts on exhaustion' do
    table = unit('table:widgets', 'database_table')
    model = unit('Widget', 'model', dependencies: [dependency(table['identifier'], 'database_table', 'table'),
                                                   dependency('Missing', 'database_table', 'table')])
    data = compute(inventory(table, model), [%w[Widget model]], max_edges: 1)
    expect(data['tables'].size).to eq(1)
    expect(data['unknowns']).to include(include('kind' => 'edge_budget'))
    expect(data['unknowns']).not_to include(include('kind' => 'related_target_unavailable'))
  end

  it 'keeps explicit partial coverage even when no candidates were observed' do
    data = compute({}, [])
    expect(data).to include('coverage' => 'partial', 'tables' => [], 'templates' => [], 'tests' => [])
    expect(data['unknowns'].map { |item| item['kind'] })
      .to eq(%w[database_access_not_exhaustive render_references_only test_suggestions_only])
  end
end
