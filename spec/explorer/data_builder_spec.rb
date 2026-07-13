# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/explorer/data_builder'

RSpec.describe Woods::Explorer::DataBuilder do
  # Sorted app node order (framework excluded):
  #   0 Comment, 1 Ghost, 2 Post, 3 PostsController
  let(:graph) do
    {
      'nodes' => {
        'Post' => { 'type' => 'model', 'file_path' => 'app/models/post.rb' },
        'Comment' => { 'type' => 'model', 'file_path' => 'app/models/comment.rb' },
        'PostsController' => { 'type' => 'controller',
                               'file_path' => 'app/controllers/posts_controller.rb' },
        'ActiveRecord::Base' => { 'type' => 'rails_source' },
        'Ghost' => { 'type' => 'model' }
      },
      'edges' => {
        'Comment' => [{ 'target' => 'Post', 'via' => 'belongs_to' }],
        'Post' => [{ 'target' => 'Comment', 'via' => 'has_many' },
                   { 'target' => 'ActiveRecord::Base', 'via' => 'code_reference' }],
        'PostsController' => [{ 'target' => 'Post', 'via' => 'code_reference' },
                              { 'target' => 'Ghost', 'via' => 'code_reference' },
                              'Comment']
      },
      'pagerank' => { 'Post' => 0.5, 'Comment' => 0.3, 'PostsController' => 0.1,
                      'ActiveRecord::Base' => 0.0421009876 },
      'stats' => { 'node_count' => 5 }
    }
  end

  let(:analysis) do
    {
      'orphans' => ['Ghost', 'ActiveRecord::Base'],
      'dead_ends' => ['Comment'],
      'hubs' => [{ 'identifier' => 'Post', 'dependent_count' => 2 },
                 { 'identifier' => 'ActiveRecord::Base', 'dependent_count' => 9 }],
      'cycles' => [%w[Post Comment], %w[Post ActiveRecord::Base]],
      'bridges' => [{ 'identifier' => 'PostsController', 'score' => 0.9 },
                    { 'identifier' => 'ActiveRecord::Base', 'score' => 0.4 }],
      'stats' => { 'orphan_count' => 2 }
    }
  end

  let(:manifest) do
    { 'extracted_at' => '2026-07-01T00:00:00Z', 'rails_version' => '8.0.1',
      'ruby_version' => '3.3.6', 'git_branch' => 'main', 'git_sha' => 'abc123',
      'total_units' => 42 }
  end

  let(:units) do
    {
      'Post' => { 'identifier' => 'Post', 'type' => 'model', 'file_path' => 'app/models/post.rb',
                  'metadata' => { 'table_name' => 'posts',
                                  'columns' => [{ 'name' => 'id', 'type' => 'integer' }] } },
      'Comment' => { 'identifier' => 'Comment', 'type' => 'model',
                     'file_path' => 'app/models/comment.rb', 'metadata' => {} },
      'PostsController' => { 'identifier' => 'PostsController', 'type' => 'controller',
                             'file_path' => 'app/controllers/posts_controller.rb',
                             'metadata' => { 'actions' => %w[index] } },
      'ActiveRecord::Base' => { 'identifier' => 'ActiveRecord::Base', 'type' => 'rails_source',
                                'metadata' => {} }
    }
  end

  let(:reader) do
    instance_double('Woods::MCP::IndexReader').tap do |r|
      allow(r).to receive(:raw_graph_data).and_return(graph)
      allow(r).to receive(:graph_analysis).and_return(analysis)
      allow(r).to receive(:manifest).and_return(manifest)
      allow(r).to receive(:find_unit) { |id| units[id] }
    end
  end

  def build(**overrides)
    described_class.new(reader: reader, **overrides)
  end

  describe '#build' do
    let(:builder) { build }
    let(:payload) { builder.build }

    it 'stamps the versioned schema key' do
      expect(payload['schema']).to eq('woods-explorer/1')
    end

    it 'sorts nodes by identifier and excludes framework nodes by default' do
      expect(payload['nodes'].map { |n| n['id'] }).to eq(%w[Comment Ghost Post PostsController])
    end

    it 'includes framework nodes when include_framework is set' do
      ids = build(include_framework: true).build['nodes'].map { |n| n['id'] }
      expect(ids).to eq(['ActiveRecord::Base', 'Comment', 'Ghost', 'Post', 'PostsController'])
    end

    it 'emits [source_idx, target_idx, via] triples indexed into the sorted node list' do
      expect(payload['edges']).to eq([[0, 2, 'belongs_to'], [2, 0, 'has_many'], [3, 0, ''],
                                      [3, 1, 'code_reference'], [3, 2, 'code_reference']])
    end

    it 'gives a legacy bare-string edge an empty via label' do
      expect(payload['edges']).to include([3, 0, ''])
    end

    it 'drops edges pointing at excluded nodes and counts them in stats' do
      targets = payload['edges'].map { |(_s, t, _v)| payload['nodes'][t]['id'] }
      expect(targets).not_to include('ActiveRecord::Base')
      expect(builder.stats[:skipped_edges]).to eq(1)
    end

    it 'keeps the framework edge when include_framework is set' do
      framework_builder = build(include_framework: true)
      framework_builder.build
      expect(framework_builder.stats[:skipped_edges]).to eq(0)
    end

    it 'computes in/out degrees from the surviving edges' do
      degrees = payload['nodes'].to_h { |n| [n['id'], [n['in'], n['out']]] }
      expect(degrees).to eq('Comment' => [2, 1], 'Ghost' => [1, 0],
                            'Post' => [2, 1], 'PostsController' => [0, 3])
    end

    it 'carries pagerank rounded to 6 places, defaulting to 0.0 for unranked nodes' do
      by_id = payload['nodes'].to_h { |n| [n['id'], n['pagerank']] }
      expect(by_id['Post']).to eq(0.5)
      expect(by_id['Ghost']).to eq(0.0)
      framework = build(include_framework: true).build['nodes'].find { |n| n['id'] == 'ActiveRecord::Base' }
      expect(framework['pagerank']).to eq(0.042101)
    end

    it 'marks a node whose unit JSON is missing and counts it as skipped' do
      ghost = payload['nodes'].find { |n| n['id'] == 'Ghost' }
      expect(ghost).to include('no_unit' => true, 'facts' => {}, 'summary' => 'model')
      expect(builder.stats[:skipped_units]).to eq(1)
    end

    it 'does not flag nodes whose unit loaded' do
      post = payload['nodes'].find { |n| n['id'] == 'Post' }
      expect(post).not_to have_key('no_unit')
      expect(post['facts']).to include('table_name' => 'posts')
    end

    it 'labels nodes with the demodulized identifier and family group' do
      framework = build(include_framework: true).build['nodes'].find { |n| n['id'] == 'ActiveRecord::Base' }
      expect(framework).to include('label' => 'Base', 'group' => 'other')
      post = payload['nodes'].find { |n| n['id'] == 'Post' }
      expect(post).to include('label' => 'Post', 'group' => 'data')
    end

    it 'remaps analysis identifiers to node indices, dropping excluded ones' do
      expect(payload['analysis']).to eq(
        'orphans' => [1],
        'dead_ends' => [0],
        'hubs' => [{ 'node' => 2, 'dependent_count' => 2 }],
        'cycles' => [[2, 0]],
        'bridges' => [{ 'node' => 3, 'score' => 0.9 }],
        'stats' => { 'orphan_count' => 2 }
      )
    end

    it 'sorts type counts by count descending' do
      expect(payload['types']).to eq('model' => 3, 'controller' => 1)
      expect(payload['types'].keys).to eq(%w[model controller])
    end

    it 'sorts via counts by count descending then name' do
      expect(payload['via_counts'].keys).to eq(['code_reference', '', 'belongs_to', 'has_many'])
      expect(payload['via_counts']['code_reference']).to eq(2)
    end

    it 'picks app provenance from the manifest' do
      expect(payload['app']).to eq('extracted_at' => '2026-07-01T00:00:00Z',
                                   'rails_version' => '8.0.1', 'ruby_version' => '3.3.6',
                                   'git_branch' => 'main', 'git_sha' => 'abc123',
                                   'total_units' => 42)
    end

    it 'records meta counters and the verbatim graph stats' do
      expect(payload['meta']).to eq('include_framework' => false, 'skipped_units' => 1,
                                    'skipped_edges' => 1, 'graph_stats' => { 'node_count' => 5 })
    end

    it 'raises ExportError when the graph has no nodes' do
      allow(reader).to receive(:raw_graph_data).and_return({ 'nodes' => {} })
      expect { build.build }.to raise_error(Woods::Explorer::ExportError, /no nodes/)
    end

    it 'is deterministic — two independent builds produce equal payloads' do
      expect(build.build).to eq(build.build)
    end
  end
end
