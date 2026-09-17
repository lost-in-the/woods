# frozen_string_literal: true

require 'spec_helper'
require_relative '../../bench/evaluation/lexical_comparison'

RSpec.describe RetrievalComparison::SeededExecutor do
  let(:metadata) { Woods::Storage::MetadataStore::InMemory.new }
  let(:graph) { Woods::Storage::GraphStore::Memory.new }
  let(:lexical) { Woods::Retrieval::LexicalIndex.new(metadata_store: metadata) }
  let(:executor) { described_class.new(lexical, metadata, graph) }

  before do
    %w[Target Neighbor UnrelatedHub].each do |name|
      metadata.store(name, { 'identifier' => name, 'type' => 'model',
                             'source_code' => name == 'Target' ? 'notify' : '' })
      unit = Woods::ExtractedUnit.new(type: :model, identifier: name, file_path: "app/models/#{name}.rb")
      unit.dependencies = [{ target: 'Neighbor', type: :reference }] if name == 'Target'
      graph.register(unit)
    end
  end

  it 'does not invent graph seeds for a query without positive lexical evidence' do
    expect(executor.execute(query: 'missingword').candidates).to be_empty
  end

  it 'never promotes a disconnected hub over query evidence' do
    ids = executor.execute(query: 'notify').candidates.map(&:identifier)
    expect(ids).to include('Target', 'Neighbor')
    expect(ids).not_to include('UnrelatedHub')
  end

  it 'keeps exclusions authoritative during graph propagation' do
    expect(executor.execute(query: 'notify', exclude_types: ['model']).candidates).to be_empty
  end
end
