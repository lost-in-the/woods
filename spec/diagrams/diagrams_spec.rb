# frozen_string_literal: true

require 'spec_helper'
require 'woods/mcp/index_reader'
require 'woods/diagrams'

RSpec.describe Woods::Diagrams do
  include DiagramIndex

  before { described_class::Cache.clear }

  def build(**arguments)
    described_class.build(diagram_reader, index_dir: diagram_root, **arguments)
  end

  it 'refuses an unknown kind and names the kinds' do
    expect { build(kind: 'class', identifier: 'Post') }
      .to raise_error(described_class::InvalidRequest, /Unknown diagram kind "class"; use one of neighbourhood, schema/)
  end

  it 'gives every kind a depth with its own default and range' do
    expect(described_class::DEPTHS.transform_values { |spec| [spec[:default], spec[:range]] })
      .to eq('neighbourhood' => [1, 1..3], 'schema' => [1, 1..3], 'lifecycle' => [0, 0..2], 'impact' => [2, 0..10])
    described_class::DEPTHS.each do |kind, spec|
      expect(described_class.depth_for(kind, nil)).to eq(spec[:default])
      expect(described_class.depth_for(kind, spec[:range].max)).to eq(spec[:range].max)
      [spec[:range].min - 1, spec[:range].max + 1, 'two'].each do |depth|
        expect { described_class.depth_for(kind, depth) }
          .to raise_error(described_class::InvalidRequest, /\A#{kind} depth must be #{spec[:range].min} to/)
      end
    end
  end

  it 'answers an unknown unit as not found, typed or not' do
    expect { build(kind: 'neighbourhood', identifier: 'Nope') }
      .to raise_error(described_class::UnitNotFound, 'No unit Nope in this generation')
    expect { build(kind: 'schema', identifier: 'Post', type: 'job') }
      .to raise_error(described_class::UnitNotFound, 'No unit Post of type job in this generation')
  end

  it 'records the generation, the depth and what was built' do
    result = build(kind: 'schema', identifier: 'Post')
    expect([result.generation, result.drawn?, result.refusal]).to eq([1, true, nil])
    expect(result.details).to include('kind' => 'schema', 'identifier' => 'Post', 'type' => 'model', 'depth' => 1,
                                      'budget' => 40, 'size' => 3)
  end

  it 'caches per generation and request, and builds again for another generation' do
    first = build(kind: 'neighbourhood', identifier: 'Post')
    expect(build(kind: 'neighbourhood', identifier: 'Post')).to equal(first)
    expect(build(kind: 'neighbourhood', identifier: 'Post', depth: 2)).not_to equal(first)
    File.write(File.join(diagram_root, 'generation.json'),
               JSON.generate('number' => 2, 'token' => 'diagrams-2', 'payload' => 'payloads/gen-1'))
    second = build(kind: 'neighbourhood', identifier: 'Post')
    expect([second.generation, second.text]).to eq([2, first.text])
    expect(second).not_to equal(first)
  end

  it 'keeps a bounded number of results, oldest dropped first' do
    stub_const('Woods::Diagrams::Cache::LIMIT', 2)
    first = build(kind: 'neighbourhood', identifier: 'Post')
    build(kind: 'neighbourhood', identifier: 'User')
    build(kind: 'neighbourhood', identifier: 'Comment')
    expect(described_class::Cache.size).to eq(2)
    expect(build(kind: 'neighbourhood', identifier: 'Post')).not_to equal(first)
  end

  it 'refuses options a kind does not take' do
    expect { build(kind: 'schema', identifier: 'Post', direction: 'both') }
      .to raise_error(described_class::InvalidRequest, 'schema takes no direction')
  end
end
