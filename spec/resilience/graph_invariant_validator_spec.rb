# frozen_string_literal: true

require 'spec_helper'
require 'woods/resilience/graph_invariant_validator'

RSpec.describe Woods::Resilience::GraphInvariantValidator do
  let(:graph) do
    {
      'nodes' => {
        'A' => { 'type' => 'model', 'file_path' => 'app/models/a.rb' },
        'B' => { 'type' => 'service', 'file_path' => 'app/services/b.rb' }
      },
      'edges' => { 'A' => [{ 'target' => 'B', 'via' => 'code_reference' }, 'http_api'], 'B' => [] },
      'reverse' => { 'A' => [], 'B' => ['A'], 'http_api' => ['A'] },
      'file_map' => { 'app/models/a.rb' => ['A'], 'app/services/b.rb' => ['B'] },
      'type_index' => { 'model' => ['A'], 'service' => ['B'] }
    }
  end
  let(:entries) do
    [
      { 'identifier' => 'A', 'type' => 'model', 'file_path' => 'app/models/a.rb' },
      { 'identifier' => 'B', 'type' => 'service', 'file_path' => 'app/services/b.rb' }
    ]
  end

  def errors
    described_class.new(graph: graph, index_entries: entries).validate
  end

  it 'accepts legacy string edges, external targets and empty reverse buckets' do
    expect(errors).to eq([])
  end

  it 'accepts legacy scalar file membership without altering either input' do
    graph['file_map'].transform_values!(&:first)
    before = Marshal.dump([graph, entries])

    expect(errors).to eq([])
    expect(Marshal.dump([graph, entries])).to eq(before)
  end

  it 'accepts cycles, recursive edges and multiple relationships on one pair' do
    graph['edges']['B'] = %w[A B]
    graph['edges']['A'] << { 'target' => 'B', 'via' => 'belongs_to' }
    graph['reverse']['A'] = ['B']
    graph['reverse']['B'] << 'B'

    expect(errors).to eq([])
  end

  it 'reports a missing reverse edge to an external target' do
    graph['reverse'].delete('http_api')

    expect(errors).to include('dependency_graph.json reverse["http_api"]: missing "A"')
  end

  it 'reports a forward edge whose source has no node' do
    graph['edges']['Missing'] = ['A']

    expect(errors).to include('dependency_graph.json edges["Missing"]: source has no primary node')
  end

  it 'reports a spurious reverse source' do
    graph['reverse']['B'] << 'Missing'

    expect(errors).to include('dependency_graph.json reverse["B"]: unexpected "Missing"')
  end

  it 'reports missing and incorrect type membership' do
    graph['type_index']['model'] = ['B']

    expect(errors).to include('dependency_graph.json type_index["model"]: missing "A"',
                              'dependency_graph.json type_index["model"]: unexpected "B"')
  end

  it 'reports a unit listed under the wrong file' do
    graph['file_map']['app/models/a.rb'] = ['B']

    expect(errors).to include('dependency_graph.json file_map["app/models/a.rb"]: missing "A"',
                              'dependency_graph.json file_map["app/models/a.rb"]: unexpected "B"')
  end

  it 'reports a missing typed indexed unit without calling every external target corrupt' do
    entries << { 'identifier' => 'C', 'type' => 'model' }

    expect(errors).to eq(['dependency_graph.json nodes: missing indexed unit model:C'])
  end

  it 'reports a graph node absent from the unit indexes' do
    entries.pop

    expect(errors).to eq(['dependency_graph.json unit indexes: graph node service:B is not indexed'])
  end

  it 'reports disagreement between the graph and unit index source path' do
    entries.first['file_path'] = 'app/models/other.rb'

    expect(errors).to include('dependency_graph.json unit indexes: file_path differs for model:A')
  end

  context 'typed variants' do
    before do
      graph['variants'] =
        [{ 'identifier' => 'A', 'type' => 'factory', 'file_path' => 'spec/a.rb', 'edges' => ['http_api'] }]
      graph['type_index']['factory'] = ['A']
      graph['file_map']['spec/a.rb'] = ['A']
      entries << { 'identifier' => 'A', 'type' => 'factory', 'file_path' => 'spec/a.rb' }
    end

    it 'unions bare reverse membership across distinct typed sources' do
      expect(errors).to eq([])
    end

    it 'validates variant-only reverse contributions' do
      graph['variants'].first['edges'] << 'external_variant'

      expect(errors).to include('dependency_graph.json reverse["external_variant"]: missing "A"')
    end

    it 'rejects duplicate variants and primary/variant typed collisions' do
      graph['variants'] << graph['variants'].first.dup
      graph['variants'] << { 'identifier' => 'A', 'type' => 'model', 'edges' => [] }

      expect(errors).to include('dependency_graph.json variants[1]: duplicate typed node factory:A',
                                'dependency_graph.json variants[2]: duplicate typed node model:A')
    end

    it 'requires a primary record for each variant identifier' do
      graph['variants'].first['identifier'] = 'Missing'

      expect(errors).to include('dependency_graph.json variants[0]: missing primary node for "Missing"')
    end
  end

  it 'accepts nil source paths' do
    graph['nodes']['B']['file_path'] = nil
    entries.last['file_path'] = nil
    graph['file_map'].delete('app/services/b.rb')

    expect(errors).to eq([])
  end

  it 'unions file membership when units of different types share a file' do
    graph['nodes'].each_value { |node| node['file_path'] = 'app/shared.rb' }
    entries.each { |entry| entry['file_path'] = 'app/shared.rb' }
    graph['file_map'] = { 'app/shared.rb' => %w[A B] }

    expect(errors).to eq([])
  end

  it 'rejects duplicate typed per-directory index entries' do
    entries << entries.first.dup

    expect(errors).to include('dependency_graph.json unit indexes: duplicate typed entry model:A')
  end

  it 'accepts optional relationship attributes without requiring unknown ones' do
    graph['edges']['A'].first.merge!('through' => 'memberships', 'through_db' => 'analytics',
                                     'disable_joins' => false, 'future_attribute' => { 'value' => 1 })

    expect(errors).to eq([])
  end

  it 'rejects malformed known relationship attributes' do
    graph['edges']['A'].first.merge!('through' => 1, 'through_db' => [], 'disable_joins' => 'false')

    expect(errors).to include('dependency_graph.json edges["A"][0]: through must be a string or null',
                              'dependency_graph.json edges["A"][0]: through_db must be a string or null',
                              'dependency_graph.json edges["A"][0]: disable_joins must be a boolean or null')
  end

  it 'reports malformed variant records without losing valid primary records' do
    graph['variants'] = [nil, { 'identifier' => 'A', 'type' => [] }]

    expect(errors).to include('dependency_graph.json variants[0]: expected an object',
                              'dependency_graph.json variants[1]: ' \
                              'expected a nonempty identifier and an object with a nonempty type')
  end

  %w[nodes edges reverse file_map type_index].each do |section|
    it "reports malformed #{section} rather than crashing" do
      graph[section] = []

      expect(errors).to include("dependency_graph.json #{section}: expected an object")
    end
  end

  it 'reports invalid edge lists, targets and labels' do
    graph['edges']['B'] = nil
    graph['edges']['A'] = [false, { 'target' => 'B', 'via' => [] }]

    expect(errors).to include('dependency_graph.json edges["B"]: expected an array',
                              'dependency_graph.json edges["A"][0]: ' \
                              'expected a target identifier or an object with a target identifier',
                              'dependency_graph.json edges["A"][1]: via must be a string or null')
  end

  context 'with the additive reverse relationship index' do
    before do
      graph['reverse_via'] = {
        'B' => [{ 'source' => 'A', 'source_type' => 'model', 'via' => 'code_reference' }],
        'http_api' => [{ 'source' => 'A', 'source_type' => 'model', 'via' => nil }]
      }
    end

    it 'accepts explicit legacy unknown relationships and typed source records' do
      expect(errors).to eq([])
    end

    it 'detects a missing record even when the old reverse membership is correct' do
      graph['reverse_via']['http_api'] = []

      expect(errors).to include('dependency_graph.json reverse_via["http_api"]: ' \
                                'relationship records differ from typed forward edges')
    end

    it 'detects duplicated records without collapsing their multiplicity' do
      graph['reverse_via']['B'] *= 2

      expect(errors).to include('dependency_graph.json reverse_via["B"]: ' \
                                'relationship records differ from typed forward edges')
    end

    it 'requires typed variants and association attributes in the derived records' do
      graph['variants'] = [{ 'identifier' => 'A', 'type' => 'factory', 'file_path' => nil,
                             'edges' => [{ 'target' => 'B', 'via' => 'factory_for', 'through' => 'setup' }] }]
      graph['type_index']['factory'] = ['A']
      entries << { 'identifier' => 'A', 'type' => 'factory', 'file_path' => nil }
      expect(errors).not_to be_empty

      graph['reverse_via']['B'] << { 'source' => 'A', 'source_type' => 'factory', 'via' => 'factory_for',
                                     'through' => 'setup' }
      expect(errors).to eq([])
    end

    it 'reports malformed buckets without crashing' do
      graph['reverse_via']['B'] = [nil]

      expect(errors).to include('dependency_graph.json reverse_via["B"]: ' \
                                'expected a named bucket containing relationship objects')
    end
  end

  it 'accepts an empty graph and empty inventory' do
    empty = %w[nodes edges reverse file_map type_index].to_h { |name| [name, {}] }

    expect(described_class.new(graph: empty, index_entries: []).validate).to eq([])
  end
end
