# frozen_string_literal: true

require 'spec_helper'
require 'woods/dependency_graph'
require 'woods/extracted_unit'

RSpec.describe Woods::DependencyGraph, 'file profile identity' do
  let(:graph) { described_class.new }

  def register(identifier, type, path)
    graph.register(Woods::ExtractedUnit.new(identifier: identifier, type: type, file_path: path))
  end

  it 'distinguishes a caching profile from its controller without removing change ownership' do
    path = 'app/controllers/things_controller.rb'
    register('ThingsController', :controller, path)
    register(path, :caching, path)

    snapshot = graph.to_h
    expect(snapshot.fetch(:file_map).fetch(path)).to contain_exactly('ThingsController', path)
    expect(snapshot.fetch(:nodes).fetch(path)).to include(type: :caching, kind: 'file_profile')
    expect(snapshot.fetch(:nodes).fetch('ThingsController')).not_to have_key(:kind)
    expect(graph.affected_by([path])).to include('ThingsController', path)
  end

  it 'marks each supported file profile by extractor type, independently of its identifier spelling' do
    %i[caching configuration test_mapping rails_source gem_source].each do |type|
      register("#{type}/profile", type, '/some/source.rb')
      expect(graph.to_h.fetch(:nodes).fetch("#{type}/profile")).to include(kind: 'file_profile')
    end
  end

  it 'does not classify unrelated path-named units as profiles or constants' do
    %i[view component service custom].each do |type|
      register("app/#{type}.rb", type, "app/#{type}.rb")
      expect(graph.to_h.fetch(:nodes).fetch("app/#{type}.rb")).not_to have_key(:kind)
    end
  end

  it 'retains the marker on a non-primary typed variant after a JSON round trip' do
    register('Shared', :api, 'app/shared.rb')
    register('Shared', :configuration, 'config/shared.rb')
    snapshot = JSON.parse(JSON.generate(graph.to_h))
    restored = described_class.from_h(snapshot).to_h

    expect(restored.fetch(:nodes).fetch('Shared')).not_to have_key(:kind)
    expect(restored.fetch(:variants)).to include(include(identifier: 'Shared', type: :configuration,
                                                         kind: 'file_profile'))
    expect(JSON.parse(JSON.generate(restored))).to eq(snapshot)
  end

  it 'derives markers when republishing a legacy graph, including variants' do
    register('Shared', :caching, 'app/shared.rb')
    register('Shared', :test_mapping, 'spec/shared_spec.rb')
    snapshot = JSON.parse(JSON.generate(graph.to_h))
    snapshot.fetch('nodes').each_value { |node| node.delete('kind') }
    snapshot.fetch('variants').each { |node| node.delete('kind') }

    restored = described_class.from_h(snapshot).to_h
    expect(restored.fetch(:nodes).fetch('Shared')).to include(kind: 'file_profile')
    expect(restored.fetch(:variants).first).to include(kind: 'file_profile')
  end

  it 'agrees between a fresh graph and incremental registration from a legacy baseline' do
    register('config/example.rb', :configuration, 'config/example.rb')
    snapshot = JSON.parse(JSON.generate(graph.to_h))
    snapshot.fetch('nodes').each_value { |node| node.delete('kind') }
    restored = described_class.from_h(snapshot)
    replacement = Woods::ExtractedUnit.new(identifier: 'app/cache.rb', type: :caching, file_path: 'app/cache.rb')
    graph.register(replacement)
    restored.register(replacement)
    expect(restored.to_h).to eq(graph.to_h)
    expect(restored.to_h.fetch(:nodes).fetch('config/example.rb')).to include(kind: 'file_profile')
  end

  it 'keeps serialized node field order stable after late enrichment and JSON loading' do
    register('app/cache.rb', :caching, 'app/cache.rb')
    graph.annotate('app/cache.rb', type: :caching, commit_count: 4, change_frequency: 'high')
    fresh = JSON.generate(graph.to_h)
    restored = described_class.from_h(JSON.parse(fresh))

    expect(JSON.generate(restored.to_h)).to eq(fresh)
  end
end
