# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/unblocked/exporter'

RSpec.describe Woods::Unblocked::Exporter do
  let(:stub_config) do
    instance_double(
      'Woods::Configuration',
      unblocked_collection_id: 'col-1',
      unblocked_repo_url: 'https://github.com/org/repo',
      unblocked_api_token: 'ubk_token'
    )
  end

  let(:reader) do
    instance_double('Woods::MCP::IndexReader').tap do |r|
      allow(r).to receive(:list_units).and_return([])
    end
  end

  let(:client) do
    instance_double(Woods::Unblocked::Client).tap do |c|
      allow(c).to receive(:put_document).and_return('id' => 'doc-1')
    end
  end

  subject(:exporter) do
    described_class.new(
      index_dir: '/tmp/woods',
      config: stub_config,
      client: client,
      reader: reader,
      output: StringIO.new
    )
  end

  describe '#initialize' do
    it 'raises if unblocked_collection_id is missing' do
      bad_config = instance_double('Woods::Configuration', unblocked_collection_id: nil)
      expect { described_class.new(index_dir: '/tmp/x', config: bad_config) }
        .to raise_error(Woods::ConfigurationError, /unblocked_collection_id/)
    end

    it 'raises if unblocked_repo_url is missing' do
      bad_config = instance_double(
        'Woods::Configuration',
        unblocked_collection_id: 'c',
        unblocked_repo_url: nil
      )
      expect { described_class.new(index_dir: '/tmp/x', config: bad_config) }
        .to raise_error(Woods::ConfigurationError, /unblocked_repo_url/)
    end

    it 'raises if unblocked_api_token is missing' do
      bad_config = instance_double(
        'Woods::Configuration',
        unblocked_collection_id: 'c',
        unblocked_repo_url: 'https://example.com',
        unblocked_api_token: nil
      )
      expect { described_class.new(index_dir: '/tmp/x', config: bad_config) }
        .to raise_error(Woods::ConfigurationError, /unblocked_api_token/)
    end
  end

  describe '#sync_all' do
    it 'returns empty stats when no units exist' do
      stats = exporter.sync_all
      expect(stats[:synced]).to eq(0)
      expect(stats[:skipped]).to eq(0)
      expect(stats[:errors]).to eq([])
    end

    it 'syncs each unit via the client' do
      unit = { 'identifier' => 'User', 'type' => 'model' }
      allow(reader).to receive(:list_units).and_return([unit])
      allow(reader).to receive(:list_units).with(type: 'poro').and_return([])
      allow(reader).to receive(:list_units).with(type: 'lib').and_return([])
      allow(reader).to receive(:find_unit).with('User').and_return({
                                                                     'type' => 'model',
                                                                     'identifier' => 'User',
                                                                     'file_path' => 'app/models/user.rb',
                                                                     'metadata' => {}
                                                                   })

      stats = exporter.sync_all
      expect(stats[:synced]).to be > 0
      expect(client).to have_received(:put_document).at_least(:once)
    end

    it 'records errors but does not abort on non-budget failures' do
      unit_a = { 'identifier' => 'A', 'type' => 'model' }
      unit_b = { 'identifier' => 'B', 'type' => 'model' }
      # Order matters: the generic default goes first, then the specific override
      # for :model. Writing them the other way around overwrites the specific stub.
      allow(reader).to receive(:list_units).and_return([])
      allow(reader).to receive(:list_units).with(type: 'model').and_return([unit_a, unit_b])
      allow(reader).to receive(:find_unit).with('A').and_return({ 'type' => 'model', 'identifier' => 'A',
                                                                  'file_path' => 'a.rb' })
      allow(reader).to receive(:find_unit).with('B').and_return({ 'type' => 'model', 'identifier' => 'B',
                                                                  'file_path' => 'b.rb' })

      call_count = 0
      allow(client).to receive(:put_document) do
        call_count += 1
        raise Woods::Error, 'some api error' if call_count == 1

        { 'id' => 'ok' }
      end

      stats = exporter.sync_all
      expect(stats[:errors].size).to eq(1)
      expect(stats[:synced]).to eq(1)
    end

    it 'stops on "daily budget exhausted" without attempting further documents' do
      unit_a = { 'identifier' => 'A', 'type' => 'model' }
      unit_b = { 'identifier' => 'B', 'type' => 'model' }
      allow(reader).to receive(:list_units).and_return([])
      allow(reader).to receive(:list_units).with(type: 'model').and_return([unit_a, unit_b])
      allow(reader).to receive(:find_unit).and_return({ 'type' => 'model', 'identifier' => 'X',
                                                        'file_path' => 'x.rb' })
      allow(client).to receive(:put_document).and_raise(Woods::Error, 'daily budget exhausted')

      stats = exporter.sync_all
      expect(stats[:errors]).not_to be_empty
      expect(stats[:errors].first).to include('daily budget exhausted')
      expect(client).to have_received(:put_document).once
    end
  end

  describe 'MAX_ERRORS cap' do
    it 'caps the error list at MAX_ERRORS' do
      many_units = (1..(Woods::Unblocked::Exporter::MAX_ERRORS + 50)).map do |i|
        { 'identifier' => "U#{i}", 'type' => 'model' }
      end
      allow(reader).to receive(:list_units).and_return([])
      allow(reader).to receive(:list_units).with(type: 'model').and_return(many_units)
      allow(reader).to receive(:find_unit).and_return({ 'type' => 'model', 'identifier' => 'X',
                                                        'file_path' => 'x.rb' })
      allow(client).to receive(:put_document).and_raise(StandardError, 'api down')

      stats = exporter.sync_all
      expect(stats[:errors].size).to be <= Woods::Unblocked::Exporter::MAX_ERRORS + 1
    end
  end
end
