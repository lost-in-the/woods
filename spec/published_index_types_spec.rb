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

  it 'returns no units for an unknown type' do
    expect(@index.unit('Example::graphql_type', type: 'unknown')).to be_nil
    expect(@index.units(type: 'unknown')).to eq([])
  end
end
