# frozen_string_literal: true

require 'spec_helper'
require 'woods/storage/vector_store'
require 'woods/storage/pgvector'

RSpec.describe Woods::Storage::VectorStore::Pgvector do
  let(:connection) { double('ActiveRecord::ConnectionAdapters::AbstractAdapter') }
  let(:store) { described_class.new(connection: connection, dimensions: 3) }

  describe '#initialize' do
    it 'stores the connection and dimensions' do
      expect(store).to be_a(described_class)
    end

    it 'accepts a validated table name for isolated live namespaces' do
      isolated = described_class.new(
        connection: connection,
        dimensions: 3,
        table: 'woods_vectors_a1b2c3'
      )

      expect(isolated.table).to eq('woods_vectors_a1b2c3')
    end

    it 'rejects table names that could alter SQL structure' do
      expect do
        described_class.new(connection: connection, dimensions: 3, table: 'woods_vectors; DROP TABLE users')
      end.to raise_error(ArgumentError, /table must be a PostgreSQL identifier/)
    end

    it 'uses an actual positive Integer before SQL construction' do
      normalized = described_class.new(connection: connection, dimensions: 3)
      allow(connection).to receive(:transaction).and_yield
      allow(connection).to receive(:execute)

      normalized.ensure_schema!

      expect(connection).to have_received(:execute).with(/vector\(3\)/)
    end

    [3.0, '3', true, false, '3); DROP TABLE users; --'].each do |dimensions|
      it "rejects non-Integer dimensions #{dimensions.inspect} before SQL" do
        expect { described_class.new(connection: connection, dimensions: dimensions) }
          .to raise_error(ArgumentError, /dimensions must be a positive Integer/)
      end
    end

    it 'rejects invalid dimensions and schema identifiers before executing SQL' do
      expect { described_class.new(connection: connection, dimensions: '0') }
        .to raise_error(ArgumentError, /dimensions must be a positive Integer/)
      expect { described_class.new(connection: connection, dimensions: 3, schema: 'public; DROP') }
        .to raise_error(ArgumentError, /schema must be a PostgreSQL identifier/)
    end
  end

  describe '#ensure_schema!' do
    before { allow(connection).to receive(:transaction).and_yield }

    it 'creates the extension, table, and index in one transaction' do
      allow(connection).to receive(:execute)

      store.ensure_schema!

      expect(connection).to have_received(:transaction).once
    end

    it 'creates the extension, table, and index' do
      allow(connection).to receive(:execute)

      store.ensure_schema!

      expect(connection).to have_received(:execute).with(/CREATE EXTENSION IF NOT EXISTS vector/)
      expect(connection).to have_received(:execute).with(/CREATE TABLE IF NOT EXISTS woods_vectors/)
      expect(connection).to have_received(:execute).with(/CREATE INDEX IF NOT EXISTS/)
    end

    it 'creates a vector column with the correct dimensions' do
      allow(connection).to receive(:execute)

      store.ensure_schema!

      expect(connection).to have_received(:execute).with(/vector\(3\)/)
    end

    it 'creates an explicitly isolated table and index' do
      allow(connection).to receive(:execute)
      isolated = described_class.new(
        connection: connection,
        dimensions: 3,
        table: 'woods_vectors_a1b2c3'
      )

      isolated.ensure_schema!

      expect(connection).to have_received(:execute).with(/CREATE TABLE IF NOT EXISTS woods_vectors_a1b2c3/)
      expect(connection).to have_received(:execute).with(/ON woods_vectors_a1b2c3 USING hnsw/)
    end

    it 'quotes an explicitly selected schema and table' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote_table_name) { |name| %("#{name}") }
      namespaced = described_class.new(connection: connection, dimensions: 3, schema: 'tenant_a')

      namespaced.ensure_schema!

      expect(connection).to have_received(:execute).with(/CREATE TABLE IF NOT EXISTS "tenant_a"\."woods_vectors"/)
    end
  end

  describe '#store' do
    it 'upserts a vector with metadata' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.store('doc1', [0.1, 0.2, 0.3], { type: 'model' })

      expect(connection).to have_received(:execute).with(/INSERT INTO woods_vectors/)
      expect(connection).to have_received(:execute).with(/ON CONFLICT \(id\) DO UPDATE/)
    end

    it 'quotes values to prevent SQL injection' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.store('doc1', [0.1, 0.2, 0.3])

      expect(connection).to have_received(:quote).at_least(:once)
    end
  end

  describe '#store_batch' do
    before do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }
    end

    it 'inserts multiple rows in a single SQL statement' do
      entries = [
        { id: 'doc1', vector: [0.1, 0.2, 0.3], metadata: { type: 'model' } },
        { id: 'doc2', vector: [0.4, 0.5, 0.6], metadata: { type: 'service' } }
      ]

      store.store_batch(entries)

      expect(connection).to have_received(:execute).once
      expect(connection).to have_received(:execute).with(/INSERT INTO woods_vectors/)
    end

    it 'includes all entries in the VALUES clause' do
      entries = [
        { id: 'a', vector: [1.0, 2.0, 3.0], metadata: {} },
        { id: 'b', vector: [4.0, 5.0, 6.0], metadata: {} },
        { id: 'c', vector: [7.0, 8.0, 9.0], metadata: {} }
      ]

      store.store_batch(entries)

      expect(connection).to have_received(:execute).with(/VALUES.*'a'.*'b'.*'c'/m)
    end

    it 'uses ON CONFLICT upsert' do
      entries = [{ id: 'doc1', vector: [0.1, 0.2, 0.3], metadata: {} }]

      store.store_batch(entries)

      expect(connection).to have_received(:execute).with(/ON CONFLICT \(id\) DO UPDATE/)
    end

    it 'does nothing for empty entries' do
      store.store_batch([])

      expect(connection).not_to have_received(:execute)
    end

    it 'validates vectors in the batch' do
      entries = [{ id: 'doc1', vector: [0.1, 'bad', 0.3], metadata: {} }]

      expect { store.store_batch(entries) }.to raise_error(ArgumentError, /not numeric/)
    end

    it 'defaults metadata to empty hash when not provided' do
      entries = [{ id: 'doc1', vector: [0.1, 0.2, 0.3] }]

      store.store_batch(entries)

      expect(connection).to have_received(:execute).with(/\{\}/)
    end
  end

  # #181 regression coverage. Deliberately uses a plain double (not the
  # string-named instance_double above, which verifies nothing) so the
  # message expectations have teeth.
  describe '#store_batch in-batch duplicate handling (#181)' do
    let(:strict_connection) { double('connection') }
    let(:strict_store) { described_class.new(connection: strict_connection, dimensions: 3) }
    let(:executed_sql) { [] }

    before do
      allow(strict_connection).to receive(:quote) { |v| "'#{v}'" }
      allow(strict_connection).to receive(:execute) do |sql|
        executed_sql << sql
        []
      end
    end

    it 'keeps exactly one row per duplicated id — the LAST occurrence (upsert semantics)' do
      entries = [
        { id: 'dup', vector: [1.0, 1.0, 1.0], metadata: { 'v' => 'first' } },
        { id: 'other', vector: [2.0, 2.0, 2.0], metadata: {} },
        { id: 'dup', vector: [9.0, 9.0, 9.0], metadata: { 'v' => 'last' } }
      ]

      expect { strict_store.store_batch(entries) }.to output(/dup/).to_stderr

      sql = executed_sql.fetch(0)
      expect(sql.scan("'dup'").length).to eq(1)
      expect(sql).to include('[9.0,9.0,9.0]')
      expect(sql).not_to include('[1.0,1.0,1.0]')
    end

    it 'logs the duplicated ids when dropping so the upstream cause stays visible' do
      entries = [
        { id: 'twin', vector: [1.0, 2.0, 3.0], metadata: {} },
        { id: 'twin', vector: [4.0, 5.0, 6.0], metadata: {} }
      ]

      expect { strict_store.store_batch(entries) }
        .to output(/store_batch received duplicate ids.*twin/).to_stderr
    end

    it 'leaves batches without duplicates untouched and silent' do
      entries = [
        { id: 'a', vector: [1.0, 2.0, 3.0], metadata: {} },
        { id: 'b', vector: [4.0, 5.0, 6.0], metadata: {} },
        { id: 'c', vector: [7.0, 8.0, 9.0], metadata: {} }
      ]

      expect { strict_store.store_batch(entries) }.not_to output.to_stderr

      sql = executed_sql.fetch(0)
      %w[a b c].each { |id| expect(sql.scan("'#{id}'").length).to eq(1) }
    end

    it 're-raises a PG cardinality violation as Woods::Error naming the batch ids' do
      stub_const('PG::CardinalityViolation', Class.new(StandardError))
      allow(strict_connection).to receive(:execute)
        .and_raise(PG::CardinalityViolation,
                   'ERROR: ON CONFLICT DO UPDATE command cannot affect row a second time')

      entries = [
        { id: 'alpha', vector: [1.0, 2.0, 3.0], metadata: {} },
        { id: 'beta', vector: [4.0, 5.0, 6.0], metadata: {} }
      ]

      expect { strict_store.store_batch(entries) }
        .to raise_error(Woods::Error, /duplicate-row conflict.*Batch ids: alpha, beta/m)
    end

    it 'detects the violation on the cause (ActiveRecord::StatementInvalid-style wrapping)' do
      stub_const('PG::CardinalityViolation', Class.new(StandardError))
      allow(strict_connection).to receive(:execute) do
        raise PG::CardinalityViolation, 'unremarkable message'
      rescue StandardError
        raise StandardError, 'statement invalid'
      end

      entries = [{ id: 'wrapped', vector: [1.0, 2.0, 3.0], metadata: {} }]

      expect { strict_store.store_batch(entries) }
        .to raise_error(Woods::Error, /Batch ids: wrapped/)
    end

    it 'lets unrelated execution errors propagate untouched' do
      allow(strict_connection).to receive(:execute).and_raise(StandardError, 'network down')

      entries = [{ id: 'a', vector: [1.0, 2.0, 3.0], metadata: {} }]

      expect { strict_store.store_batch(entries) }.to raise_error(StandardError) do |error|
        expect(error).not_to be_a(Woods::Error)
        expect(error.message).to eq('network down')
      end
    end
  end

  describe '#search' do
    let(:result_row) do
      { 'id' => 'doc1', 'distance' => 0.1, 'metadata' => '{"type":"model"}' }
    end

    before do
      allow(connection).to receive(:execute).and_return([result_row])
      allow(connection).to receive(:quote) { |v| "'#{v}'" }
    end

    it 'returns an array of SearchResult objects' do
      results = store.search([0.1, 0.2, 0.3], limit: 5)

      expect(results).to all(be_a(Woods::Storage::VectorStore::SearchResult))
    end

    it 'converts distance to similarity score' do
      results = store.search([0.1, 0.2, 0.3])

      expect(results.first.score).to be_within(0.001).of(0.9)
    end

    it 'parses metadata JSON' do
      results = store.search([0.1, 0.2, 0.3])

      expect(results.first.metadata).to eq({ 'type' => 'model' })
    end

    it 'respects the limit parameter' do
      store.search([0.1, 0.2, 0.3], limit: 5)

      expect(connection).to have_received(:execute).with(/LIMIT 5/)
    end

    it 'applies metadata filters' do
      store.search([0.1, 0.2, 0.3], filters: { type: 'model' })

      expect(connection).to have_received(:execute).with(/metadata->>'type' = 'model'/)
    end

    it 'translates an Array filter value into IN (...) membership (#108)' do
      store.search([0.1, 0.2, 0.3], filters: { type: %w[model service] })

      expect(connection).to have_received(:execute).with(/metadata->>'type' IN \('model', 'service'\)/)
    end

    it 'emits an always-false predicate for an empty Array filter' do
      store.search([0.1, 0.2, 0.3], filters: { type: [] })

      expect(connection).to have_received(:execute).with(/WHERE FALSE/)
    end

    it 'returns empty array when no results' do
      allow(connection).to receive(:execute).and_return([])

      results = store.search([0.1, 0.2, 0.3])

      expect(results).to be_empty
    end
  end

  describe '#delete' do
    it 'deletes by ID' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.delete('doc1')

      expect(connection).to have_received(:execute).with(/DELETE FROM woods_vectors WHERE id = /)
    end
  end

  describe '#delete_by_filter' do
    it 'deletes by metadata filter' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.delete_by_filter({ type: 'model' })

      expect(connection).to have_received(:execute)
        .with(/DELETE FROM woods_vectors WHERE metadata->>'type' = 'model'/)
    end

    it 'handles multiple filters' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.delete_by_filter({ type: 'model', app: 'main' })

      expect(connection).to have_received(:execute).with(/metadata->>'type' = 'model'/)
      expect(connection).to have_received(:execute).with(/metadata->>'app' = 'main'/)
    end
  end

  describe '#count' do
    it 'returns the number of stored vectors' do
      allow(connection).to receive(:execute).and_return([{ 'count' => 42 }])

      expect(store.count).to eq(42)
    end
  end

  describe '#each_id' do
    it 'selects ids without loading vectors' do
      allow(connection).to receive(:execute).and_return([{ 'id' => 'User' }, { 'id' => 'Post#chunk_0' }])

      expect(store.each_id.to_a).to eq(['User', 'Post#chunk_0'])
      expect(connection).to have_received(:execute).with(/SELECT id FROM woods_vectors/)
      expect(connection).not_to have_received(:execute).with(/embedding/)
    end
  end

  describe '#stored_dimensions' do
    before { allow(connection).to receive(:quote) { |value| "'#{value}'" } }

    # For pgvector's `vector` type, atttypmod carries the dimension directly.
    it 'reads the width the column was created with' do
      allow(connection).to receive(:execute).and_return([{ 'dimension' => 384 }])

      expect(store.stored_dimensions).to eq(384)
    end

    it 'returns nil when the table does not exist' do
      allow(connection).to receive(:execute).and_return([])

      expect(store.stored_dimensions).to be_nil
    end

    it 'returns nil when the column reports no width' do
      allow(connection).to receive(:execute).and_return([{ 'dimension' => -1 }])

      expect(store.stored_dimensions).to be_nil
    end

    it 'surfaces connection and permission failures' do
      allow(connection).to receive(:execute).and_raise(StandardError, 'connection lost')

      expect { store.stored_dimensions }.to raise_error(StandardError, 'connection lost')
    end
  end

  describe 'Interface compliance' do
    it 'includes VectorStore::Interface' do
      expect(described_class.ancestors).to include(Woods::Storage::VectorStore::Interface)
    end

    # #211 / B-108: the interface defines each_entry, so respond_to? is true
    # for every adapter. Only the owner check distinguishes a real
    # implementation — Indexer#persistable? depends on this being so.
    it 'implements each_id but not each_entry' do
      expect(described_class.instance_method(:each_id).owner).to eq(described_class)
      expect(described_class.instance_method(:each_entry).owner)
        .to eq(Woods::Storage::VectorStore::Interface)
    end
  end

  describe '#build_where security' do
    it 'rejects malicious filter keys' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      expect { store.search([0.1, 0.2, 0.3], filters: { "'; DROP TABLE users; --" => 'x' }) }
        .to raise_error(ArgumentError, /Invalid filter key/)
    end

    it 'accepts valid filter keys' do
      allow(connection).to receive(:execute).and_return([])
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      expect { store.search([0.1, 0.2, 0.3], filters: { type: 'model' }) }.not_to raise_error
    end

    it 'accepts filter keys with underscores and numbers' do
      allow(connection).to receive(:execute).and_return([])
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      expect { store.search([0.1, 0.2, 0.3], filters: { unit_type: 'model' }) }.not_to raise_error
    end
  end

  describe 'vector validation' do
    it 'rejects non-numeric vector elements on store' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      expect { store.store('doc1', [0.1, 'malicious', 0.3]) }
        .to raise_error(ArgumentError, /not numeric/)
    end

    it 'rejects non-numeric vector elements on search' do
      expect { store.search([0.1, nil, 0.3]) }
        .to raise_error(ArgumentError, /not numeric/)
    end

    it 'rejects NaN and Infinity on store' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      expect { store.store('doc1', [0.1, Float::NAN, 0.3]) }
        .to raise_error(ArgumentError, /not finite/)
      expect { store.store('doc1', [0.1, Float::INFINITY, 0.3]) }
        .to raise_error(ArgumentError, /not finite/)
    end

    it 'coerces vector elements to Float when building the literal so a Numeric subclass cannot smuggle SQL' do
      sneaky = Class.new(Numeric) do
        def to_s
          "', INJECTED, '"
        end

        def to_f
          0.5
        end

        def finite?
          true
        end
      end.new

      captured = nil
      allow(connection).to receive(:execute) do |sql|
        captured = sql
        []
      end
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.search([0.1, sneaky, 0.3])
      expect(captured).not_to include('INJECTED')
      expect(captured).to match(/\[0\.1,0\.5,0\.3\]/)
    end
  end

  describe '#build_where SQL construction (G-3)' do
    it 'passes the metadata key through connection.quote so future regex changes cannot reopen injection' do
      quoted_calls = []
      allow(connection).to receive(:execute).and_return([])
      allow(connection).to receive(:quote) do |v|
        quoted_calls << v
        "'#{v}'"
      end

      store.search([0.1, 0.2, 0.3], filters: { unit_type: 'model' })
      expect(quoted_calls).to include('unit_type')
      expect(quoted_calls).to include('model')
    end
  end
end
