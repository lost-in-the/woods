# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'stringio'
require 'woods'
require 'woods/explorer/site_builder'

RSpec.describe Woods::Explorer::SiteBuilder do
  around do |example|
    Dir.mktmpdir do |dir|
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

    it 'returns stats with path and node/edge/skip counters' do
      expect(builder.export_all).to eq(path: @out, nodes: 2, edges: 1,
                                       skipped_units: 0, skipped_edges: 0)
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
