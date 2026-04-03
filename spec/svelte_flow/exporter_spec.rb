# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'time'
require 'woods'
require 'woods/svelte_flow/exporter'

RSpec.describe Woods::SvelteFlow::Exporter do
  let(:tmpdir) { Dir.mktmpdir('woods_svelte_flow_test') }

  after { FileUtils.rm_rf(tmpdir) }

  let(:graph_data) do
    graph = Woods::DependencyGraph.new
    unit = instance_double(
      'Woods::ExtractedUnit',
      identifier: 'User',
      type: :model,
      file_path: 'app/models/user.rb',
      namespace: nil,
      dependencies: [{ target: 'Post' }]
    )
    graph.register(unit)

    unit2 = instance_double(
      'Woods::ExtractedUnit',
      identifier: 'Post',
      type: :model,
      file_path: 'app/models/post.rb',
      namespace: nil,
      dependencies: []
    )
    graph.register(unit2)

    graph.to_h
  end

  before do
    # Set up mock extraction output
    File.write(File.join(tmpdir, 'manifest.json'), JSON.generate(
                                                     extracted_at: Time.now.iso8601,
                                                     total_units: 2
                                                   ))
    File.write(File.join(tmpdir, 'dependency_graph.json'), JSON.generate(graph_data))
  end

  describe '#initialize' do
    it 'creates an exporter with valid index directory' do
      exporter = described_class.new(index_dir: tmpdir)
      expect(exporter).to be_a(described_class)
    end

    it 'raises ExtractionError for missing index directory' do
      expect do
        described_class.new(index_dir: '/nonexistent/path')
      end.to raise_error(Woods::ExtractionError, /No extraction output found/)
    end

    it 'defaults output_dir to index_dir/svelte_flow' do
      exporter = described_class.new(index_dir: tmpdir)
      stats = exporter.export_all

      expect(stats[:output_dir]).to eq(File.join(tmpdir, 'svelte_flow'))
    end

    it 'accepts custom output_dir' do
      custom_dir = File.join(tmpdir, 'custom_output')
      exporter = described_class.new(index_dir: tmpdir, output_dir: custom_dir)
      stats = exporter.export_all

      expect(stats[:output_dir]).to eq(custom_dir)
    end
  end

  describe '#export_all' do
    subject { described_class.new(index_dir: tmpdir) }

    let(:stats) { subject.export_all }

    it 'returns export statistics' do
      expect(stats).to have_key(:nodes)
      expect(stats).to have_key(:edges)
      expect(stats).to have_key(:clusters)
      expect(stats).to have_key(:flows)
      expect(stats).to have_key(:output_dir)
    end

    it 'writes dependency_graph.json' do
      stats
      path = File.join(tmpdir, 'svelte_flow', 'dependency_graph.json')
      expect(File.exist?(path)).to be true

      data = JSON.parse(File.read(path))
      expect(data).to have_key('nodes')
      expect(data).to have_key('edges')
    end

    it 'writes domain_clusters.json' do
      stats
      path = File.join(tmpdir, 'svelte_flow', 'domain_clusters.json')
      expect(File.exist?(path)).to be true
    end

    it 'writes manifest.json' do
      stats
      path = File.join(tmpdir, 'svelte_flow', 'manifest.json')
      expect(File.exist?(path)).to be true

      manifest = JSON.parse(File.read(path))
      expect(manifest).to have_key('generated_at')
      expect(manifest).to have_key('node_count')
      expect(manifest).to have_key('edge_count')
    end

    it 'reports correct node count' do
      expect(stats[:nodes]).to eq(2)
    end

    it 'reports correct edge count' do
      expect(stats[:edges]).to eq(1)
    end
  end

  describe '#export_flows' do
    subject { described_class.new(index_dir: tmpdir) }

    context 'when no flows exist' do
      it 'returns zero flow count' do
        expect(subject.export_flows).to eq({ flow_count: 0 })
      end
    end

    context 'when flows exist' do
      before do
        flows_dir = File.join(tmpdir, 'flows')
        FileUtils.mkdir_p(flows_dir)

        flow_doc = {
          entry_point: 'UsersController#index',
          route: { verb: 'GET', path: '/users' },
          max_depth: 5,
          steps: [
            { unit: 'UsersController#index', type: 'controller', operations: [] }
          ]
        }

        flow_path = File.join(flows_dir, 'UsersController__index.json')
        File.write(flow_path, JSON.generate(flow_doc))
        File.write(
          File.join(flows_dir, 'flow_index.json'),
          JSON.generate({ 'UsersController#index' => flow_path })
        )
      end

      it 'exports flow visualizations' do
        stats = subject.export_flows
        expect(stats[:flow_count]).to eq(1)
      end

      it 'writes flow files to svelte_flow/flows/' do
        subject.export_flows
        flow_files = Dir.glob(File.join(tmpdir, 'svelte_flow', 'flows', '*.json'))
        # flow_index.json + one flow file
        expect(flow_files.size).to eq(2)
      end
    end
  end

  describe '#load_unit_metadata' do
    before do
      # Create a mock type directory with unit files
      model_dir = File.join(tmpdir, 'model')
      FileUtils.mkdir_p(model_dir)

      unit_data = {
        'type' => 'model',
        'identifier' => 'User',
        'metadata' => {
          'primary_key' => 'id',
          'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false }],
          'associations' => []
        }
      }
      File.write(File.join(model_dir, 'User_abcd1234.json'), JSON.generate(unit_data))

      # Write an _index.json that should be skipped
      File.write(File.join(model_dir, '_index.json'), JSON.generate([{ 'identifier' => 'User' }]))
    end

    it 'loads metadata from type directory unit files' do
      exporter = described_class.new(index_dir: tmpdir)
      metadata = exporter.send(:load_unit_metadata)

      expect(metadata).to have_key('User')
      expect(metadata['User']['metadata']['columns']).to be_an(Array)
    end

    it 'skips _index.json files' do
      exporter = described_class.new(index_dir: tmpdir)
      metadata = exporter.send(:load_unit_metadata)

      # Only the unit file should be loaded, not the index
      expect(metadata.size).to eq(1)
    end

    it 'skips svelte_flow and flows directories' do
      # Create directories that should be skipped
      FileUtils.mkdir_p(File.join(tmpdir, 'svelte_flow'))
      File.write(File.join(tmpdir, 'svelte_flow', 'not_a_unit.json'), '{"identifier":"fake"}')

      FileUtils.mkdir_p(File.join(tmpdir, 'flows'))
      File.write(File.join(tmpdir, 'flows', 'not_a_unit.json'), '{"identifier":"fake2"}')

      exporter = described_class.new(index_dir: tmpdir)
      metadata = exporter.send(:load_unit_metadata)

      expect(metadata).not_to have_key('fake')
      expect(metadata).not_to have_key('fake2')
    end

    it 'handles malformed JSON gracefully' do
      bad_dir = File.join(tmpdir, 'service')
      FileUtils.mkdir_p(bad_dir)
      File.write(File.join(bad_dir, 'bad_service.json'), 'not valid json{{{')

      exporter = described_class.new(index_dir: tmpdir)
      metadata = exporter.send(:load_unit_metadata)

      # Should still have User from model dir, bad file skipped
      expect(metadata).to have_key('User')
      expect(metadata.size).to eq(1)
    end
  end
end
