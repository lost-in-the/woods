# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'pathname'
require_relative '../../../script/typesafe/graph_evidence'

RSpec.describe WoodsDevelopment::TypeSafe::GraphEvidence do
  let(:root) { '/explicit/source' }
  let(:data) { { 'nodes' => {}, 'file_map' => {} } }
  let(:adapter) { described_class.new(data) }
  let(:invalid_evidence) { WoodsDevelopment::TypeSafe::InvalidEvidence }

  def add_node(identifier, type, path, edges: [])
    data.fetch('nodes')[identifier] = { 'type' => type, 'file_path' => path, 'namespace' => nil }
    (data['edges'] ||= {})[identifier] = edges
    (data.fetch('file_map')[path] ||= []) << identifier
  end

  def rows(path)
    adapter.for_path(path, root: root)
  end

  it 'preserves typed collisions at different paths with each type owning its own edges' do
    add_node('reports', 'database_view', 'db/views/reports.sql', edges: ['Report'])
    data['variants'] = [{ 'identifier' => 'reports', 'type' => 'factory',
                          'file_path' => 'spec/factories/reports.rb', 'namespace' => nil,
                          'edges' => [{ 'target' => 'FactorySupport', 'via' => 'calls' }] }]
    data.fetch('file_map')['spec/factories/reports.rb'] = ['reports']

    expect(rows('db/views/reports.sql').map { |row| row.values_at('identifier', 'type', 'edges') })
      .to eq([['reports', 'database_view', [{ 'target' => 'Report', 'via' => nil }]]])
    expect(rows('spec/factories/reports.rb').map { |row| row.values_at('identifier', 'type', 'edges') })
      .to eq([['reports', 'factory', [{ 'target' => 'FactorySupport', 'via' => 'calls' }]]])
  end

  it 'returns every typed unit at one path in deterministic identifier and type order' do
    add_node('Zebra', 'model', 'app/models/shared.rb')
    add_node('reports', 'factory', 'app/models/shared.rb')
    data['variants'] = [{ 'identifier' => 'reports', 'type' => 'database_view',
                          'file_path' => 'app/models/shared.rb', 'edges' => [] }]

    expect(rows('app/models/shared.rb').map { |row| row.values_at('identifier', 'type') })
      .to eq([%w[Zebra model], %w[reports database_view], %w[reports factory]])
  end

  it 'recovers other registered identifiers omitted by a legacy scalar file map' do
    add_node('First', 'lib', 'lib/shared.rb')
    add_node('Second', 'lib', 'lib/shared.rb')
    data.fetch('file_map')['lib/shared.rb'] = 'First'

    expect(rows('lib/shared.rb').map { |row| row.fetch('identifier') }).to eq(%w[First Second])
  end

  it 'retains the native file-map fallback for a node whose recorded path differs' do
    add_node('Shared', 'lib', 'lib/recorded.rb')
    data.fetch('file_map')['lib/mapped.rb'] = ['Shared']

    expect(rows('lib/mapped.rb').first.fetch('node').fetch('file_path')).to eq('lib/recorded.rb')
  end

  it 'finds valid variants-only identifiers without a primary node or a file map entry' do
    data['variants'] = [{ 'identifier' => 'OnlyVariant', 'type' => 'factory',
                          'file_path' => 'spec/factories/only.rb', 'edges' => ['Helper'] }]

    expect(rows('spec/factories/only.rb').map { |row| row.values_at('identifier', 'type', 'edges') })
      .to eq([['OnlyVariant', 'factory', [{ 'target' => 'Helper', 'via' => nil }]]])
  end

  it 'preserves all native node and edge attributes without inventing target types' do
    edge = { 'target' => 'Account', 'via' => 'association', 'through' => 'membership',
             'through_db' => 'primary', 'disable_joins' => true }
    add_node('User', 'model', 'app/models/user.rb', edges: [edge])
    data.fetch('nodes').fetch('User').merge!('foreign_key_tables' => %w[accounts], 'enforce_dependencies' => false)

    row = rows('app/models/user.rb').first
    expect(row.keys.sort).to eq(%w[edges identifier node type])
    expect(row.fetch('edges')).to eq([edge])
    expect(row.fetch('node')).to include('foreign_key_tables' => ['accounts'], 'enforce_dependencies' => false)
    expect(JSON.parse(JSON.generate(row))).to eq(row)
  end

  it 'returns isolated JSON copies without mutating or freezing the input' do
    add_node('User', 'model', 'app/models/user.rb', edges: [{ 'target' => 'Account', 'via' => 'calls' }])
    data.fetch('nodes').fetch('User')['foreign_key_tables'] = ['accounts']
    before = JSON.generate(data)
    row = rows('app/models/user.rb').first
    row.fetch('node').fetch('foreign_key_tables').first.replace('changed')
    row.fetch('edges').first.fetch('target').replace('changed')

    expect(JSON.generate(data)).to eq(before)
    expect(rows('app/models/user.rb').first.fetch('edges').first.fetch('target')).to eq('Account')
    expect(data).not_to be_frozen
  end

  it 'returns an empty array for an unindexed file' do
    expect(rows('spec/not_indexed_spec.rb')).to eq([])
  end

  it 'matches relative and root-owned absolute graph paths and lookup paths' do
    add_node('Relative', 'lib', 'lib/shared.rb')
    add_node('Absolute', 'lib', '/explicit/source/lib/shared.rb')

    %w[lib/shared.rb /explicit/source/lib/shared.rb].each do |path|
      expect(rows(path).map { |row| row.fetch('identifier') }).to eq(%w[Absolute Relative])
    end
  end

  it 'accepts a Pathname root and does not need to open the source files' do
    add_node('AbsentFile', 'lib', 'lib/absent.rb')

    expect(adapter.for_path('lib/absent.rb', root: Pathname.new('/not/a/real/root')).length).to eq(1)
  end

  it 'does not match basenames, foreign absolute paths, or a sibling prefix' do
    add_node('Foreign', 'lib', '/other/source/lib/shared.rb')
    add_node('Sibling', 'lib', '/explicit/source-copy/lib/shared.rb')
    add_node('OtherDirectory', 'lib', 'nested/lib/shared.rb')

    expect(rows('lib/shared.rb')).to eq([])
    expect(rows('shared.rb')).to eq([])
  end

  ['/other/source/lib/shared.rb', '../lib/shared.rb', 'lib/../shared.rb', '', '/explicit/source'].each do |path|
    it "rejects lookup paths outside the explicit root or with unsafe components: #{path.inspect}" do
      expect { rows(path) }.to raise_error(invalid_evidence)
    end
  end

  [nil, [], {}, { 'nodes' => [] }, { 'nodes' => {}, 'file_map' => [] }].each do |invalid|
    it "rejects malformed basic graph shape: #{invalid.inspect}" do
      expect { described_class.new(invalid) }.to raise_error(invalid_evidence)
    end
  end

  it 'rejects ambient Rails roots rather than silently rebasing graph evidence' do
    stub_const('Rails', Class.new do
      def self.root
        Pathname.new('/ambient/rails')
      end
    end)

    expect { adapter }.to raise_error(invalid_evidence, /standalone/)
  end
end
