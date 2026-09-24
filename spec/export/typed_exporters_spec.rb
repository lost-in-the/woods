# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'stringio'
require 'woods/extracted_unit'
require 'woods/mcp/index_reader'
require 'woods/notion/exporter'
require 'woods/unblocked/exporter'

RSpec.describe 'Typed export selection with a published IndexReader' do
  around do |example|
    Dir.mktmpdir('woods-typed-export') do |dir|
      @index_dir = dir
      example.run
    end
  end

  let(:config) do
    Woods::Configuration.new.tap do |value|
      value.notion_api_token = 'local-test-token'
      value.notion_database_ids = { data_models: 'models-db', columns: 'columns-db' }
      value.unblocked_collection_id = 'collection'
      value.unblocked_api_token = 'local-test-token'
      value.unblocked_repo_url = 'https://example.invalid/repo'
    end
  end
  let(:pages) { [] }
  let(:documents) { [] }
  let(:remote_documents) { {} }
  let(:notion_client) do
    instance_double(Woods::Notion::Client).tap do |client|
      allow(client).to receive(:find_page_by_title).and_return(nil)
      allow(client).to receive(:query_database).and_return('results' => [])
      allow(client).to receive(:create_page) do |**arguments|
        pages << arguments
        { 'id' => "page-#{pages.size}" }
      end
    end
  end
  let(:unblocked_client) do
    instance_double(Woods::Unblocked::Client).tap do |client|
      allow(client).to receive(:all_documents) { remote_documents.values }
      allow(client).to receive(:delete_document).and_return({})
      allow(client).to receive(:put_document) do |**arguments|
        documents << arguments
        id = remote_documents.dig(arguments[:uri], 'id') || "doc-#{documents.size}"
        remote_documents[arguments[:uri]] = { 'id' => id, 'uri' => arguments[:uri],
                                             'collectionId' => arguments[:collection_id] }
        { 'id' => id }
      end
    end
  end

  def unit(type, identifier = 'Report', file_path: "#{type}/report.rb")
    Woods::ExtractedUnit.new(type: type.to_sym, identifier: identifier, file_path: file_path).tap do |item|
      item.source_code = "# #{type} source\nclass #{identifier}; end"
      item.metadata = { table_name: "#{type}_reports", columns: [{ name: "#{type}_only", type: 'string' }] }
    end
  end

  def publish(*units)
    File.write(File.join(@index_dir, 'manifest.json'), JSON.generate(total_units: units.size, git_branch: 'main'))
    units.group_by { |item| directory(item.type) }.each do |dir, entries|
      FileUtils.mkdir_p(File.join(@index_dir, dir))
      # Legacy indexes omit type; actual type comes from the unit document.
      index = entries.map { |item| { identifier: item.identifier, file_path: item.file_path } }
      File.write(File.join(@index_dir, dir, '_index.json'), JSON.generate(index))
      entries.each { |item| File.write(unit_path(item), JSON.generate(item.to_h)) }
    end
    Woods::MCP::IndexReader.new(@index_dir)
  end

  def directory(type)
    Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR.find { |_, types| types.include?(type.to_s) }.first
  end

  def unit_path(item)
    base = item.identifier.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
    File.join(@index_dir, directory(item.type), "#{base}_#{Digest::SHA256.hexdigest(item.identifier)[0, 8]}.json")
  end

  def notion(reader)
    Woods::Notion::Exporter.new(index_dir: @index_dir, config: config, reader: reader, client: notion_client)
  end

  def unblocked(reader, **options)
    Woods::Unblocked::Exporter.new(index_dir: @index_dir, config: config, reader: reader,
                                   client: unblocked_client, output: StringIO.new, **options)
  end

  def existing_manifest
    Woods::Unblocked::SyncManifest.new(path: File.join(@index_dir, 'unblocked_sync_manifest.json'),
                                       collection_id: 'collection').tap do |manifest|
      manifest.record(uri: 'https://example.invalid/repo/blob/main/model/report.rb',
                      hash: 'old', document_id: 'existing-model')
      manifest.save
    end
  end

  it 'maps only the model payload to Notion models and columns despite a same-named poro' do
    reader = publish(unit('model'), unit('poro'))
    expect(reader.find_unit('Report')['type']).to eq('poro') # exercises the original collision
    expect(notion(reader).sync_all).to include(data_models: 1, columns: 1, errors: [])
    expect(JSON.generate(pages)).to include('model_reports', 'model_only')
    expect(JSON.generate(pages)).not_to include('poro_reports', 'poro_only')
  end

  it 'uses the migration variant for Notion schema dates' do
    migration = unit('migration', 'CreateReports')
    migration.metadata = { tables_affected: ['model_reports'], migration_version: '20260102030405' }
    reader = publish(unit('model'), migration, unit('poro', 'CreateReports'))
    notion(reader).sync_data_models
    expect(pages.first[:properties]['Last Schema Change']).to eq(date: { start: '2026-01-02T03:04:05Z' })
  end

  it 'refuses a missing model without API writes or pruning its existing Notion manifest' do
    model = unit('model')
    notion(publish(model)).sync_all
    path = File.join(@index_dir, 'notion_sync_manifest.json')
    File.write(path, "#{JSON.generate(JSON.parse(File.read(path)))}\n\n")
    before = File.binread(path)
    pages.clear
    File.unlink(unit_path(model))
    expect do
      notion(Woods::MCP::IndexReader.new(@index_dir)).sync_all
    end.to raise_error(Woods::ExtractionError, /incomplete/)
    expect(pages).to be_empty
    expect(File.binread(path)).to eq(before)
  end

  it 'refuses a mismatched model payload before any Notion API write' do
    model = unit('model')
    reader = publish(model)
    File.write(unit_path(model), JSON.generate(unit('poro').to_h))
    expect { notion(reader).sync_all }.to raise_error(Woods::ExtractionError, /identity/)
    expect(pages).to be_empty
  end

  %w[missing malformed count_mismatch].each do |corruption|
    it "refuses a #{corruption} model index before Notion writes or manifest pruning" do
      notion(publish(unit('model'))).sync_all
      manifest_path = File.join(@index_dir, 'notion_sync_manifest.json')
      before = File.binread(manifest_path)
      File.write(File.join(@index_dir, 'manifest.json'), JSON.generate(total_units: 1, counts: { models: 1 }))
      path = File.join(@index_dir, 'models', '_index.json')
      if corruption == 'missing'
        File.unlink(path)
      else
        File.write(path, corruption == 'malformed' ? '{}' : '[]')
      end
      pages.clear
      expect { notion(Woods::MCP::IndexReader.new(@index_dir)).sync_all }.to raise_error(Woods::ExtractionError)
      expect(pages).to be_empty
      expect(File.binread(manifest_path)).to eq(before)
    end
  end

  %i[sync_data_models sync_columns].each do |operation|
    it "keeps standalone #{operation} reads and page mapping inside one generation pin" do
      reader = publish(unit('model'))
      depth = 0
      observations = []
      allow(reader).to receive(:with_pinned_generation).and_wrap_original do |method, &block|
        depth += 1
        begin
          method.call(&block)
        ensure
          depth -= 1
        end
      end
      allow(reader).to receive(:read_published_unit).and_wrap_original do |method, *args|
        observations << depth
        method.call(*args)
      end
      allow(notion_client).to receive(:create_page) do |**arguments|
        observations << depth
        pages << arguments
        { 'id' => 'page' }
      end
      notion(reader).public_send(operation)
      expect(observations.size).to eq(2) # one source read, then one mapped page
      expect(observations).to all(be_positive)
    end
  end

  it 'uploads the requested full-sync type with its original URI' do
    reader = publish(unit('model'), unit('poro'))
    expect(unblocked(reader).sync_type('model')).to include(synced: 1, errors: [])
    expect(documents.map { |doc| [doc[:title], doc[:uri]] }).to eq(
      [['Report (model)', 'https://example.invalid/repo/blob/main/model/report.rb']]
    )
  end

  it 'ranks and uploads the requested partial-sync type instead of a same-named lib' do
    reader = publish(unit('poro'), unit('lib'))
    expect(unblocked(reader).sync_type_partial('poro', 100)).to include(synced: 1, errors: [])
    expect(documents.first[:title]).to eq('Report (poro)')
  end

  it 'preserves the still-present model document and reaches an unchanged warm run' do
    reader = publish(unit('model'), unit('poro'))
    exporter = unblocked(reader, manifest: existing_manifest)
    expect(exporter.sync_all).to include(synced: 2, deleted: 0, errors: [])
    expect(exporter.sync_all).to include(synced: 0, skipped: 2, deleted: 0, errors: [])
    expect(documents.map { |doc| doc[:title] }).to contain_exactly('Report (model)', 'Report (poro)')
    expect(unblocked_client).not_to have_received(:delete_document)
  end

  it 'refuses unreadable published units before writes or deletion even with force_purge' do
    model = unit('model')
    reader = publish(model, unit('poro'))
    manifest = existing_manifest
    path = File.join(@index_dir, 'unblocked_sync_manifest.json')
    File.write(path, "#{JSON.generate(JSON.parse(File.read(path)))}\n\n")
    before = File.binread(path)
    File.unlink(unit_path(model))
    expect do
      unblocked(reader, manifest: manifest,
                        force_purge: true).sync_all
    end.to raise_error(Woods::ExtractionError, /incomplete/)
    expect(documents).to be_empty
    expect(unblocked_client).not_to have_received(:delete_document)
    expect(File.binread(File.join(@index_dir, 'unblocked_sync_manifest.json'))).to eq(before)
  end

  it 'does not overwrite same-name same-file variants or delete previous documents' do
    reader = publish(unit('model', file_path: 'shared.rb'), unit('poro', file_path: 'shared.rb'))
    result = unblocked(reader, manifest: existing_manifest, force_purge: true).sync_all
    expect(result).to include(synced: 0, deleted: 0)
    expect(result[:errors]).to all(include('ambiguous export URI'))
    expect(result[:errors].size).to eq(2)
    expect(documents).to be_empty
    expect(unblocked_client).not_to have_received(:delete_document)
  end

  it 'includes excluded types in the collision preflight for standalone full sync' do
    reader = publish(unit('model', file_path: 'shared.rb'), unit('database_view', file_path: 'shared.rb'))
    expect(unblocked(reader).sync_type('model')[:errors]).to contain_exactly(include('ambiguous export URI'))
    expect(documents).to be_empty
  end

  it 'includes excluded siblings in the collision preflight for partial sync' do
    reader = publish(unit('poro', file_path: 'shared.rb'), unit('database_view', file_path: 'shared.rb'))
    expect(unblocked(reader).sync_type_partial('poro', 1)[:errors]).to contain_exactly(include('ambiguous export URI'))
    expect(documents).to be_empty
  end

  it 'exports actual GraphQL subtypes once through the family and supports standalone subtype sync' do
    types = %w[graphql_type graphql_mutation graphql_resolver graphql_query]
    reader = publish(*types.map { |type| unit(type, type.split('_').last.capitalize) })
    expect(unblocked(reader).sync_all).to include(synced: 4, errors: [])
    expect(documents.map { |doc| doc[:title] }).to match_array(types.map { |type|
      "#{type.split('_').last.capitalize} (#{type})"
    })
    documents.clear
    expect(unblocked(reader, force_full: true).sync_type('graphql_query')).to include(synced: 1)
    expect(documents.first[:title]).to eq('Query (graphql_query)')
  end
end
