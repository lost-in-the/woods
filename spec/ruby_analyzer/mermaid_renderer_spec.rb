# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/ruby_analyzer/mermaid_renderer'

RSpec.describe CodebaseIndex::RubyAnalyzer::MermaidRenderer do
  subject(:renderer) { described_class.new }

  def make_unit(type:, identifier:, file_path: nil, dependencies: [], metadata: {})
    unit = CodebaseIndex::ExtractedUnit.new(
      type: type,
      identifier: identifier,
      file_path: file_path || "/app/#{identifier.underscore}.rb"
    )
    unit.dependencies = dependencies
    unit.metadata = metadata
    unit
  end

  describe '#render_call_graph' do
    it 'returns graph TD header for empty input' do
      expect(renderer.render_call_graph([])).to eq('graph TD')
    end

    it 'returns graph TD header for nil input' do
      expect(renderer.render_call_graph(nil)).to eq('graph TD')
    end

    it 'renders nodes for units' do
      units = [make_unit(type: :ruby_class, identifier: 'User')]
      result = renderer.render_call_graph(units)

      expect(result).to include('graph TD')
      expect(result).to include('User["User"]')
    end

    it 'renders edges for dependencies' do
      units = [
        make_unit(
          type: :ruby_class,
          identifier: 'Order',
          dependencies: [{ type: :ruby_class, target: 'User', via: :association }]
        )
      ]
      result = renderer.render_call_graph(units)

      expect(result).to include('Order -->|association| User')
    end

    it 'renders edges without labels when via is nil' do
      units = [
        make_unit(
          type: :ruby_class,
          identifier: 'Order',
          dependencies: [{ type: :ruby_class, target: 'User' }]
        )
      ]
      result = renderer.render_call_graph(units)

      expect(result).to include('Order --> User')
    end

    it 'deduplicates edges' do
      units = [
        make_unit(
          type: :ruby_class,
          identifier: 'Order',
          dependencies: [
            { type: :ruby_class, target: 'User', via: :association },
            { type: :ruby_class, target: 'User', via: :association }
          ]
        )
      ]
      result = renderer.render_call_graph(units)

      expect(result.scan('Order -->').count).to eq(1)
    end

    it 'sanitizes identifiers with special characters' do
      units = [
        make_unit(
          type: :ruby_class,
          identifier: 'Foo::Bar',
          dependencies: [{ type: :ruby_class, target: 'Baz::Qux' }]
        )
      ]
      result = renderer.render_call_graph(units)

      expect(result).to include('Foo__Bar')
      expect(result).to include('Baz__Qux')
      expect(result).not_to include('Foo::Bar[')
    end

    it 'renders multiple units and their dependencies' do
      units = [
        make_unit(
          type: :ruby_class,
          identifier: 'Order',
          dependencies: [{ type: :ruby_class, target: 'User' }]
        ),
        make_unit(
          type: :ruby_class,
          identifier: 'Invoice',
          dependencies: [{ type: :ruby_class, target: 'Order' }]
        )
      ]
      result = renderer.render_call_graph(units)

      expect(result).to include('Order --> User')
      expect(result).to include('Invoice --> Order')
    end
  end

  describe '#render_dependency_map' do
    it 'returns graph TD header for nil input' do
      expect(renderer.render_dependency_map(nil)).to eq('graph TD')
    end

    it 'returns graph TD header for empty nodes' do
      expect(renderer.render_dependency_map({ nodes: {}, edges: {} })).to eq('graph TD')
    end

    it 'groups nodes into subgraphs by type' do
      graph_data = {
        nodes: {
          'User' => { type: :model },
          'Order' => { type: :model },
          'UsersController' => { type: :controller }
        },
        edges: {}
      }
      result = renderer.render_dependency_map(graph_data)

      expect(result).to include('subgraph model')
      expect(result).to include('subgraph controller')
      expect(result).to include('User["User"]')
      expect(result).to include('UsersController["UsersController"]')
    end

    it 'renders edges between nodes' do
      graph_data = {
        nodes: {
          'UsersController' => { type: :controller },
          'User' => { type: :model }
        },
        edges: {
          'UsersController' => ['User']
        }
      }
      result = renderer.render_dependency_map(graph_data)

      expect(result).to include('UsersController --> User')
    end

    it 'skips edges to nodes not in the graph' do
      graph_data = {
        nodes: {
          'User' => { type: :model }
        },
        edges: {
          'User' => ['NonExistent']
        }
      }
      result = renderer.render_dependency_map(graph_data)

      expect(result).not_to include('NonExistent')
    end

    it 'handles string keys in graph data' do
      graph_data = {
        'nodes' => {
          'User' => { 'type' => 'model' }
        },
        'edges' => {}
      }
      result = renderer.render_dependency_map(graph_data)

      expect(result).to include('User["User"]')
    end
  end

  describe '#render_dataflow' do
    it 'returns flowchart TD header for empty input' do
      expect(renderer.render_dataflow([])).to eq('flowchart TD')
    end

    it 'returns flowchart TD header for nil input' do
      expect(renderer.render_dataflow(nil)).to eq('flowchart TD')
    end

    it 'skips units without data_transformations metadata' do
      units = [make_unit(type: :ruby_class, identifier: 'User')]
      result = renderer.render_dataflow(units)

      expect(result).to eq('flowchart TD')
    end

    it 'renders units with transformation data' do
      units = [
        make_unit(
          type: :ruby_class,
          identifier: 'UserService',
          metadata: {
            data_transformations: [
              { method: 'to_json', category: :serialization, receiver: 'User', line: 5 }
            ]
          }
        )
      ]
      result = renderer.render_dataflow(units)

      expect(result).to include('flowchart TD')
      expect(result).to include('UserService')
      expect(result).to include('User')
      expect(result).to include('serialization: to_json')
    end

    it 'skips transformations without a receiver' do
      units = [
        make_unit(
          type: :ruby_class,
          identifier: 'Foo',
          metadata: {
            data_transformations: [
              { method: 'new', category: :construction, receiver: nil, line: 1 }
            ]
          }
        )
      ]
      result = renderer.render_dataflow(units)

      # Node for Foo is rendered (it has transformations), but no edge
      expect(result).to include('Foo')
      expect(result).not_to include('-->')
    end
  end

  describe '#render_architecture' do
    let(:units) do
      [
        make_unit(
          type: :ruby_class,
          identifier: 'User',
          dependencies: []
        ),
        make_unit(
          type: :ruby_class,
          identifier: 'Order',
          dependencies: [{ type: :ruby_class, target: 'User' }]
        )
      ]
    end

    let(:graph_data) do
      {
        nodes: {
          'User' => { type: :model },
          'Order' => { type: :model }
        },
        edges: {
          'Order' => ['User']
        }
      }
    end

    let(:analysis) do
      {
        orphans: ['Order'],
        dead_ends: ['User'],
        hubs: [{ identifier: 'User', type: :model, dependent_count: 3, dependents: %w[Order Invoice Receipt] }],
        cycles: [],
        bridges: [],
        stats: {
          orphan_count: 1,
          dead_end_count: 1,
          hub_count: 1,
          cycle_count: 0
        }
      }
    end

    it 'returns a markdown document with all sections' do
      result = renderer.render_architecture(units, graph_data, analysis)

      expect(result).to include('# Architecture Overview')
      expect(result).to include('## Call Graph')
      expect(result).to include('## Dependency Map')
      expect(result).to include('## Data Flow')
      expect(result).to include('## Analysis Summary')
    end

    it 'wraps diagrams in mermaid code blocks' do
      result = renderer.render_architecture(units, graph_data, analysis)

      expect(result).to include("```mermaid\ngraph TD")
      expect(result).to include("```mermaid\nflowchart TD")
      expect(result.scan('```mermaid').count).to eq(3)
      expect(result.scan('```').count).to eq(6) # 3 open + 3 close
    end

    it 'includes analysis stats' do
      result = renderer.render_architecture(units, graph_data, analysis)

      expect(result).to include('**Orphans:** 1')
      expect(result).to include('**Dead ends:** 1')
      expect(result).to include('**Hubs:** 1')
      expect(result).to include('**Cycles:** 0')
    end

    it 'includes top hubs' do
      result = renderer.render_architecture(units, graph_data, analysis)

      expect(result).to include('### Top Hubs')
      expect(result).to include('User (3 dependents)')
    end

    it 'includes cycles when present' do
      analysis[:cycles] = [%w[A B A]]
      analysis[:stats][:cycle_count] = 1
      result = renderer.render_architecture(units, graph_data, analysis)

      expect(result).to include('### Cycles')
      expect(result).to include('A -> B -> A')
    end

    it 'handles nil analysis gracefully' do
      result = renderer.render_architecture(units, graph_data, nil)

      expect(result).to include('## Analysis Summary')
      expect(result).not_to include('**Orphans:**')
    end
  end
end
