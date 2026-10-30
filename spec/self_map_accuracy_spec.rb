# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods/gem_mapper'
require 'woods/gem_map_affected_specs'
require 'woods/published_index'

# Agents choose what to run from the self-map's dependents (#926), so a
# regression in it silently narrows every blast radius. These edges are
# known truths about this repository; each names the mapping rule it holds.
RSpec.describe 'Woods self-map accuracy', :self_map do
  before(:context) do
    @output = Dir.mktmpdir('woods-self-map-accuracy')
    Woods::GemMapper.new(root: File.expand_path('..', __dir__), output_dir: @output).map!
    @index = Woods::PublishedIndex.open(@output)
  end

  after(:context) { FileUtils.rm_rf(@output) }

  def dependents(identifier)
    @index.dependents_of(identifier)
  end

  it 'resolves a constant a method names relative to its enclosing module' do
    expect(dependents('Woods::GitCommitTable')).to include('Woods::Extractor#published_commit_table')
  end

  it 'maps class << self methods' do
    expect(dependents('Woods::Extractor')).to include('Woods.with_extraction_writer')
  end

  it 'records what top-level rake code references' do
    expect(dependents('Woods::GemMapper')).to include('file:lib/tasks/woods.rake')
  end

  it 'maps specs by the constants they name' do
    expect(dependents('Woods::GemMapper')).to include('file:spec/gem_mapper_spec.rb')
  end

  it 'names the specs a change to the mapper reaches' do
    specs = Woods::GemMapAffectedSpecs.new(@index).for(['lib/woods/gem_mapper.rb']).fetch(:specs)

    expect(specs).to include('spec/gem_mapper_spec.rb', 'spec/gem_map_affected_specs_spec.rb',
                             'spec/self_map_accuracy_spec.rb')
  end
end
