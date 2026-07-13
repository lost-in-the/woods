# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'stringio'
require 'yaml'
require 'woods'
require 'woods/explorer/site_builder'

RSpec.describe Woods::Explorer::SiteBuilder do
  around do |example|
    Dir.mktmpdir do |dir|
      @index_dir = dir
      @out = File.join(dir, 'explorer')
      example.run
    end
  end

  let(:graph) do
    {
      'nodes' => {
        'Post' => { 'type' => 'model', 'file_path' => 'app/models/post.rb' },
        'Comment' => { 'type' => 'model', 'file_path' => 'app/models/comment.rb' }
      },
      'edges' => { 'Comment' => [{ 'target' => 'Post', 'via' => 'belongs_to' }] },
      'pagerank' => { 'Post' => 0.6, 'Comment' => 0.4 }
    }
  end

  let(:analysis) { { 'orphans' => [], 'dead_ends' => [], 'hubs' => [], 'cycles' => [], 'bridges' => [] } }
  let(:manifest) { { 'rails_version' => '8.0.1', 'total_units' => 2 } }

  let(:units) do
    {
      'Post' => { 'identifier' => 'Post', 'type' => 'model', 'file_path' => 'app/models/post.rb',
                  'metadata' => { 'table_name' => 'posts' } },
      'Comment' => { 'identifier' => 'Comment', 'type' => 'model',
                     'file_path' => 'app/models/comment.rb', 'metadata' => {} }
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

  def builder(**overrides)
    described_class.new(index_dir: 'unused', output_dir: @out, reader: reader,
                        output: StringIO.new, **overrides)
  end

  def read_out(rel)
    File.read(File.join(@out, rel), encoding: 'UTF-8')
  end

  def embedded_data_segment(html)
    html[%r{<script id="woods-data" type="application/json">(.*?)</script>}m, 1]
  end

  describe '#export_all' do
    it 'writes index.html, data.json, README.md, and the ownership sentinel' do
      builder.export_all
      %w[index.html data.json README.md .woods-explorer].each do |file|
        expect(File).to exist(File.join(@out, file)), "missing #{file}"
      end
    end

    it 'returns stats with path, node/edge/skip counters, and screen/flow counts' do
      expect(builder.export_all).to eq(path: @out, nodes: 2, edges: 1,
                                       screens: 0, flows: 0,
                                       skipped_units: 0, skipped_edges: 0)
    end

    it 'writes no flows.js and no flows.js script tag when the ops fit inline' do
      builder.export_all
      expect(File).not_to exist(File.join(@out, 'flows.js'))
      expect(read_out('index.html')).not_to include('<script src="flows.js"')
    end

    it 'embeds the exact data.json payload inside index.html' do
      builder.export_all
      segment = embedded_data_segment(read_out('index.html'))
      expect(segment).not_to be_nil
      expect(JSON.parse(segment)).to eq(JSON.parse(read_out('data.json')))
    end
  end

  describe 'script-injection hardening' do
    before do
      units['Post']['metadata']['table_name'] = 'x</script><script>alert(1)</script>'
      builder.export_all
    end

    let(:html) { read_out('index.html') }
    let(:segment) { embedded_data_segment(html) }

    it 'keeps only the two legitimate script tags — hostile openers and closers are both escaped' do
      # Openings: the data block and the app block. The payload's "<script"
      # is escaped to \u003Cscript to guard the tokenizer's double-escaped
      # states (a "<!--" + "<script" pair can keep the block open past the
      # real closer).
      expect(html.scan('<script').size).to eq(2)
      # Closers: only the two legitimate ones — the payload's is escaped.
      expect(html.scan('</script>').size).to eq(2)
    end

    it 'escapes every "</", "<!--" and "<script" in the embedded JSON' do
      expect(segment).not_to include('</')
      expect(segment).not_to include('<!--')
      expect(segment).not_to match(/<script/i)
      expect(segment).to include('<\/script>')
    end

    it 'round-trips the hostile value intact through the JSON escape' do
      post = JSON.parse(segment)['nodes'].find { |n| n['id'] == 'Post' }
      expect(post['facts']['table_name']).to eq('x</script><script>alert(1)</script>')
    end
  end

  describe 'flow packaging' do
    def write_flows_fixture
      flow_doc = {
        'entry_point' => 'PostsController#create',
        'route' => { 'verb' => 'POST', 'path' => '/posts' },
        'steps' => [
          { 'unit' => 'PostsController#create', 'type' => 'controller',
            'operations' => [{ 'type' => 'call', 'target' => 'Post',
                               'method' => 'create!', 'line' => 3 }] }
        ]
      }
      flows_dir = File.join(@index_dir, 'flows')
      FileUtils.mkdir_p(flows_dir)
      File.write(File.join(flows_dir, 'PostsController_create.json'), JSON.generate(flow_doc))
    end

    before { write_flows_fixture }

    def flow_builder
      builder(index_dir: @index_dir)
    end

    it 'embeds flow ops inline under the default limit and counts the flow in stats' do
      stats = flow_builder.export_all
      expect(stats[:flows]).to eq(1)
      expect(File).not_to exist(File.join(@out, 'flows.js'))
      embedded = JSON.parse(embedded_data_segment(read_out('index.html')))
      expect(embedded['flow_ops']).to eq([[{ 'u' => 'PostsController#create', 't' => 'controller',
                                             'ops' => [{ 't' => 'call', 'tgt' => 'Post',
                                                         'm' => 'create!', 'line' => 3 }] }]])
    end

    context 'when the compacted ops exceed FLOW_EMBED_LIMIT' do
      before do
        stub_const('Woods::Explorer::SiteBuilder::FLOW_EMBED_LIMIT', 10)
        flow_builder.export_all
      end

      it 'writes the ops to a flows.js sidecar assigning window.WOODS_FLOWOPS' do
        flows_js = read_out('flows.js')
        expect(flows_js).to start_with('window.WOODS_FLOWOPS = ')
        expect(flows_js).to include('PostsController#create')
      end

      it 'replaces the embedded flow_ops with the external marker' do
        embedded = JSON.parse(embedded_data_segment(read_out('index.html')))
        expect(embedded['flow_ops']).to eq('external:flows.js')
      end

      it 'references the sidecar with a script tag in index.html' do
        expect(read_out('index.html')).to include('<script src="flows.js"></script>')
      end

      it 'still writes the full flow_ops into data.json' do
        flow_ops = JSON.parse(read_out('data.json'))['flow_ops']
        expect(flow_ops).to be_an(Array)
        expect(flow_ops.first.first).to include('u' => 'PostsController#create')
      end
    end
  end

  describe 'screen labels via labels_path' do
    let(:graph) do
      super().tap do |g|
        g['nodes'] = g['nodes'].merge(
          'PostsController' => { 'type' => 'controller',
                                 'file_path' => 'app/controllers/posts_controller.rb' }
        )
      end
    end

    let(:units) do
      super().merge(
        'PostsController' => {
          'identifier' => 'PostsController', 'type' => 'controller',
          'file_path' => 'app/controllers/posts_controller.rb',
          'metadata' => { 'actions' => %w[index],
                          'routes' => { 'index' => [{ 'verb' => 'GET', 'path' => '/posts' }] } }
        }
      )
    end

    def screen_for(id)
      JSON.parse(read_out('data.json'))['screens'].find { |s| s['id'] == id }
    end

    it 'accepts a labels_path and applies its screen labels to the payload' do
      labels_file = File.join(@index_dir, 'woods_labels.yml')
      File.write(labels_file, { 'screens' => { 'PostsController#index' => 'The Feed' } }.to_yaml)
      builder(labels_path: labels_file).export_all
      expect(screen_for('PostsController#index')['label']).to eq('The Feed')
    end

    it 'falls back to humanized labels when no labels file exists' do
      builder.export_all
      expect(screen_for('PostsController#index')['label']).to eq('Posts — Index')
    end
  end

  describe 'idempotency' do
    def snapshot
      Dir.glob(File.join(@out, '**', '*'), File::FNM_DOTMATCH)
         .select { |f| File.file?(f) }
         .sort
         .to_h { |f| [f, File.binread(f)] }
    end

    it 'produces byte-identical output on re-export' do
      builder.export_all
      first = snapshot
      builder.export_all
      expect(snapshot).to eq(first)
    end
  end

  describe 'ownership guard' do
    it 'raises ExportError for a non-empty foreign directory without the sentinel' do
      FileUtils.mkdir_p(@out)
      File.write(File.join(@out, 'precious.txt'), 'mine')
      expect { builder.export_all }
        .to raise_error(Woods::Explorer::ExportError, /\.woods-explorer sentinel/)
      expect(File.read(File.join(@out, 'precious.txt'))).to eq('mine')
    end

    it 'overwrites a foreign directory when force is set' do
      FileUtils.mkdir_p(@out)
      File.write(File.join(@out, 'precious.txt'), 'mine')
      expect { builder(force: true).export_all }.not_to raise_error
      expect(File).to exist(File.join(@out, 'index.html'))
    end

    it 'overwrites a directory that carries the sentinel' do
      FileUtils.mkdir_p(@out)
      File.write(File.join(@out, described_class::SENTINEL), 'woods-managed')
      File.write(File.join(@out, 'index.html'), 'stale')
      expect { builder.export_all }.not_to raise_error
      expect(read_out('index.html')).not_to eq('stale')
    end

    it 'writes into an existing empty directory without complaint' do
      FileUtils.mkdir_p(@out)
      expect { builder.export_all }.not_to raise_error
    end
  end

  describe 'reader bootstrapping' do
    it 'raises a readable ExportError pointing at woods:extract when the index is missing' do
      Dir.mktmpdir do |empty|
        expect { described_class.new(index_dir: empty, output_dir: @out, output: StringIO.new) }
          .to raise_error(Woods::Explorer::ExportError, /woods:extract/)
      end
    end
  end
end
