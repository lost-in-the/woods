# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods/resilience/incremental_readiness'
require 'woods/resilience/index_validator'
require 'woods/source_references/cache'
require 'woods/source_references/caller_policy'
require 'woods/payload_store'
require 'woods/generation'

RSpec.describe Woods::Resilience::IncrementalReadiness do
  around do |example|
    Dir.mktmpdir('woods-readiness') do |dir|
      @index = Pathname.new(dir).join('index')
      example.run
    end
  end

  let(:cache_class) { Woods::SourceReferences::Cache }
  let(:payload) { @index.join(Woods::PayloadStore.name_for(1)) }
  let(:cache_path) { payload.join(cache_class::FILE_NAME) }
  let(:graph_nodes) { { 'Post' => { 'type' => 'model', 'file_path' => 'app/models/post.rb' } } }

  def valid_cache
    { 'version' => cache_class::VERSION, 'callers' => Woods::SourceReferences::CallerPolicy.new({}).to_h,
      'files' => {}, 'owners' => [] }
  end

  def build_index(writer: Woods::VERSION, cache: valid_cache, nodes: graph_nodes, flat: false)
    dir = flat ? @index : Woods::PayloadStore.new(@index).create(1)
    dir.mkpath
    manifest = { 'total_units' => 0, 'counts' => {} }
    manifest['woods_version'] = writer if writer
    dir.join('manifest.json').write(JSON.generate(manifest))
    graph = { nodes: nodes, edges: {}, reverse: {}, file_map: {}, type_index: {} }
    dir.join('dependency_graph.json').write(JSON.generate(graph))
    cache_class.write(dir.join(cache_class::FILE_NAME), cache) if cache
    return if flat

    Woods::Generation.new(output_dir: @index).bump!(reason: 'full', payload: Woods::PayloadStore.name_for(1))
  end

  def readiness
    described_class.new(index_dir: @index).call
  end

  it 'is ready for a modern payload with a valid cache' do
    build_index

    expect(readiness).to have_attributes(ready?: true, reason: nil, to_s: 'ready')
  end

  it 'is ready without a cache when no unit could carry a source reference' do
    build_index(cache: nil, nodes: { 'config' => { 'type' => 'route', 'file_path' => 'config/routes.rb' } })

    expect(readiness).to be_ready
  end

  it 'needs a full extraction when the cache is missing but eligible units exist' do
    build_index(cache: nil)

    expect(readiness.to_s).to match(/\Aneeds full extraction \(.*source reference cache.*missing/i)
  end

  it 'needs a full extraction for a malformed cache, and is ready again once the bytes are restored' do
    build_index
    good = cache_path.binread
    cache_path.binwrite(good.sub('"owners":[]', '"owners":{}'))

    expect(readiness).not_to be_ready
    expect(readiness.to_s).to match(/\Aneeds full extraction \(.*source reference cache/i)

    cache_path.binwrite(good)
    expect(readiness).to be_ready
  end

  it 'needs a full extraction for a cache with a duplicate JSON key' do
    build_index
    cache_path.binwrite(cache_path.binread.sub('{', '{"version":7,'))

    expect(readiness).not_to be_ready
  end

  it 'needs a full extraction for a 1.x writer' do
    build_index(writer: '1.6.3')

    expect(readiness.to_s).to match(/needs full extraction \(.*Woods 1\.6\.3/)
  end

  it 'is ready when the manifest records no writer version' do
    build_index(writer: nil)

    expect(readiness).to be_ready
  end

  it 'needs a full extraction for a legacy flat index' do
    build_index(flat: true)

    expect(readiness.to_s).to match(/needs full extraction \(.*legacy flat index/)
  end

  it 'needs a full extraction when the manifest is unreadable' do
    build_index
    payload.join('manifest.json').write('{not json')

    expect(readiness.to_s).to match(/needs full extraction \(.*manifest/i)
  end

  it 'needs a full extraction when nothing is published' do
    @index.mkpath

    expect(readiness.to_s).to match(/needs full extraction \(.*no published index/i)
  end

  describe 'beside index validity' do
    it 'keeps a malformed-cache index reader-valid while reporting it not ready' do
      build_index(nodes: {})
      good = cache_path.binread
      cache_path.binwrite(good.sub('"owners":[]', '"owners":{}'))

      report = Woods::Resilience::IndexValidator.new(index_dir: @index.to_s).validate

      expect(report.errors).to eq([])
      expect(report.valid?).to be(true)
      expect(report.incremental.to_s).to match(/\Aneeds full extraction/)

      cache_path.binwrite(good)
      expect(Woods::Resilience::IndexValidator.new(index_dir: @index.to_s).validate.incremental).to be_ready
    end
  end
end
