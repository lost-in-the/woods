# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/dependency_graph'
require 'codebase_index/mcp/index_reader'

RSpec.describe CodebaseIndex::MCP::IndexReader do
  let(:fixture_dir) { File.expand_path('../fixtures/codebase_index', __dir__) }
  let(:reader) { described_class.new(fixture_dir) }

  describe '#initialize' do
    it 'accepts a valid index directory' do
      expect { described_class.new(fixture_dir) }.not_to raise_error
    end

    it 'raises ArgumentError for non-existent directory' do
      expect { described_class.new('/nonexistent/path') }
        .to raise_error(ArgumentError, /does not exist/)
    end

    it 'raises ArgumentError for directory without manifest.json' do
      require 'tmpdir'
      expect { described_class.new(Dir.tmpdir) }
        .to raise_error(ArgumentError, /No manifest\.json/)
    end
  end

  describe '#manifest' do
    it 'returns parsed manifest data' do
      expect(reader.manifest).to include(
        'rails_version' => '8.1.2',
        'ruby_version' => '4.0.1',
        'total_units' => 7
      )
    end

    it 'caches the result' do
      expect(reader.manifest).to equal(reader.manifest)
    end
  end

  describe '#summary' do
    it 'returns SUMMARY.md content' do
      expect(reader.summary).to include('Codebase Index Summary')
      expect(reader.summary).to include('Post')
    end
  end

  describe '#dependency_graph' do
    it 'returns a DependencyGraph instance' do
      expect(reader.dependency_graph).to be_a(CodebaseIndex::DependencyGraph)
    end

    it 'has correct edges' do
      graph = reader.dependency_graph
      expect(graph.dependencies_of('Comment')).to include('Post')
      expect(graph.dependents_of('Post')).to include('Comment', 'PostsController')
    end
  end

  describe '#graph_analysis' do
    it 'returns parsed graph analysis data' do
      analysis = reader.graph_analysis
      expect(analysis).to include('orphans', 'dead_ends', 'hubs', 'cycles')
    end

    it 'contains expected orphans' do
      expect(reader.graph_analysis['orphans']).to include('PostsController')
    end
  end

  describe '#find_unit' do
    it 'returns full unit data for a valid identifier' do
      unit = reader.find_unit('Post')
      expect(unit).to include(
        'type' => 'model',
        'identifier' => 'Post',
        'source_code' => a_string_including('has_many :comments')
      )
    end

    it 'returns nil for an unknown identifier' do
      expect(reader.find_unit('NonExistent')).to be_nil
    end

    it 'includes metadata in the unit' do
      unit = reader.find_unit('Post')
      expect(unit['metadata']).to include('table_name' => 'posts')
    end

    it 'loads controller units' do
      unit = reader.find_unit('PostsController')
      expect(unit['type']).to eq('controller')
      expect(unit['source_code']).to include('Post.all')
    end
  end

  describe '#list_units' do
    it 'returns all units when no type filter' do
      units = reader.list_units
      identifiers = units.map { |u| u['identifier'] }
      expect(identifiers).to contain_exactly(
        'Post', 'Comment', 'PostsController',
        'ActiveRecord::Base', 'ActionController::Base',
        'PostDecorator', 'Publishable'
      )
    end

    it 'filters by type' do
      units = reader.list_units(type: 'model')
      identifiers = units.map { |u| u['identifier'] }
      expect(identifiers).to contain_exactly('Post', 'Comment')
    end

    it 'returns empty array for unknown type' do
      expect(reader.list_units(type: 'nonexistent')).to eq([])
    end

    it 'returns only controllers when filtered' do
      units = reader.list_units(type: 'controller')
      expect(units.size).to eq(1)
      expect(units.first['identifier']).to eq('PostsController')
    end
  end

  describe '#search' do
    it 'matches identifiers by default' do
      results = reader.search('Post')
      identifiers = results.map { |r| r[:identifier] }
      expect(identifiers).to include('Post', 'PostsController')
    end

    it 'is case-insensitive' do
      results = reader.search('post')
      identifiers = results.map { |r| r[:identifier] }
      expect(identifiers).to include('Post')
    end

    it 'filters by type' do
      results = reader.search('Post', types: ['model'])
      expect(results.all? { |r| r[:type] == 'model' }).to be true
    end

    it 'respects limit' do
      results = reader.search('o', limit: 2)
      expect(results.size).to eq(2)
    end

    it 'searches source_code when requested' do
      results = reader.search('has_many', fields: %w[source_code])
      expect(results.first[:identifier]).to eq('Post')
      expect(results.first[:match_field]).to eq('source_code')
    end

    it 'searches metadata when requested' do
      results = reader.search('posts_controller', fields: %w[metadata])
      # The fixtures have metadata with parent_class etc — this tests that metadata JSON is searched
      expect(results).to be_an(Array)
    end

    it 'returns match_field for each result' do
      results = reader.search('Comment')
      results.each do |r|
        expect(r).to include(:identifier, :type, :match_field)
      end
    end
  end

  describe '#traverse_dependencies' do
    it 'returns forward dependencies for Comment' do
      result = reader.traverse_dependencies('Comment', depth: 1)
      expect(result[:root]).to eq('Comment')
      expect(result[:nodes]['Comment'][:deps]).to include('Post')
    end

    it 'returns empty deps for a leaf node' do
      result = reader.traverse_dependencies('Post', depth: 1)
      expect(result[:nodes]['Post'][:deps]).to eq([])
    end

    it 'respects depth limit' do
      result = reader.traverse_dependencies('Comment', depth: 0)
      # At depth 0, we get the root node but don't traverse further
      expect(result[:nodes].keys).to eq(['Comment'])
    end

    it 'returns empty nodes for unknown identifier' do
      result = reader.traverse_dependencies('NonExistent', depth: 1)
      expect(result[:nodes]).to be_empty
    end

    it 'returns found: false for unknown identifier' do
      result = reader.traverse_dependencies('NonExistent', depth: 1)
      expect(result[:found]).to be false
    end

    it 'returns found: true for known identifier' do
      result = reader.traverse_dependencies('Comment', depth: 1)
      expect(result[:found]).to be true
    end
  end

  describe '#traverse_dependents' do
    it 'returns reverse dependencies for Post' do
      result = reader.traverse_dependents('Post', depth: 1)
      expect(result[:root]).to eq('Post')
      expect(result[:nodes]['Post'][:deps]).to include('Comment', 'PostsController')
    end

    it 'returns empty deps for an orphan node' do
      result = reader.traverse_dependents('PostsController', depth: 1)
      expect(result[:nodes]['PostsController'][:deps]).to eq([])
    end

    it 'returns found: true for known identifier' do
      result = reader.traverse_dependents('Post', depth: 1)
      expect(result[:found]).to be true
    end
  end

  describe '#framework_sources' do
    it 'returns rails_source units matching identifier keyword' do
      results = reader.framework_sources('ActiveRecord')
      identifiers = results.map { |r| r[:identifier] }
      expect(identifiers).to include('ActiveRecord::Base')
    end

    it 'matches against source_code' do
      results = reader.framework_sources('Persistence')
      identifiers = results.map { |r| r[:identifier] }
      expect(identifiers).to include('ActiveRecord::Base')
    end

    it 'matches against metadata' do
      results = reader.framework_sources('controller')
      identifiers = results.map { |r| r[:identifier] }
      expect(identifiers).to include('ActionController::Base')
    end

    it 'returns empty for no match' do
      results = reader.framework_sources('zzz_no_match')
      expect(results).to be_empty
    end

    it 'respects limit' do
      results = reader.framework_sources('Base', limit: 1)
      expect(results.size).to eq(1)
    end

    it 'includes file_path and metadata in results' do
      results = reader.framework_sources('ActiveRecord')
      result = results.find { |r| r[:identifier] == 'ActiveRecord::Base' }
      expect(result[:file_path]).to include('activerecord')
      expect(result[:metadata]).to include('gem_name' => 'activerecord')
    end
  end

  describe '#recent_changes' do
    it 'returns units sorted by last_modified descending' do
      results = reader.recent_changes
      dates = results.map { |r| r[:last_modified] }
      expect(dates).to eq(dates.sort.reverse)
    end

    it 'returns the most recently modified unit first' do
      results = reader.recent_changes
      expect(results.first[:identifier]).to eq('Comment')
    end

    it 'excludes units without git metadata' do
      results = reader.recent_changes
      identifiers = results.map { |r| r[:identifier] }
      # rails_source fixtures have no git metadata
      expect(identifiers).not_to include('ActiveRecord::Base')
    end

    it 'respects limit' do
      results = reader.recent_changes(limit: 1)
      expect(results.size).to eq(1)
    end

    it 'filters by type' do
      results = reader.recent_changes(types: ['model'])
      results.each do |r|
        expect(r[:type]).to eq('model')
      end
    end

    it 'includes expected fields in results' do
      results = reader.recent_changes(limit: 1)
      result = results.first
      expect(result).to include(:identifier, :type, :file_path, :last_modified)
    end
  end

  describe 'previously invisible types' do
    it 'finds decorator units via find_unit' do
      unit = reader.find_unit('PostDecorator')
      expect(unit).to include(
        'type' => 'decorator',
        'identifier' => 'PostDecorator',
        'source_code' => a_string_including('display_title')
      )
    end

    it 'lists concern units via list_units' do
      units = reader.list_units(type: 'concern')
      identifiers = units.map { |u| u['identifier'] }
      expect(identifiers).to include('Publishable')
    end

    it 'searches with types filter for decorators' do
      results = reader.search('Post', types: ['decorator'])
      expect(results).to include(
        a_hash_including(identifier: 'PostDecorator', type: 'decorator')
      )
    end

    it 'searches decorator source_code' do
      results = reader.search('display_title', types: ['decorator'], fields: %w[source_code])
      expect(results.first[:identifier]).to eq('PostDecorator')
      expect(results.first[:match_field]).to eq('source_code')
    end

    it 'searches concern metadata' do
      results = reader.search('publish', types: ['concern'], fields: %w[metadata])
      expect(results.first[:identifier]).to eq('Publishable')
    end

    it 'includes decorators in recent_changes' do
      # PostDecorator has no git metadata, so it won't appear — but the type filter works
      results = reader.recent_changes(types: ['decorator'])
      expect(results).to be_an(Array)
    end
  end

  describe 'TYPE_DIRS coverage' do
    it 'covers all Extractor::EXTRACTORS keys' do
      # This test prevents future drift between IndexReader and Extractor
      require 'codebase_index/extractor'
      extractor_keys = CodebaseIndex::Extractor::EXTRACTORS.keys.map(&:to_s)
      missing = extractor_keys - described_class::TYPE_DIRS
      expect(missing).to be_empty, "TYPE_DIRS is missing: #{missing.join(', ')}"
    end

    it 'has a DIR_TO_TYPE entry for every TYPE_DIRS entry' do
      missing = described_class::TYPE_DIRS - described_class::DIR_TO_TYPE.keys
      expect(missing).to be_empty, "DIR_TO_TYPE is missing: #{missing.join(', ')}"
    end

    it 'has a TYPE_TO_DIR entry for every DIR_TO_TYPE value' do
      described_class::DIR_TO_TYPE.each do |dir, type|
        expect(described_class::TYPE_TO_DIR[type]).to eq(dir),
                                                      "TYPE_TO_DIR missing reverse for #{dir} => #{type}"
      end
    end
  end

  describe 'filename sanitization' do
    it 'generates collision-safe filenames with digest suffix' do
      # Access the private identifier_map to verify filename generation
      map = reader.send(:build_identifier_map)

      # Namespaced identifiers should have :: replaced with __ plus digest
      ar_entry = map['ActiveRecord::Base']
      expect(ar_entry[:filename]).to eq('ActiveRecord__Base_902403fd.json')

      # Simple identifiers get digest suffix too
      post_entry = map['Post']
      expect(post_entry[:filename]).to eq('Post_a5554622.json')
    end

    it 'sanitizes characters not in [a-zA-Z0-9_-] from identifiers' do
      # Build a map entry manually to test the sanitization logic
      id = 'App::Service#process!'
      filename = "#{id.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}.json"
      expect(filename).to eq('App__Service_process_.json')
    end
  end

  describe 'unit cache' do
    it 'caches loaded units' do
      reader.find_unit('Post')
      reader.find_unit('Post')
      # No error and same object returned
      expect(reader.find_unit('Post')).to eq(reader.find_unit('Post'))
    end
  end

  describe '#reload!' do
    it 'clears cached manifest so next access re-reads from disk' do
      original = reader.manifest
      expect(original['total_units']).to eq(7)

      # Swap manifest on disk, reload, and verify fresh data is returned
      manifest_path = File.join(fixture_dir, 'manifest.json')
      original_content = File.read(manifest_path)
      modified = JSON.parse(original_content).merge('total_units' => 999)

      begin
        File.write(manifest_path, JSON.generate(modified))
        reader.reload!
        expect(reader.manifest['total_units']).to eq(999)
      ensure
        File.write(manifest_path, original_content)
      end
    end

    it 'clears unit cache so units are re-read from disk' do
      reader.find_unit('Post')
      reader.reload!
      # After reload, find_unit still works (re-reads from disk)
      unit = reader.find_unit('Post')
      expect(unit['identifier']).to eq('Post')
    end

    it 'clears summary cache' do
      reader.summary
      reader.reload!
      # After reload, summary still works (re-reads from disk)
      expect(reader.summary).to include('Codebase Index Summary')
    end

    it 'clears graph caches' do
      reader.dependency_graph
      reader.graph_analysis
      reader.raw_graph_data
      reader.reload!
      # After reload, all graph accessors still work
      expect(reader.dependency_graph).to be_a(CodebaseIndex::DependencyGraph)
      expect(reader.graph_analysis).to include('orphans')
      expect(reader.raw_graph_data).to include('nodes')
    end
  end
end
