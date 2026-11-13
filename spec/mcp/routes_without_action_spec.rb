# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods/extracted_unit'
require 'woods/dependency_graph'
require 'woods/graph_analyzer'
require 'woods/mcp/routes_without_action'

RSpec.describe Woods::MCP::RoutesWithoutAction do
  def make_unit(type:, identifier:, dependencies: [], metadata: {})
    unit = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: nil)
    unit.dependencies = dependencies
    unit.metadata = metadata
    unit
  end

  def controller(identifier, actions, parent: nil, **metadata)
    edges = parent ? [{ type: :controller, target: parent, via: :inheritance }] : []
    make_unit(type: :controller, identifier: identifier, dependencies: edges,
              metadata: { actions: actions }.merge(metadata))
  end

  def route(identifier, controller_class, action)
    make_unit(type: :route, identifier: identifier,
              dependencies: [{ type: :controller, target: controller_class, via: :route_dispatch }],
              metadata: { controller: controller_class, action: action })
  end

  def template(identifier, owner)
    make_unit(type: :view_template, identifier: identifier,
              dependencies: [{ type: :controller, target: owner, via: :view_render }])
  end

  # The report as a reader gets it: analyzed, written as JSON, parsed.
  def published_analysis(units)
    graph = Woods::DependencyGraph.new
    units.each { |unit| graph.register(unit) }
    JSON.parse(JSON.generate(Woods::GraphAnalyzer.new(graph).analyze))
  end

  def unit_hash(identifier, metadata)
    { 'type' => 'controller', 'identifier' => identifier, 'metadata' => metadata }
  end

  describe '.actions' do
    # `resources :things` draws seven routes onto a controller with three actions.
    let(:things_routes) do
      { 'index' => 'GET /things', 'create' => 'POST /things', 'new' => 'GET /things/new',
        'edit' => 'GET /things/:id/edit', 'show' => 'GET /things/:id', 'update' => 'PATCH /things/:id',
        'destroy' => 'DELETE /things/:id' }.map { |action, id| route(id, 'ThingsController', action) }
    end

    it 'lists, sorted, the routed actions nothing answers' do
      analysis = published_analysis([controller('ThingsController', %w[create show update]), *things_routes])

      expect(described_class.actions('ThingsController', analysis)).to eq(%w[destroy edit index new])
    end

    it 'leaves out an action the controller defines' do
      analysis = published_analysis([controller('ThingsController', %w[create show update]), *things_routes])

      expect(described_class.actions('ThingsController', analysis)).not_to include('create', 'show', 'update')
    end

    it 'leaves out an action inherited from a parent controller' do
      # The extractor admits a routed inherited method to the child's `actions`.
      analysis = published_analysis([controller('BaseController', []),
                                     controller('ThingsController', %w[create index show update],
                                                parent: 'BaseController'),
                                     *things_routes])

      expect(described_class.actions('ThingsController', analysis)).to eq(%w[destroy edit new])
    end

    it 'leaves out an action a gem-defined body answers' do
      analysis = published_analysis([controller('ThingsController', %w[create show update],
                                                inherited_gem_actions: { 'destroy' => { owner: 'Vault::Base' } }),
                                     *things_routes])

      expect(described_class.actions('ThingsController', analysis)).to eq(%w[edit index new])
    end

    it 'leaves out an action served by an implicit template, its own or an ancestor controller\'s' do
      analysis = published_analysis([controller('BaseController', []),
                                     controller('ThingsController', %w[create show update], parent: 'BaseController'),
                                     template('things/new.html.erb', 'ThingsController'),
                                     template('base/index.html.erb', 'BaseController'),
                                     template('things/_edit.html.erb', 'ThingsController'),
                                     *things_routes])

      expect(described_class.actions('ThingsController', analysis)).to eq(%w[destroy edit])
    end

    it 'lists nothing for a controller that defines action_missing' do
      analysis = published_analysis([controller('ThingsController', %w[show], action_missing: true), *things_routes])

      expect(described_class.actions('ThingsController', analysis)).to eq([])
    end

    it 'lists nothing when every route has an action' do
      actions = %w[create destroy edit index new show update]
      analysis = published_analysis([controller('ThingsController', actions), *things_routes])

      expect(described_class.actions('ThingsController', analysis)).to eq([])
    end

    it 'lists an action once however many routes reach it' do
      analysis = published_analysis([controller('ThingsController', %w[show]),
                                     route('PATCH /things/:id', 'ThingsController', 'update'),
                                     route('PUT /things/:id', 'ThingsController', 'update')])

      expect(described_class.actions('ThingsController', analysis)).to eq(%w[update])
    end

    it 'does not list the routes of another controller, or a route with no controller unit' do
      analysis = published_analysis([controller('ThingsController', %w[show]),
                                     controller('OtherController', []),
                                     route('GET /other', 'OtherController', 'index'),
                                     route('GET /gone', 'GoneController', 'index')])

      expect(described_class.actions('ThingsController', analysis)).to eq([])
      expect(described_class.actions('GoneController', analysis)).to eq([])
    end

    it 'lists nothing when the analysis is missing or predates the report' do
      expect(described_class.actions('ThingsController', nil)).to eq([])
      expect(described_class.actions('ThingsController', {})).to eq([])
      expect(described_class.actions('ThingsController', { 'unresolvable_routes' => 'n/a' })).to eq([])
    end
  end

  describe '.annotate' do
    let(:analysis) do
      { 'unresolvable_routes' => [
        { 'route' => 'DELETE /things/:id', 'controller' => 'ThingsController', 'action' => 'destroy',
          'reason' => 'missing_action' }
      ] }
    end

    it 'adds the key right after routes' do
      unit = unit_hash('ThingsController', 'actions' => %w[show], 'routes' => { 'show' => [], 'destroy' => [] },
                                           'filters' => [])

      metadata = described_class.annotate(unit, analysis)['metadata']

      expect(metadata['routes_without_action']).to eq(%w[destroy])
      expect(metadata.keys).to eq(%w[actions routes routes_without_action filters])
    end

    it 'appends the key when the unit records no routes' do
      unit = unit_hash('ThingsController', 'actions' => %w[show])

      expect(described_class.annotate(unit, analysis)['metadata'].keys).to eq(%w[actions routes_without_action])
    end

    it 'does not mutate the unit it was given' do
      unit = unit_hash('ThingsController', 'actions' => %w[show])

      described_class.annotate(unit, analysis)

      expect(unit['metadata']).to eq('actions' => %w[show])
    end

    it 'returns the same unit, without the key, when every route has an action' do
      unit = unit_hash('ThingsController', 'actions' => %w[show])

      expect(described_class.annotate(unit, { 'unresolvable_routes' => [] })).to equal(unit)
    end

    it 'leaves a unit of another type alone, even one sharing the identifier' do
      unit = unit_hash('ThingsController', {}).merge('type' => 'service')

      expect(described_class.annotate(unit, analysis)).to equal(unit)
    end

    it 'leaves a unit with no metadata alone' do
      unit = { 'type' => 'controller', 'identifier' => 'ThingsController' }

      expect(described_class.annotate(unit, analysis)).to equal(unit)
    end
  end

  describe '.route_label' do
    it 'marks a flagged action and leaves the others as they are' do
      metadata = { 'routes' => {}, 'routes_without_action' => %w[destroy] }

      expect(described_class.route_label(metadata, 'routes', 'destroy')).to eq('destroy (no action)')
      expect(described_class.route_label(metadata, 'routes', 'show')).to eq('show')
      expect(described_class.route_label(metadata, 'action_sources', 'destroy')).to eq('destroy')
      expect(described_class.route_label({}, 'routes', 'destroy')).to eq('destroy')
    end
  end
end
