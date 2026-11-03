# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods/filename_utils'
require 'woods/mcp/index_reader'
require 'woods/published_index'

# `routes/` holds two unit types: `route` (one per routing rule) and
# `route_file` (one per routes source file). Only `graphql` and
# `rails_source` are documented directory-family aliases, so `route` names
# the route unit type alone; it must not expand to the whole directory.
#
# Type selector truth table (what a `type:`/`types:` argument stands for):
#
#   | selector       | expands to                                          |
#   |----------------|-----------------------------------------------------|
#   | route          | route                                               |
#   | route_file     | route_file                                          |
#   | routes         | nothing (no plural selector; unknown)               |
#   | graphql        | graphql_type graphql_mutation graphql_resolver ...  |
#   | rails_source   | rails_source gem_source                             |
#   | gem_source     | gem_source                                          |
#   | model          | model                                               |
#   | nope           | nothing (unknown)                                   |
RSpec.describe 'Route type selector' do
  include Woods::FilenameUtils

  let(:index_dir) { Dir.mktmpdir('woods-route-type') }
  let(:reader) { Woods::MCP::IndexReader.new(index_dir) }
  let(:graphql_types) { %w[graphql_type graphql_mutation graphql_resolver graphql_query] }

  # Each unit is [directory, type, identifier, file_path, last_modified].
  let(:units) do
    [
      ['routes', 'route', 'GET /widgets', 'config/routes.rb', '2026-01-05T00:00:00Z'],
      ['routes', 'route_file', 'config/routes.rb', 'config/routes.rb', '2026-01-06T00:00:00Z'],
      ['models', 'model', 'Widget', 'app/models/widget.rb', '2026-01-01T00:00:00Z'],
      ['rails_source', 'rails_source', 'ActiveRecord::Base', 'activerecord/lib/active_record/base.rb',
       '2026-01-02T00:00:00Z'],
      ['rails_source', 'gem_source', 'Devise::Models', 'lib/devise/models.rb', '2026-01-03T00:00:00Z'],
      *graphql_types.each_with_index.map do |type, index|
        ['graphql', type, "Graph::Unit#{index}", "app/graphql/unit#{index}.rb", "2026-01-04T0#{index}:00:00Z"]
      end
    ]
  end

  def write_unit(path, type, identifier, file_path, last_modified)
    unit = { 'type' => type, 'identifier' => identifier, 'file_path' => file_path,
             'source_code' => "# #{identifier}",
             'metadata' => { 'git' => { 'last_modified' => last_modified, 'last_author' => 'dev' } } }
    File.write(File.join(path, collision_safe_filename(identifier)), JSON.generate(unit))
  end

  def write_index(typed_entries: true)
    units.group_by(&:first).each do |directory, rows|
      path = File.join(index_dir, directory)
      FileUtils.mkdir_p(path)
      entries = rows.map do |(_, type, identifier, file_path, last_modified)|
        write_unit(path, type, identifier, file_path, last_modified)
        entry = { 'identifier' => identifier, 'file_path' => file_path }
        typed_entries ? entry.merge('type' => type) : entry
      end
      File.write(File.join(path, '_index.json'), JSON.generate(entries.sort_by { |e| e['identifier'] }))
    end
    File.write(File.join(index_dir, 'manifest.json'), JSON.generate('counts' => units.map(&:first).tally))
  end

  before { write_index }
  after { FileUtils.remove_entry(index_dir) }

  def search_types(*types)
    reader.search('.', types: types, limit: 50)[:results].map { |row| [row[:type], row[:identifier]] }
  end

  describe 'IndexReader#unit_types_for' do
    {
      'route' => %w[route],
      'route_file' => %w[route_file],
      'routes' => [],
      'graphql' => %w[graphql_type graphql_mutation graphql_resolver graphql_query],
      'rails_source' => %w[rails_source gem_source],
      'gem_source' => %w[gem_source],
      'model' => %w[model],
      'nope' => []
    }.each do |selector, expected|
      it "expands #{selector.inspect} to #{expected.inspect}" do
        expect(reader.unit_types_for(selector)).to eq(expected)
      end
    end

    it 'keeps the family aliases to the documented allowlist' do
      expect(Woods::MCP::IndexReader::DIRECTORY_FAMILY_ALIASES).to eq(%w[graphql rails_source])
    end
  end

  describe 'search' do
    it 'returns route units only for route (positive)' do
      expect(search_types('route')).to eq([['route', 'GET /widgets']])
    end

    it 'does not return the route file for route (near miss: same directory, other type)' do
      expect(search_types('route').map(&:first)).not_to include('route_file')
      expect(search_types('route_file')).to eq([['route_file', 'config/routes.rb']])
    end

    it 'applies the same meaning inside a source-path scope' do
      result = reader.search('.', types: ['route'], source_paths: ['config/'], limit: 50)
      expect(result[:results].map { |row| row[:type] }).to eq(['route'])
    end

    it 'refuses a plural routes selector as unknown' do
      expect { reader.search('.', types: ['routes']) }.to raise_error(ArgumentError, /unknown search type: routes/)
    end

    it 'still expands the documented family aliases' do
      expect(search_types('graphql').map(&:first)).to match_array(graphql_types)
      expect(search_types('rails_source').map(&:first)).to contain_exactly('rails_source', 'gem_source')
    end
  end

  describe 'lookup (IndexReader#find_unit with type:)' do
    it 'finds a route as route and the route file only as route_file' do
      expect(reader.find_unit('GET /widgets', type: 'route')).to include('type' => 'route')
      expect(reader.find_unit('config/routes.rb', type: 'route')).to be_nil
      expect(reader.find_unit('config/routes.rb', type: 'route_file')).to include('type' => 'route_file')
    end
  end

  describe 'PublishedIndex' do
    def with_index(&block)
      Woods::PublishedIndex.open(index_dir, &block)
    end

    it 'unit(type: "route") does not return a route file' do
      with_index do |index|
        expect(index.unit('GET /widgets', type: 'route')).to include('type' => 'route')
        expect(index.unit('config/routes.rb', type: 'route')).to be_nil
        expect(index.unit('config/routes.rb', type: 'route_file')).to include('type' => 'route_file')
      end
    end

    it 'units(type: "route") lists route units only' do
      with_index do |index|
        expect(index.units(type: 'route').map { |e| [e['type'], e['identifier']] })
          .to eq([['route', 'GET /widgets']])
        expect(index.units(type: 'route_file').map { |e| e['identifier'] }).to eq(['config/routes.rb'])
        expect(index.units(type: 'routes')).to eq([])
      end
    end

    it 'still expands graphql and rails_source over their whole directory' do
      with_index do |index|
        expect(index.units(type: 'graphql').map { |e| e['type'] }).to match_array(graphql_types)
        expect(index.units(type: 'rails_source').map { |e| e['type'] }).to contain_exactly('rails_source', 'gem_source')
        expect(index.unit('Devise::Models', type: 'rails_source')).to include('type' => 'gem_source')
        expect(index.unit('Graph::Unit1', type: 'graphql')).to include('type' => 'graphql_mutation')
      end
    end

    # Indexes written before entries carried their type: the type of a
    # routes/ entry is unknown until the unit is read.
    context 'with an older index whose entries carry no type' do
      before { write_index(typed_entries: false) }

      it 'labels every routes/ entry with its read type' do
        with_index do |index|
          labelled = index.units.select { |e| %w[route route_file].include?(e['type']) }
          expect(labelled.map { |e| [e['type'], e['identifier']] })
            .to contain_exactly(['route', 'GET /widgets'], ['route_file', 'config/routes.rb'])
        end
      end

      it 'filters untyped entries by their read type' do
        with_index do |index|
          expect(index.units(type: 'route').map { |e| e['identifier'] }).to eq(['GET /widgets'])
          expect(index.units(type: 'route_file').map { |e| e['identifier'] }).to eq(['config/routes.rb'])
          expect(index.units(type: 'rails_source').map { |e| e['type'] })
            .to contain_exactly('rails_source', 'gem_source')
        end
      end

      it 'searches untyped entries by their read type' do
        expect(search_types('route')).to eq([['route', 'GET /widgets']])
      end
    end
  end

  describe 'recent_changes' do
    def recent(types = nil)
      reader.recent_changes(limit: 50, types: types).map { |row| [row[:type], row[:identifier]] }
    end

    it 'labels each row with its unit type, not its directory' do
      expect(recent).to include(['route_file', 'config/routes.rb'], ['gem_source', 'Devise::Models'],
                                ['graphql_mutation', 'Graph::Unit1'])
      expect(recent.map(&:first)).not_to include('graphql')
    end

    it 'filters route to route units only' do
      expect(recent(['route'])).to eq([['route', 'GET /widgets']])
      expect(recent(['route_file'])).to eq([['route_file', 'config/routes.rb']])
    end

    it 'still expands the family aliases and returns nothing for an unknown type' do
      expect(recent(['rails_source']).map(&:first)).to contain_exactly('rails_source', 'gem_source')
      expect(recent(['graphql']).map(&:first)).to match_array(graphql_types)
      expect(recent(['routes'])).to eq([])
    end
  end
end
