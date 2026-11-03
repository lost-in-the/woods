# frozen_string_literal: true

require 'spec_helper'
require 'woods/published_index'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe Woods::PublishedIndex, 'published unit types' do
  around do |example|
    Dir.mktmpdir('woods-published-types') do |dir|
      @dir = dir
      File.write(File.join(dir, 'manifest.json'), '{}')
      write_units('graphql', %w[graphql_type graphql_mutation graphql_resolver graphql_query])
      write_units('rails_source', %w[rails_source gem_source])
      described_class.open(dir) do |index|
        @index = index
        example.run
      end
    end
  end

  def write_units(directory, types)
    FileUtils.mkdir_p(File.join(@dir, directory))
    entries = types.map { |type| { 'identifier' => "Example::#{type}", 'namespace' => 'Example' } }
    File.write(File.join(@dir, directory, '_index.json'), JSON.generate(entries))
    entries.zip(types).each do |entry, type|
      identifier = entry.fetch('identifier')
      filename = "#{identifier.gsub('::', '__')}_#{Digest::SHA256.hexdigest(identifier)[0, 8]}.json"
      File.write(File.join(@dir, directory, filename), JSON.generate(entry.merge('type' => type)))
    end
  end

  %w[graphql_type graphql_mutation graphql_resolver graphql_query gem_source rails_source].each do |type|
    it "reads #{type} by its published identity" do
      expect(@index.unit("Example::#{type}", type: type.to_sym)).to include('type' => type)
      expect(@index.units(type: type).map { |entry| entry['type'] }).to include(type)
    end
  end

  it 'does not return a different GraphQL subtype' do
    expect(@index.unit('Example::graphql_type', type: 'graphql_mutation')).to be_nil
    expect(@index.units(type: 'graphql_mutation')).to eq([
                                                           { 'identifier' => 'Example::graphql_mutation', 'namespace' => 'Example', 'type' => 'graphql_mutation' }
                                                         ])
  end

  it 'preserves actual types and index entry fields when enumerating all units' do
    expect(@index.units.map { |entry| entry.fetch('type') }).to contain_exactly(
      'graphql_type', 'graphql_mutation', 'graphql_resolver', 'graphql_query', 'rails_source', 'gem_source'
    )
    expect(@index.units).to all(include('namespace' => 'Example'))
  end

  it 'retains directory-family aliases without relabeling their members' do
    expect(@index.unit('Example::graphql_type', type: 'graphql')).to include('type' => 'graphql_type')
    expect(@index.unit('Example::gem_source', type: 'rails_source')).to include('type' => 'gem_source')
    expect(@index.units(type: 'graphql').size).to eq(4)
    expect(@index.units(type: 'rails_source').map { |entry| entry['type'] })
      .to contain_exactly('rails_source', 'gem_source')
  end

  # An index entry naming its own type labels a unit of a shared directory
  # without opening the unit: listing a large routes directory otherwise
  # reads every route file.
  describe 'entries that name their published type' do
    def write_typed_index(directory, entries)
      FileUtils.mkdir_p(File.join(@dir, directory))
      File.write(File.join(@dir, directory, '_index.json'), JSON.generate(entries))
    end

    before do
      write_typed_index('routes', [{ 'identifier' => 'GET /', 'type' => 'route', 'namespace' => nil },
                                   { 'identifier' => 'config/routes.rb', 'type' => 'route_file', 'namespace' => nil }])
      allow(Woods::PublishedIndex::TypedUnitReader).to receive(:call).and_call_original
      @reader = @index.instance_variable_get(:@reader)
      allow(@reader).to receive(:find_family_unit).and_call_original
    end

    # `route` is the route unit type, not a family alias for routes/ (#969):
    # it lists the route only, while the unfiltered listing keeps both.
    it 'labels them without reading the units' do
      expect(@index.units(type: 'route_file'))
        .to eq([{ 'identifier' => 'config/routes.rb', 'type' => 'route_file', 'namespace' => nil }])
      expect(@index.units(type: 'route').map { |entry| entry['type'] }).to eq(%w[route])
      expect(@index.units.map { |entry| entry['type'] }).to include('route', 'route_file')
      expect(Woods::PublishedIndex::TypedUnitReader).not_to have_received(:call)
      expect(@reader).not_to have_received(:find_family_unit).with(anything, 'route')
    end

    # The directory read, not a `route`-typed read: a typed read would hide
    # a route_file behind a misnamed entry instead of labelling it.
    it 'reads the unit from its directory when the named type does not belong to the directory' do
      write_typed_index('routes', [{ 'identifier' => 'GET /', 'type' => 'model', 'namespace' => nil }])
      filename = Class.new { include Woods::FilenameUtils }.new.collision_safe_filename('GET /')
      File.write(File.join(@dir, 'routes', filename), JSON.generate('identifier' => 'GET /', 'type' => 'route'))
      expect(@index.units(type: 'route_file')).to eq([])
      expect(@index.units(type: 'route').map { |entry| entry['type'] }).to eq(%w[route])
      expect(@reader).to have_received(:find_family_unit).with('GET /', 'route').at_least(:once)
    end
  end

  it 'returns no units for an unknown type' do
    expect(@index.unit('Example::graphql_type', type: 'unknown')).to be_nil
    expect(@index.units(type: 'unknown')).to eq([])
  end
end
