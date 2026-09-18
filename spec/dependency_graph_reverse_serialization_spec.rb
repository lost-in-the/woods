# frozen_string_literal: true

require 'spec_helper'
require 'woods/dependency_graph'
require 'woods/extracted_unit'

RSpec.describe Woods::DependencyGraph, 'published reverse relationships' do
  def unit(identifier, type, edges)
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: nil).tap do |value|
      value.dependencies = edges
    end
  end

  let(:graph) { described_class.new }

  it 'preserves labels, association attributes and typed source collisions without changing reverse' do
    graph.register(unit('reports', :database_view, [{ target: 'User', via: :code_reference }]))
    graph.register(unit('reports', :factory, [{ target: 'User', via: :factory_for }]))
    graph.register(unit('Order', :model, [{ target: 'User', via: :has_many, through: 'memberships',
                                            through_db: 'identity', disable_joins: true }]))
    data = JSON.parse(JSON.generate(graph.to_h))
    expect(data.fetch('reverse')).to eq('User' => %w[Order reports])
    expect(data.fetch('reverse_via').fetch('User')).to contain_exactly(
      { 'source' => 'reports', 'source_type' => 'database_view', 'via' => 'code_reference' },
      { 'source' => 'reports', 'source_type' => 'factory', 'via' => 'factory_for' },
      { 'source' => 'Order', 'source_type' => 'model', 'via' => 'has_many', 'through' => 'memberships',
        'through_db' => 'identity', 'disable_joins' => true }
    )
  end

  it 'keeps multiple labels for one source and target, including unknown legacy relationships' do
    restored = described_class.from_h(nodes: { 'Post' => { type: :model } },
                                      edges: { 'Post' => ['User', { target: 'User', via: :belongs_to },
                                                          { target: 'User', via: :code_reference }] })
    rows = restored.to_h.fetch(:reverse_via).fetch('User')
    expect(rows.map { |row| row[:via] }).to contain_exactly(nil, :belongs_to, :code_reference)
  end

  it 'reconstructs the additive index from forward evidence in old and new snapshots' do
    graph.register(unit('Post', :model, [{ target: 'User', via: :belongs_to }]))
    data = JSON.parse(JSON.generate(graph.to_h))
    expected = data.fetch('reverse_via')
    data.delete('reverse_via')
    expect(JSON.parse(JSON.generate(described_class.from_h(data).to_h)).fetch('reverse_via')).to eq(expected)
    data['reverse_via'] = { 'User' => [{ 'source' => 'Invented', 'via' => 'render' }] }
    expect(JSON.parse(JSON.generate(described_class.from_h(data).to_h)).fetch('reverse_via')).to eq(expected)
  end

  it 'withdraws obsolete relationships during incremental replacement and removal' do
    graph.register(unit('Post', :model, [{ target: 'User', via: :belongs_to }]))
    graph.to_h
    graph.register(unit('Post', :model, [{ target: 'Team', via: :belongs_to }]))
    expect(graph.to_h.fetch(:reverse_via).keys).to eq(['Team'])
    graph.remove('Post', type: :model)
    expect(graph.to_h.fetch(:reverse_via)).to be_empty
  end

  it 'preserves separate associations with the same source, target and relationship' do
    graph.register(unit('Post', :model, [{ target: 'User', via: :has_many, through: 'editors' },
                                         { target: 'User', via: :has_many, through: 'reviewers' }]))
    expect(graph.to_h.fetch(:reverse_via).fetch('User').map { |row| row[:through] })
      .to contain_exactly('editors', 'reviewers')
  end

  it 'sorts target buckets and complete records independently of registration order' do
    units = [unit('Z', :service, [{ target: 'User', via: :render }]),
             unit('A', :model, [{ target: 'Team', via: :belongs_to }, { target: 'User', via: :code_reference }])]
    other = described_class.new
    units.each { |value| graph.register(value) }
    units.reverse_each { |value| other.register(value) }
    expect(JSON.generate(graph.to_h.fetch(:reverse_via))).to eq(JSON.generate(other.to_h.fetch(:reverse_via)))
    expect(graph.to_h.fetch(:reverse_via).keys).to eq(%w[Team User])
  end

  it 'detaches returned reverse records and their strings from the memo and live graph' do
    graph.register(unit('Post', :model, [{ target: 'User', via: :belongs_to, through: 'membership' }]))
    snapshot = graph.to_h.fetch(:reverse_via)
    snapshot.fetch('User').first[:source].replace('Changed')
    snapshot.fetch('User').first[:through].replace('Changed')
    snapshot.fetch('User').clear
    expect(graph.to_h.fetch(:reverse_via).fetch('User')).to eq(
      [{ source: 'Post', source_type: :model, via: :belongs_to, through: 'membership' }]
    )
    expect(graph.dependents_of('User', via: :belongs_to)).to eq(['Post'])
  end
end
