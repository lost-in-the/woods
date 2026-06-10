# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/unblocked/exporter'

RSpec.describe Woods::Unblocked::Exporter do
  around do |example|
    Dir.mktmpdir do |dir|
      @index_dir = dir
      example.run
    end
  end

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
      allow(c).to receive(:all_documents).and_return([])
      allow(c).to receive(:delete_document).and_return({})
    end
  end

  # nil → the exporter builds a real SyncManifest under @index_dir.
  # Override with a double in focused tests for precise skip/delete control.
  let(:manifest) { nil }
  let(:force_full) { false }
  let(:force_purge) { false }

  subject(:exporter) do
    described_class.new(
      index_dir: @index_dir,
      config: stub_config,
      client: client,
      reader: reader,
      manifest: manifest,
      force_full: force_full,
      force_purge: force_purge,
      output: StringIO.new
    )
  end

  # The blob URI the builder produces for a unit at the given path.
  def uri_for(path)
    "https://github.com/org/repo/blob/main/#{path}"
  end

  # A manifest double with sensible no-op defaults; pass a block to override.
  def manifest_double # rubocop:disable Metrics/AbcSize
    instance_double(Woods::Unblocked::SyncManifest).tap do |m|
      allow(m).to receive(:empty?).and_return(false)
      allow(m).to receive(:unchanged?).and_return(false)
      allow(m).to receive(:record)
      allow(m).to receive(:document_id_for).and_return(nil)
      allow(m).to receive(:stale_uris).and_return([])
      allow(m).to receive(:forget)
      allow(m).to receive(:size).and_return(0)
      allow(m).to receive(:save)
      yield m if block_given?
    end
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

  describe 'incremental sync' do
    # One model unit named User, present this run.
    def stub_single_user
      allow(reader).to receive(:list_units).and_return([])
      allow(reader).to receive(:list_units).with(type: 'model')
                                           .and_return([{ 'identifier' => 'User', 'type' => 'model' }])
      allow(reader).to receive(:find_unit).with('User')
                                          .and_return({ 'type' => 'model', 'identifier' => 'User',
                                                        'file_path' => 'app/models/user.rb', 'metadata' => {} })
    end

    context 'when a unit is unchanged' do
      let(:manifest) { manifest_double { |m| allow(m).to receive(:unchanged?).and_return(true) } }

      it 'skips it without calling put_document' do
        stub_single_user
        stats = exporter.sync_all
        expect(client).not_to have_received(:put_document)
        expect(stats[:skipped]).to be >= 1
      end
    end

    context 'when a unit changed' do
      let(:manifest) { manifest_double { |m| allow(m).to receive(:unchanged?).and_return(false) } }

      it 'pushes it and records the new hash + document_id' do
        stub_single_user
        exporter.sync_all
        expect(client).to have_received(:put_document).once
        expect(manifest).to have_received(:record)
          .with(uri: uri_for('app/models/user.rb'), hash: kind_of(String), document_id: 'doc-1')
      end
    end

    context 'when force_full is set' do
      let(:force_full) { true }
      let(:manifest) { manifest_double { |m| allow(m).to receive(:unchanged?).and_return(true) } }

      it 'pushes even unchanged units' do
        stub_single_user
        exporter.sync_all
        expect(client).to have_received(:put_document).once
      end
    end

    context 'when a recorded unit no longer exists' do
      let(:manifest) do
        manifest_double do |m|
          allow(m).to receive(:size).and_return(20)
          allow(m).to receive(:stale_uris).and_return([uri_for('app/models/gone.rb')])
          allow(m).to receive(:document_id_for).with(uri_for('app/models/gone.rb')).and_return('doc-gone')
        end
      end

      it 'deletes the orphaned remote document and forgets it' do
        stub_single_user
        stats = exporter.sync_all
        expect(client).to have_received(:delete_document).with(document_id: 'doc-gone')
        expect(manifest).to have_received(:forget).with(uri_for('app/models/gone.rb'))
        expect(stats[:deleted]).to eq(1)
      end
    end

    context 'mass-deletion guard' do
      # 8 of 10 recorded docs would be purged (80% > 30%) — a partial index.
      let(:stale) { (1..8).map { |i| uri_for("app/models/m#{i}.rb") } }
      let(:manifest) do
        manifest_double do |m|
          allow(m).to receive(:size).and_return(10)
          allow(m).to receive(:stale_uris).and_return(stale)
          allow(m).to receive(:document_id_for).and_return('some-doc')
        end
      end

      it 'refuses to purge above the threshold without force_purge' do
        stub_single_user
        stats = exporter.sync_all
        expect(client).not_to have_received(:delete_document)
        expect(stats[:deleted]).to eq(0)
      end

      context 'with force_purge' do
        let(:force_purge) { true }

        it 'purges anyway' do
          stub_single_user
          stats = exporter.sync_all
          expect(client).to have_received(:delete_document).exactly(8).times
          expect(stats[:deleted]).to eq(8)
        end
      end
    end

    context 'when budget is exhausted mid-run' do
      let(:manifest) do
        manifest_double do |m|
          allow(m).to receive(:size).and_return(20)
          allow(m).to receive(:stale_uris).and_return([uri_for('app/models/gone.rb')])
          allow(m).to receive(:document_id_for).and_return('doc-gone')
        end
      end

      it 'does not purge (current set is incomplete)' do
        stub_single_user
        allow(client).to receive(:put_document).and_raise(Woods::Error, 'daily budget exhausted')
        stats = exporter.sync_all
        expect(client).not_to have_received(:delete_document)
        expect(stats[:deleted]).to eq(0)
      end
    end

    context 'when public sync methods are called without sync_all' do
      it 'sync_type works standalone (regression: nil @current_uris crash)' do
        allow(reader).to receive(:list_units).with(type: 'model')
                                             .and_return([{ 'identifier' => 'User', 'type' => 'model' }])
        allow(reader).to receive(:find_unit).with('User')
                                            .and_return({ 'type' => 'model', 'identifier' => 'User',
                                                          'file_path' => 'app/models/user.rb', 'metadata' => {} })

        stats = exporter.sync_type('model')
        # The nil-@current_uris crash is swallowed by the per-unit rescue and
        # surfaces as a sync error — so assert success, not just no-raise.
        expect(stats[:errors]).to eq([])
        expect(stats[:synced]).to eq(1)
      end

      it 'sync_type_partial works standalone' do
        allow(reader).to receive(:list_units).with(type: 'poro')
                                             .and_return([{ 'identifier' => 'Util', 'type' => 'poro' }])
        allow(reader).to receive(:find_unit).with('Util')
                                            .and_return({ 'type' => 'poro', 'identifier' => 'Util',
                                                          'file_path' => 'lib/util.rb', 'metadata' => {} })

        stats = exporter.sync_type_partial('poro', 10)
        expect(stats[:errors]).to eq([])
        expect(stats[:synced]).to eq(1)
      end
    end

    context 'when persisting the manifest fails' do
      let(:manifest) { manifest_double { |m| allow(m).to receive(:save).and_raise(Errno::EACCES, 'ro mount') } }

      it 'still returns stats instead of raising from the ensure block' do
        stub_single_user
        stats = nil
        expect { stats = exporter.sync_all }.not_to raise_error
        expect(stats[:synced]).to eq(1)
      end
    end

    context 'when a stale delete returns 404 (already gone remotely)' do
      let(:gone_uri) { uri_for('app/models/gone.rb') }
      let(:manifest) do
        manifest_double do |m|
          allow(m).to receive(:size).and_return(20)
          allow(m).to receive(:stale_uris).and_return([gone_uri, uri_for('app/models/also_gone.rb')])
          allow(m).to receive(:document_id_for).and_return('doc-x')
        end
      end

      it 'forgets the entry and continues purging the rest' do
        stub_single_user
        call = 0
        allow(client).to receive(:delete_document) do
          call += 1
          raise Woods::Unblocked::ApiError.new('Unblocked API error 404: Not Found', status: 404) if call == 1

          {}
        end

        stats = exporter.sync_all
        expect(manifest).to have_received(:forget).twice # 404 entry + successful delete
        expect(stats[:deleted]).to eq(1)                 # only the real delete counts
      end

      it 'keeps the entry on a non-404 ApiError so a later run retries' do
        stub_single_user
        allow(client).to receive(:delete_document)
          .and_raise(Woods::Unblocked::ApiError.new('Unblocked API error 500: oops', status: 500))

        exporter.sync_all
        expect(manifest).not_to have_received(:forget)
      end
    end

    context 'when a stale entry has no document_id' do
      let(:gone_uri) { uri_for('app/models/gone.rb') }
      let(:manifest) do
        manifest_double do |m|
          allow(m).to receive(:size).and_return(20)
          allow(m).to receive(:stale_uris).and_return([gone_uri])
          # nil until the reconcile records the resolved id
          ids = { gone_uri => nil }
          allow(m).to receive(:document_id_for) { |uri| ids[uri] }
          allow(m).to receive(:record) { |uri:, document_id:, **| ids[uri] = document_id }
        end
      end

      it 'resolves the id via one all_documents call, then deletes' do
        stub_single_user
        allow(client).to receive(:all_documents).with(collection_id: 'col-1').and_return(
          [{ 'id' => 'resolved-1', 'uri' => gone_uri, 'collectionId' => 'col-1' }]
        )

        stats = exporter.sync_all
        expect(client).to have_received(:all_documents).once
        expect(client).to have_received(:delete_document).with(document_id: 'resolved-1')
        expect(stats[:deleted]).to eq(1)
      end
    end

    context 'two consecutive runs with a real manifest (end-to-end)' do
      it 'pushes everything on run 1, then skips everything and deletes nothing on run 2' do
        stub_single_user

        first = exporter.sync_all
        expect(first[:synced]).to eq(1)
        expect(client).to have_received(:put_document).once

        second_exporter = described_class.new(
          index_dir: @index_dir, config: stub_config, client: client,
          reader: reader, output: StringIO.new
        )
        second = second_exporter.sync_all

        expect(second[:synced]).to eq(0)
        expect(second[:skipped]).to be >= 1
        expect(second[:deleted]).to eq(0)
        expect(client).to have_received(:put_document).once # still only run 1's push
        expect(client).not_to have_received(:delete_document)
      end
    end

    context 'partial-sync URI tracking (top-N fallout protection)' do
      it 'reports every existing partial unit to stale_uris, not just the top-N' do
        stub_const('Woods::Unblocked::Exporter::FULL_SYNC_TYPES', [])
        stub_const('Woods::Unblocked::Exporter::PARTIAL_SYNC_TYPES', [['poro', 2]])

        units = (1..3).map { |i| { 'identifier' => "Poro#{i}", 'type' => 'poro' } }
        allow(reader).to receive(:list_units).with(type: 'poro').and_return(units)
        (1..3).each do |i|
          allow(reader).to receive(:find_unit).with("Poro#{i}").and_return(
            { 'type' => 'poro', 'identifier' => "Poro#{i}",
              'file_path' => "lib/poro#{i}.rb", 'metadata' => {},
              'dependents' => Array.new(4 - i) { { 'type' => 'model', 'identifier' => 'X' } } }
          )
        end

        captured = nil
        local_manifest = manifest_double do |m|
          allow(m).to receive(:stale_uris) { |uris|
            captured = uris.to_a
            []
          }
        end
        described_class.new(
          index_dir: @index_dir, config: stub_config, client: client,
          reader: reader, manifest: local_manifest, output: StringIO.new
        ).sync_all

        # Poro3 (rank 3, beyond max_count 2) still exists — it must be in the
        # current set handed to stale_uris or it would be purged remotely.
        expect(captured).to include(uri_for('lib/poro1.rb'), uri_for('lib/poro2.rb'), uri_for('lib/poro3.rb'))
        expect(client).to have_received(:put_document).twice # only top 2 pushed
      end
    end

    context 'mass-deletion guard boundaries' do
      def guarded_stats(manifest_size, stale_count)
        stale = (1..stale_count).map { |i| uri_for("app/models/m#{i}.rb") }
        local_manifest = manifest_double do |m|
          allow(m).to receive(:size).and_return(manifest_size)
          allow(m).to receive(:stale_uris).and_return(stale)
          allow(m).to receive(:document_id_for).and_return('doc-x')
        end
        described_class.new(
          index_dir: @index_dir, config: stub_config, client: client,
          reader: reader, manifest: local_manifest, output: StringIO.new
        ).sync_all
      end

      it 'blocks at size 10 with 40% stale (guard active at the floor)' do
        expect(guarded_stats(10, 4)[:deleted]).to eq(0)
      end

      it 'allows exactly 30% (threshold is strict greater-than)' do
        expect(guarded_stats(10, 3)[:deleted]).to eq(3)
      end

      it 'allows 100% stale below the 10-doc floor (small collections stay deletable)' do
        expect(guarded_stats(9, 9)[:deleted]).to eq(9)
      end
    end

    context 'when a sync type raises mid-run' do
      let(:manifest) { manifest_double }

      it 'still saves the manifest from the ensure block' do
        allow(reader).to receive(:list_units).and_raise(RuntimeError, 'index unreadable')
        expect { exporter.sync_all }.to raise_error(RuntimeError, /index unreadable/)
        expect(manifest).to have_received(:save)
      end
    end

    context 'when put_document returns no id' do
      let(:manifest) do
        manifest_double { |m| allow(m).to receive(:document_id_for).and_return('previously-known-id') }
      end

      it 'falls back to the previously recorded document_id' do
        stub_single_user
        allow(client).to receive(:put_document).and_return({})
        exporter.sync_all
        expect(manifest).to have_received(:record)
          .with(hash_including(document_id: 'previously-known-id'))
      end
    end

    context 'when a stale delete fails with a non-404 error' do
      let(:manifest) do
        manifest_double do |m|
          allow(m).to receive(:size).and_return(20)
          allow(m).to receive(:stale_uris).and_return([uri_for('app/models/gone.rb')])
          allow(m).to receive(:document_id_for).and_return('doc-x')
        end
      end

      it 'surfaces the failure in stats[:errors] instead of swallowing it' do
        stub_single_user
        allow(client).to receive(:delete_document)
          .and_raise(Woods::Unblocked::ApiError.new('Unblocked API error 500: oops', status: 500))

        stats = exporter.sync_all
        expect(stats[:errors]).to include(a_string_matching(/delete.*gone\.rb.*500/))
        expect(stats[:deleted]).to eq(0)
      end
    end

    context 'when reconcile hits an auth failure' do
      let(:manifest) { manifest_double { |m| allow(m).to receive(:empty?).and_return(true) } }

      it 'aborts loudly instead of proceeding into doomed API calls' do
        allow(client).to receive(:all_documents)
          .and_raise(Woods::Unblocked::ApiError.new('Unblocked API error 401: bad token', status: 401))
        expect { exporter.sync_all }.to raise_error(Woods::Unblocked::ApiError, /401/)
      end
    end

    context 'when the credential scrub fails closed (empty body)' do
      let(:manifest) { manifest_double }

      it 'records an error and does not overwrite the remote doc with an empty body' do
        stub_single_user
        allow(Woods::Console::CredentialScanner).to receive(:new).and_raise(StandardError, 'scanner broken')

        stats = exporter.sync_all
        expect(client).not_to have_received(:put_document)
        expect(stats[:errors]).to include(a_string_matching(/User.*empty/i))
      end
    end

    context 'when the manifest is empty (cache miss)' do
      it 'reconciles document ids from the remote and purges orphans' do
        # No current units; remote has one orphan in our collection.
        allow(reader).to receive(:list_units).and_return([])
        allow(client).to receive(:all_documents).with(collection_id: 'col-1').and_return(
          [{ 'id' => 'remote-1', 'uri' => uri_for('app/models/orphan.rb'), 'collectionId' => 'col-1' }]
        )

        stats = exporter.sync_all

        expect(client).to have_received(:all_documents).with(collection_id: 'col-1')
        expect(client).to have_received(:delete_document).with(document_id: 'remote-1')
        expect(stats[:deleted]).to eq(1)
      end
    end
  end
end
