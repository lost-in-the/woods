# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods'
require 'woods/extractor'
require 'woods/gem_mapper'
require 'woods/filename_utils'
require 'woods/mcp/index_reader'
require 'woods/mcp/published_lexical_retriever'
require 'woods/resilience/index_validator'

RSpec.describe 'Published directory type families' do
  include Woods::FilenameUtils

  let(:index_dir) { Dir.mktmpdir('woods-graphql-type-family') }
  let(:reader) { Woods::MCP::IndexReader.new(index_dir) }
  let(:graphql_types) { %w[graphql_type graphql_mutation graphql_resolver graphql_query] }

  before do
    directory = File.join(index_dir, 'graphql')
    FileUtils.mkdir_p(directory)
    units = graphql_types.each_with_index.map do |type, index|
      Woods::ExtractedUnit.new(type: type.to_sym, identifier: "Types::Unit#{index}",
                               file_path: "app/graphql/types/unit#{index}.rb").tap do |unit|
        unit.source_code = "class Types::Unit#{index}; def frobnicate; end; end"
        File.write(File.join(directory, collision_safe_filename(unit.identifier)), JSON.generate(unit.to_h))
      end
    end
    File.write(File.join(directory, '_index.json'), JSON.generate(units.map { |unit| { identifier: unit.identifier } }))
    File.write(File.join(index_dir, 'manifest.json'), JSON.generate(counts: { graphql: units.size }))
    graph = Woods::DependencyGraph.new
    units.each { |unit| graph.register(unit) }
    File.write(File.join(index_dir, 'dependency_graph.json'), JSON.generate(graph.to_h))
  end

  after { FileUtils.remove_entry(index_dir) }

  it 'admits every unit type in the runtime extractor and static-map publication registries' do
    families = Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR
    Woods::Extractor::TYPE_TO_EXTRACTOR_KEY.each do |type, directory|
      expect(families.fetch(directory.to_s)).to include(type.to_s), "#{directory}/ must admit #{type}"
    end
    Woods::GemMapper::TYPE_DIRECTORIES.each do |type, directory|
      expect(families.fetch(directory)).to include(type.to_s), "#{directory}/ must admit #{type}"
    end
  end

  it 'validates all four real GraphQL unit types against their typed graph nodes' do
    report = Woods::Resilience::IndexValidator.new(index_dir: index_dir).validate
    expect(report.errors).to be_empty
    expect(report.valid?).to be(true)
  end

  it 'deep searches the GraphQL family while preserving historical directory-family result labels' do
    result = reader.search('frobnicate', types: ['graphql'], fields: ['source_code'])
    expect(result[:results].size).to eq(4)
    expect(result[:results].map { |row| row[:type] }.uniq).to eq(['graphql'])
    expect(result[:completeness]).to include(status: 'complete', total_matches: 4)
    expect(reader.each_unit.map { |unit| unit['type'] }).to eq(graphql_types)
  end

  it 'retrieves each GraphQL subtype using actual typed identities without embeddings' do
    retriever = Woods::MCP::PublishedLexicalRetriever.new(index_dir: index_dir)
    graphql_types.each do |type|
      result = retriever.retrieve('frobnicate', types: [type])
      expect(result.sources.size).to eq(1)
      expect(result.sources.first[:type]).to eq(type)
    end
  end

  it 'continues rejecting an unrelated service payload in the GraphQL directory' do
    path = File.join(index_dir, 'graphql', collision_safe_filename('Types::Unit0'))
    File.write(path, JSON.generate(JSON.parse(File.read(path)).merge('type' => 'service')))
    expect { reader.each_unit.to_a }.to raise_error(IOError, /typed unit identity mismatch/)
    expect(Woods::Resilience::IndexValidator.new(index_dir: index_dir).validate.valid?).to be(false)
  end
end
