# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/mcp/bootstrapper'

RSpec.describe Woods::MCP::PublishedLexicalRetriever do
  let(:index_dir) { Dir.mktmpdir('woods-lexical-spec') }
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:retriever) { described_class.new(index_dir: index_dir) }

  before { FileUtils.cp_r("#{fixture_dir}/.", index_dir) }
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
    expect { retriever.retrieve('Post') }.to raise_error(Woods::Retriever::StoreError, /lexical index read failed/)
  end

  it 'fails explicit lexical bootstrap when the published manifest is absent' do
    Woods.configuration.retrieval_mode = :lexical
    FileUtils.rm(File.join(index_dir, 'manifest.json'))
    expect { Woods::MCP::Bootstrapper.build_retriever(index_dir: index_dir) }
      .to raise_error(Woods::MCP::BootstrapError, /lexical index could not be loaded/)
  end
end
