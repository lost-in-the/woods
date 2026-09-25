# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'yaml'
require 'stringio'
require 'woods/dependency_graph'
require 'woods/extracted_unit'
require 'woods/obsidian/vault_exporter'
require 'woods/mcp/index_reader'

RSpec.describe 'Obsidian typed graph variants' do
  around do |example|
    Dir.mktmpdir('woods-typed-vault') do |dir|
      @vault = File.join(dir, 'vault')
      example.run
    end
  end

  def unit(type, identifier, target = nil)
    Woods::ExtractedUnit.new(type: type, identifier: identifier, file_path: "#{type}/#{identifier}.rb").tap do |entry|
      entry.dependencies = [{ target: target, via: :code_reference }] if target
    end
  end

  let(:units) do
    [unit(:database_view, 'reports', 'User'), unit(:factory, 'reports', 'Account'),
     unit(:model, 'User', 'reports'), unit(:model, 'Account')]
  end
  let(:reader) do
    Object.new.tap do |result|
      entries = units
      result.define_singleton_method(:raw_graph_data) do
        graph = Woods::DependencyGraph.new
        entries.each { |entry| graph.register(entry) }
        JSON.parse(JSON.generate(graph.to_h))
      end
      result.define_singleton_method(:graph_analysis) { nil }
      result.define_singleton_method(:list_units) do
        entries.map { |entry| { 'identifier' => entry.identifier, 'type' => entry.type.to_s } }
      end
      result.define_singleton_method(:find_unit) do |identifier, type: nil|
        entry = entries.find { |item| item.identifier == identifier && (!type || item.type.to_s == type) }
        JSON.parse(JSON.generate(entry.to_h)) if entry
      end
    end
  end
  let(:exporter) do
    Woods::Obsidian::VaultExporter.new(index_dir: 'unused', vault_path: @vault,
                                       reader: reader, output: StringIO.new)
  end

  def note(path)
    File.read(File.join(@vault, path), encoding: 'UTF-8')
  end

  def manifest
    JSON.parse(note('_woods/manifest.json'))
  end

  it 'exports both typed reports with original IDs and source-specific links' do
    expect(exporter.export_all[:exported]).to eq(4)
    view = note('database_views/reports.md')
    factory = note('factories/reports.md')
    expect(YAML.safe_load(view.split("\n---\n").first)).to include('id' => 'reports', 'type' => 'database_view')
    expect(YAML.safe_load(factory.split("\n---\n").first)).to include('id' => 'reports', 'type' => 'factory')
    expect(view).to include('[[models/User|User]]')
    expect(view).not_to include('[[models/Account|Account]]')
    expect(factory).to include('[[models/Account|Account]]')
    expect(note('models/Account.md')).to include('[[factories/reports|reports]]')
    expect(note('models/User.md')).to include('[[database_views/reports|reports]]')
    expect(note('models/User.md')).not_to include('## Depends on')
  end

  it 'publishes a versioned complete typed manifest while retaining its primary projection' do
    exporter.export_all
    expect(manifest['schema_version']).to eq(2)
    expect(manifest['notes']['reports']).to include('path' => 'database_views/reports.md', 'type' => 'database_view')
    expect(manifest['variants']).to contain_exactly(
      include('identifier' => 'reports', 'type' => 'factory', 'path' => 'factories/reports.md')
    )
    expect(manifest['paths']).to include('database_views/reports.md' => 'reports', 'factories/reports.md' => 'reports')
  end

  it 'keeps surviving and unrelated notes while sweeping only a removed variant on a reused exporter' do
    exporter.export_all
    original = note('database_views/reports.md')
    File.write(File.join(@vault, 'My notes.md'), '# personal notes')
    units.reject! { |entry| entry.type == :factory }
    expect(exporter.export_all[:swept]).to eq(2) # variant and its now-empty folder MOC
    expect(note('database_views/reports.md')).to include('id: reports')
    expect(original).to include('id: reports')
    expect(File).not_to exist(File.join(@vault, 'factories/reports.md'))
    expect(note('My notes.md')).to eq('# personal notes')
    expect(manifest['schema_version']).to eq(1)
  end

  it 'does not sweep a prior variant when its typed unit cannot be read' do
    exporter.export_all
    allow(reader).to receive(:find_unit).and_wrap_original do |method, identifier, type: nil|
      type == 'factory' ? nil : method.call(identifier, type: type)
    end
    expect(exporter.export_all).to include(skipped: 1, swept: 0)
    expect(File).to exist(File.join(@vault, 'factories/reports.md'))
  end
  it 'exports both real published unit files through IndexReader' do
    Dir.mktmpdir('woods-published-variants') do |index|
      File.write(File.join(index, 'manifest.json'), JSON.generate(total_units: units.size))
      File.write(File.join(index, 'dependency_graph.json'), JSON.generate(reader.raw_graph_data))
      units.group_by(&:type).each do |type, entries|
        dir = File.join(index, Woods::MCP::IndexReader::TYPE_TO_DIR.fetch(type.to_s))
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, '_index.json'), JSON.generate(entries.map do |entry|
          { identifier: entry.identifier }
        end))
        entries.each do |entry|
          filename = "#{entry.identifier}_#{Digest::SHA256.hexdigest(entry.identifier)[0, 8]}.json"
          File.write(File.join(dir, filename), JSON.generate(entry.to_h))
        end
      end
      actual = Woods::Obsidian::VaultExporter.new(index_dir: index, vault_path: @vault, output: StringIO.new)
      expect(actual.export_all).to include(exported: 4, skipped: 0, errors: [])
      expect(note('factories/reports.md')).to include('type: factory', '[[models/Account|Account]]')
      expect(note('database_views/reports.md')).to include('type: database_view', '[[models/User|User]]')
    end
  end

  it 'keeps targets ambiguous when a sibling is excluded and suppresses human association links too' do
    units.reject! { |entry| entry.type == :factory }
    units << unit(:rails_source, 'reports')
    units.find { |entry| entry.identifier == 'User' }.metadata = {
      associations: [{ type: :belongs_to, target: 'reports' }]
    }
    exporter.export_all
    expect(note('models/User.md')).not_to include('## Depends on', '## Associations')
    expect(manifest['schema_version']).to eq(2)
    expect(manifest['variants']).to be_empty
  end

  it 'does not smear bare analysis scores and annotations across distinct typed notes' do
    raw = reader.raw_graph_data.merge('pagerank' => { 'reports' => 0.75, 'User' => 0.2 })
    allow(reader).to receive(:raw_graph_data).and_return(raw)
    allow(reader).to receive(:graph_analysis).and_return(
      'hubs' => [{ 'identifier' => 'reports' }], 'orphans' => ['reports']
    )
    exporter.export_all
    %w[database_views factories].each do |folder|
      expect(note("#{folder}/reports.md")).not_to include('pagerank:', 'woods/hub', 'woods/orphan')
    end
    expect(note('models/User.md')).to include('pagerank: 0.2')
  end

  it 'keeps all bytes stable across repeated exports of one typed graph' do
    exporter.export_all
    before = Dir.glob(File.join(@vault, '**', '*'), File::FNM_DOTMATCH)
                .select { |path| File.file?(path) }.to_h { |path| [path, File.binread(path)] }
    exporter.export_all
    expect(before.keys.to_h { |path| [path, File.binread(path)] }).to eq(before)
  end

  it 'refuses to sweep after a mismatched typed read even with force purge enabled' do
    exporter.export_all
    allow(reader).to receive(:find_unit).and_wrap_original do |method, identifier, type: nil|
      method.call(identifier, type: type == 'factory' ? 'database_view' : type)
    end
    forced = Woods::Obsidian::VaultExporter.new(index_dir: 'unused', vault_path: @vault,
                                                reader: reader, output: StringIO.new, force_purge: true)
    expect(forced.export_all).to include(skipped: 1, swept: 0)
    expect(File).to exist(File.join(@vault, 'factories/reports.md'))
  end

  it 'retains an unreadable variant even when its index entry is missing' do
    exporter.export_all
    allow(reader).to receive(:list_units).and_return([{ 'identifier' => 'User' }])
    allow(reader).to receive(:find_unit).and_wrap_original do |method, identifier, type: nil|
      type == 'factory' ? nil : method.call(identifier, type: type)
    end
    expect(exporter.export_all).to include(skipped: 1, swept: 0)
    expect(File).to exist(File.join(@vault, 'factories/reports.md'))
  end

  it 'preserves the graph primary projection independently of registration order' do
    units.reverse!
    exporter.export_all
    expect(manifest['notes']['reports']['type']).to eq('database_view')
    expect(manifest['variants'].first['type']).to eq('factory')
  end

  it 'keeps typed notes distinct when sanitized type directories coincide' do
    units.replace([unit(:'custom:type', 'reports'), unit(:'custom/type', 'reports')])
    expect(exporter.export_all[:exported]).to eq(2)
    paths = manifest['paths'].keys
    expect(paths.size).to eq(2)
    expect(paths.map { |path| File.dirname(path) }.uniq).to eq(['custom_types'])
    expect(paths.map { |path| YAML.safe_load(note(path).split("\n---\n").first)['type'] })
      .to contain_exactly('custom:type', 'custom/type')
  end
end
