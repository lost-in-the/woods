# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'woods'
require 'woods/source_references/caller_policy'

RSpec.describe Woods::SourceReferences::CallerPolicy do
  subject(:policy) { described_class.new }

  let(:types) { Woods::SourceReferences::Registry::TYPES }

  describe 'defaults' do
    let(:component_types) { %w[component view_component] }
    let(:graphql_types) { %w[graphql_type graphql_mutation graphql_resolver graphql_query] }

    it 'admits every constant-owned unit type as a caller' do
      expect(types.reject { |type| policy.caller?(type) }).to be_empty
    end

    it 'lets a component reference everything except another component' do
      component_types.each do |caller|
        expect(types.reject { |target| policy.permits?(caller, target) }.map(&:to_s)).to match_array(component_types)
      end
      expect(policy.permits?('component', 'model')).to be(true)
      expect(policy.permits?('view_component', 'service')).to be(true)
    end

    it 'lets a GraphQL unit reference everything except another GraphQL unit' do
      graphql_types.each do |caller|
        expect(types.reject { |target| policy.permits?(caller, target) }.map(&:to_s)).to match_array(graphql_types)
      end
      expect(policy.permits?('graphql_resolver', 'model')).to be(true)
    end

    it 'leaves every other caller type unfiltered' do
      unfiltered = types.map(&:to_s) - component_types - graphql_types
      unfiltered.each do |caller|
        expect(types.reject { |target| policy.permits?(caller, target) }).to be_empty
      end
    end
  end

  describe 'overrides' do
    it 'changes only the caller types it names' do
      policy = described_class.new(service: %i[model])
      expect(policy.permits?('service', 'model')).to be(true)
      expect(policy.permits?('service', 'lib')).to be(false)
      expect(policy.permits?('model', 'lib')).to be(true)
    end

    it 'accepts string keys and string target types' do
      policy = described_class.new('service' => %w[model lib])
      expect(policy.permits?(:service, :lib)).to be(true)
      expect(policy.permits?(:service, :poro)).to be(false)
    end

    it 'expands :all to every constant-owned unit type' do
      policy = described_class.new(service: :all)
      expect(types.all? { |target| policy.permits?('service', target) }).to be(true)
    end

    [false, nil, []].each do |disabled|
      it "stops a type being a caller for #{disabled.inspect}" do
        policy = described_class.new(model: disabled)
        expect(policy.caller?('model')).to be(false)
        expect(policy.permits?('model', 'service')).to be(false)
        expect(policy.to_h).not_to have_key('model')
      end
    end

    it 'rejects a value that is not a Hash' do
      expect { described_class.new(%i[model]) }
        .to raise_error(Woods::ConfigurationError, /source_reference_callers must be a Hash/)
    end

    it 'rejects an unknown caller type and names the valid ones' do
      expect { described_class.new(widget: :all) }
        .to raise_error(Woods::ConfigurationError, /unknown caller type :widget.*model/m)
    end

    it 'rejects an unknown target type' do
      expect { described_class.new(model: %i[ledger]) }
        .to raise_error(Woods::ConfigurationError, /unknown target type :ledger for model/)
    end

    it 'rejects a target list that is neither :all, false nor an Array' do
      expect { described_class.new(model: 'service') }
        .to raise_error(Woods::ConfigurationError, /model must be :all, false or an Array/)
    end
  end

  describe '#caller?' do
    it 'is false for a type the reference registry does not own' do
      expect(policy.caller?('route')).to be(false)
      expect(policy.caller?(nil)).to be(false)
    end
  end

  describe '#to_h' do
    it 'is identical JSON for equivalent policies written in a different order' do
      first = described_class.new(service: %i[model lib], model: %i[poro job])
      second = described_class.new('model' => %w[job poro], 'service' => %w[lib model model])
      expect(JSON.generate(first.to_h)).to eq(JSON.generate(second.to_h))
    end

    it 'lists callers and targets sorted, as strings' do
      serialized = described_class.new(service: %i[model lib]).to_h
      expect(serialized.keys).to eq(serialized.keys.sort)
      expect(serialized.fetch('service')).to eq(%w[lib model])
    end
  end

  describe '.normalize' do
    it 'returns a deeply frozen symbol map covering every registry type' do
      normalized = described_class.normalize(model: false)
      expect(normalized.keys).to match_array(types)
      expect(normalized.fetch(:model)).to eq([])
      expect(normalized).to be_frozen
      expect(normalized.values).to all(be_frozen)
    end
  end
end
