# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Woods::GraphAnalyzer, 'cluster assignment' do
  include_context 'isolated Woods runtime'

  let(:graph) { Woods::DependencyGraph.new }
  let(:analyzer) { described_class.new(graph) }

  def register(identifier, dependencies: [], type: :service)
    unit = Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: "/app/#{identifier}.rb")
    unit.dependencies = dependencies.map do |target, via|
      { target: target, via: via || :code_reference }
    end
    graph.register(unit)
  end

  def cluster_for(identifier, **options)
    analyzer.domain_clusters(min_size: 1, **options).find { |cluster| cluster[:members].include?(identifier) }
  end

  it 'does not probe every unrelated cluster for the same neighbor' do
    register('Target::One')
    32.times { |index| register("Unrelated#{index}::One") }
    register('Root', dependencies: [['Target::One']])

    probes = 0
    allow(analyzer).to receive(:seed_namespace_clusters).and_wrap_original do |original, *arguments|
      original.call(*arguments).tap do |clusters|
        clusters.each_value do |cluster|
          allow(cluster[:member_set]).to receive(:include?).and_wrap_original do |include_member, identifier|
            probes += 1 if identifier == 'Target::One'
            include_member.call(identifier)
          end
        end
      end
    end

    expect(cluster_for('Root')[:name]).to eq('Target')
    # Full clustering also checks membership while enriching boundary edges.
    # This budget permits that work, but no per-cluster adjacency scan.
    expect(probes).to be <= 2
  end

  it 'does not enumerate unused seed members to assign a single root' do
    4.times do |namespace|
      20.times { |member| register("Namespace#{namespace}::Member#{member}") }
    end
    register('Root', dependencies: [['Namespace0::Member0']])

    enumerated = 0
    allow(analyzer).to receive(:seed_namespace_clusters).and_wrap_original do |original, *arguments|
      original.call(*arguments).tap do |clusters|
        clusters.each_value do |cluster|
          members = cluster[:member_set]
          allow(members).to receive(:each).and_wrap_original do |each_member, *args, &block|
            enumerated += members.size
            each_member.call(*args, &block)
          end
        end
      end
    end

    expect(cluster_for('Root')[:name]).to eq('Namespace0')
    expect(enumerated).to eq(0)
  end

  it 'recognizes an initially unassigned neighbor after a later assignment batch' do
    register('Target::One')
    register('RootA', dependencies: [['RootB']])
    register('RootB', dependencies: [['Target::One']])

    expect(cluster_for('RootA')[:members]).to eq(['RootA', 'RootB', 'Target::One'])
  end

  it 'assigns a root whose identifier also names a namespace cluster' do
    register('Target::One')
    register('Target', dependencies: [['Target::One']])

    expect(cluster_for('Target')[:members]).to eq(['Target', 'Target::One'])
  end

  it 'keeps the existing namespace prefix for an explicitly rooted identifier' do
    register('::Target::One')
    register('Root', dependencies: [['::Target::One']])

    expect(cluster_for('Root')[:name]).to eq('')
  end

  it 'counts repeated forward targets with different relationship labels' do
    register('Alpha::One')
    register('Zulu::One')
    register('Root', dependencies: [['Alpha::One', :belongs_to], ['Alpha::One', :code_reference], ['Zulu::One']])

    expect(cluster_for('Root')[:name]).to eq('Alpha')
  end

  it 'counts forward targets from every type sharing an identifier' do
    register('Alpha::One')
    register('Zulu::One')
    register('Root', type: :model, dependencies: [['Alpha::One', :belongs_to]])
    register('Root', dependencies: [['Alpha::One', :code_reference], ['Zulu::One']])

    expect(cluster_for('Root')[:name]).to eq('Alpha')
  end

  it 'counts a reverse neighbor once even when it has multiple relationship labels' do
    register('Alpha::One', dependencies: [['Root', :belongs_to], ['Root', :code_reference]])
    register('Zulu::One', dependencies: [['Root']])
    register('Zulu::Two', dependencies: [['Root']])
    register('Root')

    expect(cluster_for('Root')[:name]).to eq('Zulu')
  end

  it 'counts reciprocal forward and reverse contributions separately' do
    register('Alpha::One', dependencies: [['Root']])
    register('Zulu::One')
    register('Root', dependencies: [['Alpha::One'], ['Zulu::One']])

    expect(cluster_for('Root')[:name]).to eq('Alpha')
  end

  it 'breaks equal connection counts by the greatest cluster name' do
    register('Alpha::One')
    register('Zulu::One')
    register('Root', dependencies: [['Alpha::One'], ['Zulu::One']])

    expect(cluster_for('Root')[:name]).to eq('Zulu')
  end

  it 'uses one membership snapshot per round and stops after ten rounds' do
    register('Target::One')
    11.times do |index|
      target = index == 10 ? 'Target::One' : format('Root%02d', index + 1)
      register(format('Root%02d', index), dependencies: [[target]])
    end

    cluster = cluster_for('Target::One')
    expect(cluster[:members]).to eq((1..10).map { |index| format('Root%02d', index) } + ['Target::One'])
    expect(cluster_for('Root00')).to be_nil
  end

  it 'does not assign through seeds excluded by the type or custom filter' do
    register('Alpha::One', type: :model)
    register('Zulu::One')
    register('Root', dependencies: [['Alpha::One'], ['Zulu::One']])

    expect(cluster_for('Root', types: ['service'])[:name]).to eq('Zulu')
    expect(cluster_for('Root', only: ->(identifier, _node) { identifier != 'Zulu::One' })[:name]).to eq('Alpha')
  end

  it 'does not infer ownership of an excluded seed from a retained seed with the same prefix' do
    register('Alpha::Kept')
    register('Alpha::Excluded')
    register('Root', dependencies: [['Alpha::Excluded']])

    expect(cluster_for('Root', only: ->(identifier, _node) { identifier != 'Alpha::Excluded' })).to be_nil
  end

  it 'leaves roots without an eligible neighbor unassigned' do
    register('Target::One')
    register('Root', dependencies: [['Missing::One']])

    expect(cluster_for('Root')).to be_nil
  end
end
