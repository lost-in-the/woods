# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/mcp/bootstrapper'
require 'woods/mcp/server'

RSpec.describe Woods::MCP::PublishedLexicalRetriever do
  let(:index_dir) { Dir.mktmpdir('woods-lexical-spec') }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:retriever) { described_class.new(index_dir: index_dir) }

  before do
    Woods.configuration = Woods::Configuration.new
    FileUtils.cp_r("#{fixture_dir}/.", index_dir)
  end
  after { FileUtils.rm_rf(index_dir) }

  it 'loads extract-only published units and attributes typed sources' do
    result = retriever.retrieve('publish', types: ['concern'])
    expect(result.strategy).to eq(:lexical)
    expect(result.sources).not_to be_empty
    expect(result.sources.map { |source| source[:type] }.uniq).to eq(['concern'])
    expect(retriever.vector_store).to be_nil
  end

  it 'skips provider resolution, probes and vector artifact loading at bootstrap' do
    Woods.configuration.retrieval_mode = :lexical
    expect(Woods::MCP::ConfigResolver).not_to receive(:resolve)
    expect(Woods::MCP::Bootstrapper).not_to receive(:build_artifact)
    expect(Woods::Storage::Snapshotter::Vector).not_to receive(:load_or_empty)
    built, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: index_dir)
    expect(built.retrieve('Post').sources).not_to be_empty
    expect(state.status).to eq(:hydrated)
  end

  it 'refuses a corrupt published unit instead of returning partial success' do
    unit_file = Dir.glob(File.join(index_dir, 'models', '*.json')).reject { |path| path.end_with?('_index.json') }.first
    File.write(unit_file, '{broken')
    expect { retriever.retrieve('Post') }.to raise_error(Woods::Retriever::StoreError, /JSON::ParserError/)
  end

  it 'reports lexical mode without claiming active embeddings and returns typed lexical errors' do
    server = Woods::MCP::Server.build(index_dir: index_dir, retriever: retriever, warmup: false)
    status = Woods::MCP::Server.build_status(reader: retriever.reader, retriever: retriever, index_dir: index_dir)
    expect(status[:retriever]).to include(configured: true, mode: 'lexical')
    expect(status[:features]).to include(embedding_provider: nil, embedding_model: nil, vector_store: nil)
    unit = Dir.glob(File.join(index_dir, 'models', 'Post_*.json')).fetch(0)
    File.write(unit, '{broken')
    response = server.tools.fetch('codebase_retrieve').call(query: 'Post', server_context: {})
    expect(response.error?).to be(true)
    expect(response.meta).to include(error_code: :degraded_index, mode: 'lexical', stores: ['metadata'])
    expect(response.content.first[:text]).to include('Lexical retrieval is degraded')
    expect(response.content.first[:text]).not_to include('woods:embed')
  end

  it 'rejects symlinked units and mismatched typed identities' do
    unit_file = Dir.glob(File.join(index_dir, 'models', 'Post_*.json')).fetch(0)
    data = File.read(unit_file)
    File.unlink(unit_file)
    File.symlink(File.join(fixture_dir, 'models', File.basename(unit_file)), unit_file)
    expect { retriever.retrieve('Post') }.to raise_error(Woods::Retriever::StoreError, /symlink/)
    File.unlink(unit_file)
    File.write(unit_file, data.sub('"type": "model"', '"type": "service"'))
    expect { retriever.retrieve('Post') }.to raise_error(Woods::Retriever::StoreError, /typed unit identity/)
  end

  it 'rejects a missing indexed unit instead of counting it as no match' do
    File.unlink(Dir.glob(File.join(index_dir, 'models', 'Post_*.json')).fetch(0))
    expect { retriever.retrieve('Post') }.to raise_error(Woods::Retriever::StoreError, /ENOENT/)
  end

  def publish_payload(name, source)
    relative = "payloads/#{name}"
    target = File.join(index_dir, relative)
    FileUtils.mkdir_p(target)
    FileUtils.cp_r("#{fixture_dir}/.", target)
    post = Dir.glob(File.join(target, 'models', 'Post_*.json')).fetch(0)
    data = JSON.parse(File.read(post))
    data['source_code'] = source
    File.write(post, JSON.generate(data))
    Woods::Generation.new(output_dir: index_dir).bump!(payload: relative)
  end

  it 'holds one generation during a query and adopts the next publication afterwards' do
    publish_payload('one', 'oldword')
    retriever.warmup!
    retriever.snapshot.last.pipeline_observer = ->(_) { publish_payload('two', 'newword') }
    first = retriever.retrieve('oldword')
    expect(first.context).to include('oldword')
    expect(first.sources.map { |source| source[:generation] }.uniq).to eq([1])
    second = retriever.retrieve('newword')
    expect(second.context).to include('newword')
    expect(second.sources.map { |source| source[:generation] }.uniq).to eq([2])
  end

  it 'does not reuse a snapshot when the generation number repeats with a different token' do
    publish_payload('one', 'oldword')
    retriever.warmup!
    post = Dir.glob(File.join(index_dir, 'payloads/one/models/Post_*.json')).fetch(0)
    data = JSON.parse(File.read(post)).merge('source_code' => 'newword')
    File.write(post, JSON.generate(data))
    marker = File.join(index_dir, 'generation.json')
    data = JSON.parse(File.read(marker)).merge('number' => 1, 'token' => 'different-publisher')
    File.write(marker, JSON.generate(data))
    expect(retriever.retrieve('newword').context).to include('newword')
    expect(retriever.retrieve('oldword').sources).to be_empty
  end

  it 'refuses corrupt generation markers instead of silently serving a cached snapshot' do
    publish_payload('one', 'oldword')
    retriever.warmup!
    File.write(File.join(index_dir, 'generation.json'), '{broken')
    expect { retriever.retrieve('oldword') }.to raise_error(Woods::Retriever::StoreError, /JSON::ParserError/)
  end

  it 'rejects an A-to-B-to-A publication race during reload' do
    publish_payload('one', 'oldword')
    retriever.warmup!
    old = retriever.snapshot
    marker_path = File.join(index_dir, 'generation.json')
    first_marker = File.read(marker_path)
    allow(described_class).to receive(:new).and_wrap_original do |original, **options|
      publish_payload('two', 'newword')
      original.call(**options)
    end
    hooks = { after_candidates: -> { File.write(marker_path, first_marker) } }
    expect do
      Woods::MCP::Bootstrapper.reload_stores!(retriever, index_dir: index_dir, hooks: hooks)
    end.to raise_error(Woods::MCP::ReloadGenerationMoved)
    expect(retriever.snapshot).to equal(old)
  end

  it 'leaves the old snapshot installed when reader reload fails' do
    publish_payload('one', 'oldword')
    retriever.warmup!
    old = retriever.snapshot
    allow(retriever.reader).to receive(:reload!).and_raise(IOError, 'reader refresh failed')
    expect do
      Woods::MCP::Bootstrapper.reload_stores!(retriever, index_dir: index_dir)
    end.to raise_error(Woods::MCP::ReloadDegraded, /reader refresh failed/)
    expect(retriever.snapshot).to equal(old)
  end

  it 'preserves the old snapshot on a failed explicit reload and recovers on a valid reload' do
    publish_payload('one', 'oldword')
    retriever.warmup!
    old = retriever.snapshot
    post = Dir.glob(File.join(index_dir, 'payloads/one/models/Post_*.json')).fetch(0)
    saved = File.read(post)
    File.write(post, '{broken')
    expect do
      Woods::MCP::Bootstrapper.reload_stores!(retriever, index_dir: index_dir)
    end.to raise_error(Woods::MCP::ReloadDegraded, /lexical snapshot reload failed/)
    expect(retriever.snapshot).to equal(old)
    File.write(post, saved)
    counts = Woods::MCP::Bootstrapper.reload_stores!(retriever, index_dir: index_dir)
    expect(counts).to include(vectors: 0, metadata: 9, graph: 0)
    expect(retriever.retrieve('oldword').context).to include('oldword')
  end

  it 'fails explicit lexical bootstrap when the published manifest is absent' do
    Woods.configuration.retrieval_mode = :lexical
    FileUtils.rm(File.join(index_dir, 'manifest.json'))
    expect { Woods::MCP::Bootstrapper.build_retriever(index_dir: index_dir) }
      .to raise_error(Woods::MCP::BootstrapError, /lexical index could not be loaded/)
  end
end
